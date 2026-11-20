// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import AVFoundation
import CryptoKit
import Foundation
import Network

/// Encrypts and decrypts the frames of one call with the keys the DAVE handshake produced (libdave). Used only on DiscordAudio's queue.
final class DaveFrameCodec {
    private let encryptor = daveEncryptorCreate()
    private var decryptors: [String: DAVEDecryptorHandle] = [:]
    /// Opens this account's own frames with its own keys (a check on what goes out; see `openOwn`).
    private var ownDecryptor: DAVEDecryptorHandle?
    private var passthrough = false

    deinit {
        daveEncryptorDestroy(encryptor)
        if let ownDecryptor { daveDecryptorDestroy(ownDecryptor) }
        decryptors.values.forEach { daveDecryptorDestroy($0) }
    }

    func assign(ssrc: UInt32, codec: DAVECodec = DAVE_CODEC_OPUS) { daveEncryptorAssignSsrcToCodec(encryptor, ssrc, codec) }

    /// Keys for one user (this account's own for sending, a member's for receiving). Version 0 means the call is not end-to-end encrypted.
    func setRatchet(user: String, isSelf: Bool, ratchet: DaveKeyRatchet?, version: UInt16) {
        if version == 0 {
            passthrough = true
            if isSelf { daveEncryptorSetPassthroughMode(encryptor, true) } else { decryptor(for: user, create: true).map { daveDecryptorTransitionToPassthroughMode($0, true) } }
            return
        }
        guard let ratchet else { return }
        passthrough = false
        if isSelf {
            daveEncryptorSetPassthroughMode(encryptor, false)
            daveEncryptorSetKeyRatchet(encryptor, ratchet.handle)
            if ownDecryptor == nil { ownDecryptor = daveDecryptorCreate() }
            if let own = ownDecryptor {
                daveDecryptorTransitionToPassthroughMode(own, false)
                daveDecryptorTransitionToKeyRatchet(own, ratchet.handle)
            }
        } else if let d = decryptor(for: user, create: true) {
            daveDecryptorTransitionToPassthroughMode(d, false)
            daveDecryptorTransitionToKeyRatchet(d, ratchet.handle)
        }
    }

    var canEncrypt: Bool { passthrough || daveEncryptorHasKeyRatchet(encryptor) }

    func encrypt(_ opus: Data, ssrc: UInt32, media: DAVEMediaType = DAVE_MEDIA_TYPE_AUDIO) -> Data? {
        let capacity = daveEncryptorGetMaxCiphertextByteSize(encryptor, media, opus.count)
        var out = Data(count: capacity)
        var written = 0
        let code = out.withUnsafeMutableBytes { outPtr in
            opus.withUnsafeBytes { inPtr in
                daveEncryptorEncrypt(encryptor, media, ssrc, inPtr.bindMemory(to: UInt8.self).baseAddress, opus.count,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, capacity, &written)
            }
        }
        guard code == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS else { return nil }
        return out.prefix(written)
    }

    /// nil when the frame could not be decrypted (no keys yet for that user, or a frame from before the keys).
    func decrypt(_ frame: Data, user: String, media: DAVEMediaType = DAVE_MEDIA_TYPE_AUDIO) -> (Data?, Int) {
        guard let d = decryptor(for: user, create: true) else { return (nil, -1) }
        return Self.open(frame, with: d, media: media)
    }

    /// One of this account's own encrypted frames, opened with its own keys: tells whether what goes out is well formed and decryptable by the library that made it.
    func openOwn(_ frame: Data, media: DAVEMediaType) -> (Data?, Int) {
        guard let d = ownDecryptor else { return (nil, -1) }
        return Self.open(frame, with: d, media: media)
    }

    private static func open(_ frame: Data, with d: DAVEDecryptorHandle, media: DAVEMediaType) -> (Data?, Int) {
        let capacity = max(daveDecryptorGetMaxPlaintextByteSize(d, media, frame.count), frame.count)
        var out = Data(count: capacity)
        var written = 0
        let code = out.withUnsafeMutableBytes { outPtr in
            frame.withUnsafeBytes { inPtr in
                daveDecryptorDecrypt(d, media, inPtr.bindMemory(to: UInt8.self).baseAddress, frame.count,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, capacity, &written)
            }
        }
        guard code == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS else { return (nil, Int(code.rawValue)) }
        return (out.prefix(written), 0)
    }

    private func decryptor(for user: String, create: Bool) -> DAVEDecryptorHandle? {
        if let d = decryptors[user] { return d }
        guard create, let d = daveDecryptorCreate() else { return nil }
        if passthrough { daveDecryptorTransitionToPassthroughMode(d, true) }
        decryptors[user] = d
        return d
    }
}

/// What the other people sound like, mixed: one buffer of samples per speaker, pulled by the output.
final class DiscordMixer {
    private var buffers: [UInt32: [Float]] = [:]
    private var playing: Set<UInt32> = []
    private let lock = NSLock()
    private let prebuffer = 960 * 3       // 60 ms before a speaker is heard (smooths the network)
    private let limit = 960 * 20          // 400 ms: older sound is dropped

    func push(_ samples: [Float], speaker: UInt32) {
        lock.lock(); defer { lock.unlock() }
        var b = buffers[speaker] ?? []
        b.append(contentsOf: samples)
        if b.count > limit { b.removeFirst(b.count - limit) }
        buffers[speaker] = b
        if b.count >= prebuffer { playing.insert(speaker) }
    }

    func pull(_ out: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { out[i] = 0 }
        lock.lock(); defer { lock.unlock() }
        for (speaker, var b) in buffers where playing.contains(speaker) {
            let n = min(count, b.count)
            for i in 0..<n { out[i] += b[i] }
            b.removeFirst(n)
            buffers[speaker] = b
            if n < count { playing.remove(speaker) }   // ran dry: wait for the prebuffer again
        }
        for i in 0..<count { out[i] = max(-1, min(1, out[i])) }
    }

    var speakers: Int { lock.lock(); defer { lock.unlock() }; return playing.count }
}

/// A very small linear resampler for the mono sound between Discord's 48 kHz and the endpoint's rate (usually 48 kHz as well, so usually it does nothing).
struct LinearResampler {
    private var last: Float = 0
    private var phase: Double = 0

    mutating func process(_ input: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, !input.isEmpty else { return input }
        let step = Double(from) / Double(to)
        var samples = [last]; samples.append(contentsOf: input)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        var pos = phase
        while pos + 1 < Double(samples.count) {
            let i = Int(pos), f = Float(pos - Double(i))
            out.append(samples[i] * (1 - f) + samples[i + 1] * f)
            pos += step
        }
        phase = pos - Double(input.count)
        last = input[input.count - 1]
        return out
    }
}

/// The sound of one voice call: microphone -> Opus -> end-to-end encryption -> RTP -> Discord, and back. The media connection is the UDP socket the address check used.
/// Porthole is ONE audio source: the sound goes in and the microphone comes out through the game engine's single audio unit (the porthole_voice_* calls of patch 0200),
/// with this class doing all the mixing. Every 10 ms it moves what the microphone delivered out of one ring and tops up the other ring with the channel's sound.
final class DiscordAudio {
    let queue = DispatchQueue(label: "porthole.discord.audio", qos: .userInteractive)   // a game can keep every core busy; the 10 ms pump must still run on time
    let codec = DaveFrameCodec()
    var onSpeaking: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private let connection: NWConnection
    private let ssrc: UInt32
    private let key: SymmetricKey
    private let selfID: String

    private let mixer = DiscordMixer()
    private var encoder: OpaquePointer?
    private var decoders: [UInt32: OpaquePointer] = [:]
    private var users: [UInt32: String] = [:]
    private var pcm: [Float] = []
    private var running = false
    private var inGame = false
    private var muted = false
    private var micAllowed = false
    private var rate = 48000
    private var micResampler = LinearResampler()
    private var playResampler = LinearResampler()
    private var pump: DispatchSourceTimer?

    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private var nonce: UInt32 = 0
    private var speaking = false
    private var hangover = 0
    /// The level a frame has to pass to count as talking (set from the sensitivity setting).
    private var talkThreshold = MicSensitivity.threshold(percent: MicSensitivity.standard)
    private var levelPeak: Float = 0, levelFrames = 0
    /// How loud the microphone is, about ten times a second (0...1 on the meter's scale).
    var onLevel: ((Float) -> Void)?

    private var silent = 0, micSamples = 0, micOn = false
    private var captured = 0, peak: Float = 0, talkingFrames = 0, noKeys = 0, encryptFailures = 0
    private var sent = 0, received = 0, decrypted = 0, decoded = 0, aeadFailures = 0, daveFailures = 0, unknown = 0, lastDaveCode = 0
    private var statsTimer: DispatchSourceTimer?
    private var routeObservers: [NSObjectProtocol] = []
    private var callGain: Float = 1
    private var deafened = false
    /// How much louder or quieter each person is for this phone (by Discord user id); anybody not listed plays at normal.
    private var personGains: [String: Float] = [:]
    private var lastHeard: [UInt32: Date] = [:]
    private var publishedSpeakers: Set<String> = []
    private var speakTicks = 0
    /// Who is talking now, by Discord user id (people whose sound arrived in the last moments, and this account when its microphone is heard).
    var onSpeakingUsers: ((Set<String>) -> Void)?
    private var keepAliveCounter: UInt32 = 0, lastKeepAlive = Date.distantPast
    private var writtenPeak: Float = 0, lateTicks = 0, lastTick = Date(), maxGap: Double = 0, lastPlayShort: UInt64 = 0

    init(connection: NWConnection, ssrc: UInt32, secretKey: Data, selfID: String) {
        self.connection = connection
        self.ssrc = ssrc
        self.key = SymmetricKey(data: secretKey)
        self.selfID = selfID
        codec.assign(ssrc: ssrc)
    }

    // MARK: control

    func start(microphone: Bool) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            micAllowed = microphone
            var err: Int32 = 0
            encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &err)
            if let encoder { _ = porthole_opus_configure_encoder(encoder, 32000) }
            do { try startSession() } catch { onLog?("the audio session could not start: \(error.localizedDescription)"); running = false; return }
            let flags = porthole_voice_start(microphone ? 1 : 0)
            rate = Int(porthole_voice_rate())
            micOn = flags & 2 != 0
            readVolumes()
            readSensitivity()
            onLog?("one audio source: endpoint \(flags & 1 != 0 ? "running" : "NOT running") at \(rate) Hz, microphone \(micOn ? "on" : (microphone ? "NOT on" : "not allowed"))\(inGame ? ", a game is running" : "")")
            receiveLoop()
            observeRoute()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            pump = timer
            let stats = DispatchSource.makeTimerSource(queue: queue)
            stats.schedule(deadline: .now() + 5, repeating: 5)
            stats.setEventHandler { [weak self] in self?.logStats() }
            stats.resume()
            statsTimer = stats
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            pump?.cancel(); pump = nil
            statsTimer?.cancel(); statsTimer = nil
            routeObservers.forEach { NotificationCenter.default.removeObserver($0) }; routeObservers = []
            porthole_voice_stop()
            madeira_audio_set_gain_percent(Int32(Self.ownGamePercent))      // the game's own volume again
            if let encoder { opus_encoder_destroy(encoder) }
            encoder = nil
            decoders.values.forEach { opus_decoder_destroy($0) }
            decoders = [:]
            if speaking { speaking = false; onSpeaking?(false) }
            if !publishedSpeakers.isEmpty { publishedSpeakers = []; onSpeakingUsers?([]) }
            BackgroundRun.sessionManagedElsewhere = false
            UserDefaults.standard.set(false, forKey: "f4.discordVoice.now")
            if wine_process_is_running() != 0 {
                // Back to the game's own session: playback only.
                let mix = UserDefaults.standard.bool(forKey: "f4.mixAudio.now")
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: mix ? [.mixWithOthers] : [])
            }
            onLog?("audio stopped")
        }
    }

    /// The balance between the game and the call (Settings > Discord and the Discord tab of the in-game menu): the game's level at the output, 10 to 200 percent, and the call's, 0 to 200.
    static let gameVolumeKey = "f4.discord.gameVolume", callVolumeKey = "f4.discord.callVolume"

    /// What the game's volume is without Discord: the per-game MADEIRA_AUDIO_GAIN when it is set in this process, else 100.
    private static var ownGamePercent: Int {
        if let text = getenv("MADEIRA_AUDIO_GAIN"), let v = Int(String(cString: text)), (10...200).contains(v) { return v }
        return 100
    }

    func applyVolumes() { queue.async { [self] in readVolumes() } }
    func setPersonGains(_ gains: [String: Float]) { queue.async { [self] in personGains = gains } }
    func applySensitivity() { queue.async { [self] in readSensitivity() } }

    private func readSensitivity() {
        let percent = MicSensitivity.saved
        talkThreshold = MicSensitivity.threshold(percent: percent)
        onLog?("microphone sensitivity \(Int(percent)) % (talking above level \(String(format: "%.4f", talkThreshold)))")
    }

    private func readVolumes() {
        let defaults = UserDefaults.standard
        let game = min(max(defaults.object(forKey: Self.gameVolumeKey) as? Double ?? 100, 10), 200)
        let call = min(max(defaults.object(forKey: Self.callVolumeKey) as? Double ?? 100, 0), 200)
        callGain = Float(call / 100)
        if running { madeira_audio_set_gain_percent(Int32(game.rounded())) }
        onLog?("volume: the game at \(Int(game.rounded()))%, the call at \(Int(call.rounded()))%")
    }

    func setMuted(_ on: Bool) { queue.async { [self] in muted = on; onLog?("microphone \(on ? "muted" : "unmuted")") } }

    /// Echo reduction (experimental): while the call is being played, a microphone frame that is not clearly louder than the speakers is taken for their echo and not sent.
    private var reduceEcho = false
    private var echo = EchoSuppressor()
    private var echoFrames: UInt64 = 0
    func setReduceEcho(_ on: Bool) {
        queue.async { [self] in
            if on != reduceEcho { onLog?("echo reduction \(on ? "on" : "off")") }
            reduceEcho = on
        }
    }

    /// Push to talk: with it on, the microphone sends only while the talk button is held (and it is not muted). Discord is not told: nobody sees a mute, the person simply speaks when they press.
    private var pushToTalk = false
    private var talkHeld = false
    private var gated: Bool { muted || (pushToTalk && !talkHeld) }
    func setPushToTalk(enabled: Bool, held: Bool) {
        queue.async { [self] in
            if enabled != pushToTalk { onLog?("push to talk \(enabled ? "on" : "off")") }
            pushToTalk = enabled; talkHeld = held
        }
    }
    func setDeafened(_ on: Bool) { queue.async { [self] in deafened = on; onLog?("call sound \(on ? "off (deafened)" : "on")") } }

    /// Says when the phone's audio route or session changes (a game start, headphones, a call or Siri taking the microphone).
    private func observeRoute() {
        let center = NotificationCenter.default
        routeObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "?"
            self?.queue.async { self?.onLog?("audio route changed (reason \(reason)): \(self?.routeText() ?? "")") }
        })
        routeObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).map(String.init) ?? "?"
            self?.queue.async { self?.onLog?("audio interruption (type \(type), 1 = began, 0 = ended)") }
        })
    }

    private func routeText() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        return "in \(route.inputs.map { $0.portType.rawValue }.joined(separator: ",")), out \(route.outputs.map { $0.portType.rawValue }.joined(separator: ",")), category \(session.category.rawValue) options \(session.categoryOptions.rawValue), volume \(String(format: "%.2f", session.outputVolume))"
    }

    func mapSSRC(_ ssrc: UInt32, user: String) { queue.async { [self] in users[ssrc] = user } }

    func setRatchet(user: String, ratchet: DaveKeyRatchet?, version: UInt16) {
        queue.async { [self] in codec.setRatchet(user: user, isSelf: user == selfID, ratchet: ratchet, version: version) }
    }

    var speakers: Int { mixer.speakers }

    // MARK: the one audio source

    private func startSession() throws {
        let session = AVAudioSession.sharedInstance()
        BackgroundRun.sessionManagedElsewhere = true
        UserDefaults.standard.set(true, forKey: "f4.discordVoice.now")      // a game that starts keeps the microphone (WineProcessBridge.m, SessionController)
        inGame = wine_process_is_running() != 0
        if inGame {
            // The game's sound goes out through the same unit: stay on its terms, headset output over A2DP (the phone's own microphone then).
            let mix = UserDefaults.standard.bool(forKey: "f4.mixAudio.now")
            try session.setCategory(.playAndRecord, mode: .default, options: AVAudioSession.CategoryOptions([.defaultToSpeaker, .allowBluetoothA2DP]).union(mix ? .mixWithOthers : []))
        } else {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        }
        try session.setActive(true)
        onLog?("audio route: in \(session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")), out \(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
    }

    /// Every 10 ms: what the microphone delivered goes out, the speaker's ring is topped up to 60 ms.
    private func tick() {
        guard running else { return }
        let now = Date()
        speakTicks += 1
        if speakTicks % 10 == 0 { updateSpeakers(now) }
        let gap = now.timeIntervalSince(lastTick)
        lastTick = now
        maxGap = max(maxGap, gap)
        if gap > 0.04 { lateTicks += 1 }
        // Discord's voice server stops sending sound to a client it hears nothing from (a muted microphone sends nothing): a small packet every 5 seconds keeps the path open.
        if now.timeIntervalSince(lastKeepAlive) >= 4 {
            lastKeepAlive = now
            keepAliveCounter &+= 1
            var packet = Data(Self.be32(keepAliveCounter)); packet.append(Data(count: 4))
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
        var buf = [Float](repeating: 0, count: 4096)
        let n = porthole_voice_read(&buf, 4096)
        if n > 0 {
            micSamples += n
            let mono = micResampler.process(Array(buf.prefix(n)), from: rate, to: 48000)
            pcm.append(contentsOf: mono)
            while pcm.count >= 960 {
                let frame = Array(pcm.prefix(960))
                pcm.removeFirst(960)
                send(frame)
            }
        }
        let target = rate * (inGame ? 120 : 60) / 1000     // a game keeps the cores busy: keep more sound ready
        let fill = porthole_voice_playback_fill()
        if fill < target {
            let need = target - fill
            let count48 = (need * 48000 + rate - 1) / rate
            var mixed = [Float](repeating: 0, count: count48)
            mixed.withUnsafeMutableBufferPointer { mixer.pull($0.baseAddress!, count: count48) }
            if deafened { for i in mixed.indices { mixed[i] = 0 } }
            else if callGain != 1 { for i in mixed.indices { mixed[i] = max(-1, min(1, mixed[i] * callGain)) } }
            let out = playResampler.process(mixed, from: 48000, to: rate)
            for v in out { writtenPeak = max(writtenPeak, abs(v)) }
            _ = porthole_voice_write(out, out.count)
        }
    }

    private func updateSpeakers(_ now: Date) {
        var ids = Set<String>()
        for (ssrc, time) in lastHeard where now.timeIntervalSince(time) < 0.4 { if let user = users[ssrc] { ids.insert(user) } }
        if speaking && !gated { ids.insert(selfID) }
        guard ids != publishedSpeakers else { return }
        publishedSpeakers = ids
        onSpeakingUsers?(ids)
    }

    // MARK: sending

    private func send(_ frame: [Float]) {
        guard !gated, let encoder else { return }
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        captured += 1
        peak = max(peak, rms)
        levelPeak = max(levelPeak, rms); levelFrames += 1
        if levelFrames >= 5 { onLevel?(MicSensitivity.meterPosition(rms: levelPeak)); levelPeak = 0; levelFrames = 0 }
        echo.tick()
        let echoed = reduceEcho && echo.isEcho(micRMS: rms)
        if echoed { echoFrames += 1; hangover = 0 } else if rms > talkThreshold { hangover = 15 } else if hangover > 0 { hangover -= 1 }
        let talking = hangover > 0
        if talking != speaking { speaking = talking; onSpeaking?(talking) }
        timestamp &+= 960
        if talking { talkingFrames += 1 }
        guard talking else { return }
        guard codec.canEncrypt else { noKeys += 1; return }

        var opus = [UInt8](repeating: 0, count: 1275)
        let n = opus_encode_float(encoder, frame, 960, &opus, 1275)
        guard n > 0, let framed = codec.encrypt(Data(opus.prefix(Int(n))), ssrc: ssrc) else { encryptFailures += 1; return }

        var header = Data([0x80, 0x78])
        header.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
        header.append(contentsOf: Self.be32(timestamp))
        header.append(contentsOf: Self.be32(ssrc))
        sequence &+= 1
        nonce &+= 1
        var iv = Data(Self.be32(nonce)); iv.append(Data(count: 8))
        guard let gcmNonce = try? AES.GCM.Nonce(data: iv), let sealed = try? AES.GCM.seal(framed, using: key, nonce: gcmNonce, authenticating: header) else { return }
        var packet = header
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        packet.append(contentsOf: Self.be32(nonce))
        connection.send(content: packet, completion: .contentProcessed { _ in })
        sent += 1
    }

    // MARK: receiving

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                if let data { self.receive(data) }
                if error == nil { self.receiveLoop() }
            }
        }
    }

    private func receive(_ data: Data) {
        guard data.count > 12 + 16 + 4, data[0] & 0xC0 == 0x80, data[1] & 0x7F == 0x78 else { return }
        received += 1
        let b = [UInt8](data)
        let csrc = Int(b[0] & 0x0F) * 4
        let hasExtension = b[0] & 0x10 != 0
        var aadLength = 12 + csrc
        var extensionWords = 0
        if hasExtension {
            guard b.count > aadLength + 4 else { return }
            extensionWords = Int(b[aadLength + 2]) << 8 | Int(b[aadLength + 3])
            aadLength += 4
        }
        let sourceID = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        guard b.count > aadLength + 16 + 4 else { return }
        let nonceBytes = Array(b[(b.count - 4)...])
        var iv = Data(nonceBytes); iv.append(Data(count: 8))
        let tag = Data(b[(b.count - 4 - 16)..<(b.count - 4)])
        let cipher = Data(b[aadLength..<(b.count - 4 - 16)])
        guard let gcmNonce = try? AES.GCM.Nonce(data: iv), let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: cipher, tag: tag),
              var plain = try? AES.GCM.open(box, using: key, authenticating: Data(b[0..<aadLength])) else { aeadFailures += 1; return }
        decrypted += 1
        if extensionWords > 0 { plain = plain.dropFirst(min(plain.count, extensionWords * 4)) }
        guard let user = users[sourceID] else { unknown += 1; return }
        // Discord's own clients send Opus' 3-byte silence frame unencrypted between speech: nothing to decrypt or play.
        if plain.count == 3, plain[plain.startIndex] == 0xF8, plain[plain.startIndex + 1] == 0xFF, plain[plain.startIndex + 2] == 0xFE { silent += 1; return }
        let (frame, code) = codec.decrypt(Data(plain), user: user)
        guard let frame, !frame.isEmpty else { daveFailures += 1; lastDaveCode = code; return }
        let decoder = decoders[sourceID] ?? {
            var err: Int32 = 0
            let d = opus_decoder_create(48000, 1, &err)
            if let d { decoders[sourceID] = d }
            return d
        }()
        guard let decoder else { return }
        var out = [Float](repeating: 0, count: 960 * 6)
        let n = frame.withUnsafeBytes { opus_decode_float(decoder, $0.bindMemory(to: UInt8.self).baseAddress, Int32(frame.count), &out, 960 * 6, 0) }
        guard n > 0 else { return }
        decoded += 1
        lastHeard[sourceID] = Date()
        var samples = Array(out.prefix(Int(n)))
        let gain = personGains[user] ?? 1
        if gain != 1 { for i in samples.indices { samples[i] *= gain } }
        if gain > 0 { echo.played(rms: EchoSuppressor.rms(samples)); mixer.push(samples, speaker: sourceID) }      // a muted person is still "heard" for the talking ring above, just not played
    }

    private func logStats() {
        if reduceEcho { onLog?("echo reduction: \(echoFrames) microphone frames held back as the speakers' own sound") }
        onLog?("microphone: \(micSamples) samples from the microphone, \(captured) frames heard (loudest \(String(format: "%.3f", peak))), \(talkingFrames) counted as talking, \(noKeys) held back for lack of keys, \(encryptFailures) failed to encrypt)")
        peak = 0
        var drops: UInt64 = 0, short: UInt64 = 0, errs: UInt64 = 0
        porthole_voice_stats(&drops, &short, &errs)
        onLog?("speaker: sound written to the output peaked at \(String(format: "%.3f", writtenPeak)), ring holds \(porthole_voice_playback_fill()) frames, output ran short \(short - lastPlayShort) frames in 5 s (\(short) in all), microphone dropped \(drops), microphone read errors \(errs); pump late \(lateTicks) times, longest gap \(Int(maxGap * 1000)) ms; muted \(muted); \(routeText())")
        writtenPeak = 0; lateTicks = 0; maxGap = 0; lastPlayShort = short
        onLog?("audio: sent \(sent), received \(received) (\(decrypted) opened, \(decoded) played, \(silent) silence, \(unknown) from unknown speakers, \(aeadFailures) failed the transport check, \(daveFailures) failed the end-to-end check\(daveFailures > 0 ? " (last code \(lastDaveCode))" : "")), hearing \(mixer.speakers)")
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
