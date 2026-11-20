// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import AVFoundation
import CoreMedia
import Foundation
import UIKit

// Watching somebody's Go Live (Discord branch, experimental). A stream is a second voice connection that Discord sets up for it (see DiscordStream, which sends one); a viewer
// asks for it with the main connection's "watch stream" message, is given the stream's own address and token, joins that connection with two receive-only tracks and its own
// end-to-end keys, and opens the streamer's pictures and sound with the streamer's key. The pictures are H.264 and go to a display layer, which decodes and shows them.
// Every step logs a [discord-watch] line: nothing here has been tried against a real stream yet, and the log is how a failure is told apart.

/// Where the pictures go: the display layer on the screen. Pictures that arrive while no layer is attached are dropped.
final class DiscordPictureSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock(); self.layer = layer; lock.unlock()
        // The layer shows each picture when its clock reaches the picture's time; the clock is the phone's own, so a time is simply "that moment" (see DiscordPlayout).
        guard let layer else { return }
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
    }

    func show(_ sample: CMSampleBuffer) {
        lock.lock(); let layer = self.layer; lock.unlock()
        guard let layer else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }

    func clear() { lock.lock(); let layer = self.layer; lock.unlock(); layer?.flushAndRemoveImage() }
}

/// The stream's sound: Opus from the streamer, played through its own small engine so it does not touch the voice call's audio path.
final class DiscordStreamSound: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private let lock = NSLock()
    private var queued = 0
    private var running = false
    private(set) var played = 0, dropped = 0
    var muted = false

    func start() {
        guard !running else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start(); player.play(); running = true } catch { LogStore.shared.log("[discord-watch] the stream's sound could not start: \(error.localizedDescription)") }
    }

    /// Interleaved stereo samples at 48 kHz.
    func play(_ interleaved: [Float], frames: Int) {
        guard running, !muted, frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        lock.lock()
        let backlog = queued
        lock.unlock()
        if backlog > 48000 * 4 / 10 { dropped += 1; return }          // more than 0.4 s waiting: the sound ran behind, drop instead of lagging further
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return }
        for i in 0..<frames { left[i] = interleaved[i * 2]; right[i] = interleaved[i * 2 + 1] }
        lock.lock(); queued += frames; lock.unlock()
        played += 1
        player.scheduleBuffer(buffer) { [weak self] in self?.lock.lock(); self?.queued -= frames; self?.lock.unlock() }
    }

    func stop() {
        guard running else { return }
        running = false
        player.stop(); engine.stop()
        engine.detach(player)
    }
}

@MainActor
final class DiscordStreamViewer {
    enum State: Equatable { case idle, connecting, waiting, watching, failed(String) }

    var onState: ((State) -> Void)?
    /// The picture's size in pixels, once known.
    var onSize: ((CGSize) -> Void)?
    private(set) var state: State = .idle { didSet { if state != oldValue { onState?(state) } } }
    let sink = DiscordPictureSink()
    private let sound = DiscordStreamSound()
    var muted: Bool { get { sound.muted } set { sound.muted = newValue } }

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var stopped = true
    private var seq = -1
    private var identify: [String: Any] = [:]
    private var dave: DaveManager?
    private var rtc: DiscordWebRTCReceiver?
    private var variant = DiscordWatchVariant.all[0]
    private var variantIndex = 0
    private var streamerID = ""
    private var userID = ""
    private var serverAnswer: String?
    private var applied = false
    private var audioSSRC: UInt32?, videoSSRC: UInt32?, rtxSSRC: UInt32?
    private var ownSSRC: UInt32 = 1
    private var connectionName = "none"
    private var timeout: Task<Void, Never>?
    private let mediaQueue = DispatchQueue(label: "porthole.discord.watch", qos: .userInitiated)
    private var statsTimer: DispatchSourceTimer?

    // Everything below is used on the media queue only.
    private let codec = DaveFrameCodec()
    private let depacketizer = DiscordH264Depacketizer()
    private let sampler = DiscordH264Sampler()
    private let reorder = DiscordRTPReorder()
    private let playout = DiscordPlayout()
    private let pacer = DiscordSteadyPacer()
    /// How pictures are paced (changed from the screen while watching; read on the media queue).
    var pacing = DiscordPacing.saved
    private var arrivalGaps: [Double] = [], stampGaps: [Double] = []
    private var lastStamp: UInt32?
    private var negativeStamps = 0
    private var pairDump: [String] = []
    private var slowest = 0.0, lastArrival = 0.0, longestGap = 0.0
    private var lastReport = (received: 0, highest: UInt32(0))
    private var resent = 0
    private var opusDecoder: OpaquePointer?
    private var waitingForKey = true
    private var lastKeyRequest = Date.distantPast
    private var counts = (pictures: 0, shown: 0, lost: 0, undecryptable: 0, soundHeard: 0, soundSilent: 0, soundUndecryptable: 0, otherPackets: 0)
    private var lastDaveCode = 0
    private var startStyle = 1
    private var openedOnce = false
    private var failureDumps = 0
    private var firstShown = false
    private var announcedSize = CGSize.zero

    private func log(_ line: String) { LogStore.shared.log("[discord-watch] \(line)") }

    /// Joins the stream server `endpoint` with the stream's `token`, to watch what `streamerID` shows.
    func connect(endpoint: String, rtcServerID: String, userID: String, sessionID: String, token: String, streamerID: String) {
        stop(silently: true)
        stopped = false
        state = .connecting
        self.streamerID = streamerID; self.userID = userID
        seq = -1; applied = false; serverAnswer = nil; audioSSRC = nil; videoSSRC = nil; rtxSSRC = nil; connectionName = "none"
        let chosen = DiscordWatchVariant.next()
        variant = chosen.variant; variantIndex = chosen.index
        log("VARIANT \(chosen.index): \(chosen.variant.name)")
        mediaQueue.sync {
            counts = (0, 0, 0, 0, 0, 0, 0, 0); waitingForKey = true; lastKeyRequest = .distantPast; firstShown = false; announcedSize = .zero; lastDaveCode = 0; startStyle = 1; openedOnce = false; failureDumps = 0
            depacketizer.reset(); sampler.reset(); reorder.reset(); playout.reset(); pacer.reset(); arrivalGaps = []; stampGaps = []; lastStamp = nil; negativeStamps = 0; pairDump = []; slowest = 0; lastArrival = 0; longestGap = 0; lastReport = (0, 0)
            resent = 0
        }
        identify = ["server_id": rtcServerID, "user_id": userID, "session_id": sessionID, "token": token, "video": true, "max_dave_protocol_version": Int(daveMaxSupportedProtocolVersion())]
        if variant.identifyStreams { identify["streams"] = [["type": "screen", "rid": "100", "quality": 100]] }
        // The stream has its own end-to-end encryption group, named by the stream's server id minus one.
        dave = DaveManager(selfUserID: userID, groupID: (UInt64(rtcServerID) ?? 1) &- 1)
        dave?.output = { [weak self] out in self?.daveOutput(out) }
        dave?.onRatchet = { [weak self] user, ratchet, version in
            guard let self else { return }
            self.log("encryption keys for \(user == userID ? "this account" : user == streamerID ? "the streamer" : "another member"), protocol version \(version)\(ratchet == nil ? ", no key ratchet" : "")")
            self.mediaQueue.async { self.codec.setRatchet(user: user, isSelf: user == userID, ratchet: ratchet, version: version); self.waitingForKey = true }
        }
        dave?.onStatus = { [weak self] line in self?.log("encryption: \(line)") }
        let host = endpoint.replacingOccurrences(of: ":80", with: "")
        guard let url = URL(string: "wss://\(host)/?v=8") else { state = .failed("Discord sent a stream address this version cannot read."); return }
        var request = URLRequest(url: url)
        request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        log("connecting to the stream server")
        Task { await receiveLoop(task) }
        // No picture after a while: say so, and the next attempt tries another variant.
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled, !self.stopped, self.state != .watching else { return }
            self.log("no picture after 25 s (connection \(self.connectionName))")
            self.fail("The stream did not send a picture. Try watching again (it tries a different way each time).")
        }
    }

    func stop(silently: Bool = false) {
        stopped = true
        timeout?.cancel(); timeout = nil
        heartbeat?.cancel()
        statsTimer?.cancel(); statsTimer = nil
        mediaQueue.sync { [self] in
            rtc?.close(); rtc = nil
            if let opusDecoder { opus_decoder_destroy(opusDecoder); self.opusDecoder = nil }
        }
        sound.stop()
        sink.clear()
        dave = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        if !silently { state = .idle }
    }

    private func fail(_ why: String) {
        guard !stopped else { return }
        stop(silently: true)
        state = .failed(why)
    }

    private func send(_ op: Int, _ d: Any) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: ["op": op, "d": d]), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func sendBinary(_ op: UInt8, _ payload: Data) { task?.send(.data(Data([op]) + payload)) { _ in } }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !stopped {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): handle(text)
                case .data(let data): handleBinary(data)
                @unknown default: break
                }
            } catch {
                if stopped { return }
                let code = task.closeCode.rawValue
                heartbeat?.cancel()
                self.task = nil
                log("closed with code \(code)")
                if state != .idle { fail("The stream connection ended (code \(code)).") }
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let op = object["op"] as? Int else { return }
        if let s = object["seq"] as? Int { seq = s }
        let d = object["d"] as? [String: Any] ?? [:]
        if op != 6 { log("message op \(op) fields: \(d.keys.sorted().filter { $0 != "secret_key" && $0 != "token" && $0 != "sdp" }.joined(separator: ","))") }
        switch op {
        case 8:
            startHeartbeat(interval: (d["heartbeat_interval"] as? Double ?? 41250) / 1000)
            send(0, identify)
        case 2:
            if let s = d["ssrc"] as? Int { ownSSRC = UInt32(truncatingIfNeeded: s) }
            log("ready: modes \((d["modes"] as? [String] ?? []).joined(separator: ", ")); \((d["streams"] as? [[String: Any]])?.count ?? 0) stream(s) listed")
            startConnection()
        case 4:
            let version = d["dave_protocol_version"] as? Int ?? 0
            log("session accepted: video codec \(d["video_codec"] as? String ?? "?"), audio codec \(d["audio_codec"] as? String ?? "?"), end-to-end encryption version \(version)")
            guard let sdp = d["sdp"] as? String else { log("the server's answer carries no connection description"); fail("Discord's stream server did not answer the connection request."); return }
            serverAnswer = sdp
            dave?.onSessionDescription(version: UInt16(truncatingIfNeeded: version))
            send(15, ["any": 100])                      // ask for the streamer's picture
            applyAnswerWhenReady()
        case 12:      // the streamer's sound and picture numbers
            guard (d["user_id"] as? String) == streamerID else { break }
            if let a = d["audio_ssrc"] as? Int, a != 0 { audioSSRC = UInt32(truncatingIfNeeded: a) }
            if let first = (d["streams"] as? [[String: Any]])?.first, let v = first["ssrc"] as? Int, v != 0 {
                videoSSRC = UInt32(truncatingIfNeeded: v)
                if let r = first["rtx_ssrc"] as? Int, r != 0 { rtxSSRC = UInt32(truncatingIfNeeded: r) }
            }
            else if let v = d["video_ssrc"] as? Int, v != 0 { videoSSRC = UInt32(truncatingIfNeeded: v) }
            log("the streamer's numbers: sound \(audioSSRC.map(String.init) ?? "?"), picture \(videoSSRC.map(String.init) ?? "?"), resend \(rtxSSRC.map(String.init) ?? "none")")
            applyAnswerWhenReady()
        case 5:
            if (d["user_id"] as? String) == streamerID, audioSSRC == nil, let a = d["ssrc"] as? Int { audioSSRC = UInt32(truncatingIfNeeded: a); log("the streamer's sound number from a speaking message: \(a)") }
        case 21: dave?.onPrepareTransition(id: d["transition_id"] as? Int ?? 0, version: UInt16(truncatingIfNeeded: d["protocol_version"] as? Int ?? 0))
        case 22: dave?.onExecuteTransition(id: d["transition_id"] as? Int ?? 0)
        case 24:
            let epoch = (d["epoch"] as? Int) ?? Int(d["epoch"] as? String ?? "") ?? 0
            dave?.onPrepareEpoch(epoch: epoch, version: UInt16(truncatingIfNeeded: d["protocol_version"] as? Int ?? 0))
        case 11: for id in (d["user_ids"] as? [String] ?? []) { dave?.createUser(id) }
        case 13: if let id = d["user_id"] as? String { dave?.destroyUser(id) }
        case 6, 18, 20: break
        default: log("message with opcode \(op)")
        }
    }

    private func handleBinary(_ data: Data) {
        guard data.count >= 3 else { return }
        seq = Int(data[0]) << 8 | Int(data[1])
        let op = Int(data[2])
        let payload = data.dropFirst(3)
        switch op {
        case 25: dave?.onExternalSender(Data(payload))
        case 27: dave?.onProposals(Data(payload))
        case 29, 30:
            guard payload.count > 2 else { return }
            let id = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
            let rest = Data(payload.dropFirst(2))
            if op == 29 { dave?.onCommit(transitionID: id, commit: rest) } else { dave?.onWelcome(transitionID: id, welcome: rest) }
        default: log("binary message with opcode \(op)")
        }
    }

    private func daveOutput(_ out: DaveManager.Output) {
        switch out {
        case .keyPackage(let bytes): sendBinary(26, bytes)
        case .commitWelcome(let bytes): sendBinary(28, bytes)
        case .readyForTransition(let id): send(23, ["transition_id": id])
        case .invalidCommitWelcome(let id): send(31, ["transition_id": id])
        }
    }

    private func startHeartbeat(interval: Double) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await MainActor.run {
                    guard let self, !self.stopped else { return }
                    self.send(3, ["t": Int(Date().timeIntervalSince1970 * 1000), "seq_ack": self.seq])
                }
            }
        }
    }

    // MARK: The connection

    private func startConnection() {
        rtc?.close()
        let rtc = DiscordWebRTCReceiver(variant: variant)
        self.rtc = rtc
        rtc.log = { [weak self] line in Task { @MainActor in self?.log(line) } }
        rtc.onOffer = { [weak self] sdp in Task { @MainActor in self?.sendOffer(sdp) } }
        rtc.onState = { [weak self] name in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.connectionName = name
                self.log("connection: \(name)")
                if name == "failed" || name == "ice failed" { self.fail("The connection to Discord's stream server failed (\(name)).") }
            }
        }
        rtc.onVideo = { [weak self] data in self?.mediaQueue.async { self?.handleVideo(data) } }
        rtc.onAudio = { [weak self] data in self?.mediaQueue.async { self?.handleAudio(data) } }
        if !rtc.start() { fail("The phone's WebRTC connection could not start.") }
    }

    private func sendOffer(_ sdp: String) {
        log("offer (\(sdp.count) characters)")
        send(1, ["protocol": "webrtc", "codecs": DiscordCodecs.viewerList, "data": sdp, "sdp": sdp, "rtc_connection_id": UUID().uuidString.lowercased()])
    }

    /// The server's answer is applied once the streamer's numbers are known (they tell the library which track each packet belongs to), or after a short wait without them.
    private func applyAnswerWhenReady() {
        guard !applied, let answer = serverAnswer, let rtc else { return }
        if videoSSRC != nil && audioSSRC != nil { apply(answer, rtc) ; return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard let self, !self.applied, let answer = self.serverAnswer, let rtc = self.rtc else { return }
            self.log("applying the answer without all of the streamer's numbers (sound \(self.audioSSRC.map(String.init) ?? "none"), picture \(self.videoSSRC.map(String.init) ?? "none"))")
            self.apply(answer, rtc)
        }
    }

    private func apply(_ answer: String, _ rtc: DiscordWebRTCReceiver) {
        guard !applied else { return }
        applied = true
        let ok = rtc.setAnswer(serverSDP: answer, audioSSRC: audioSSRC, videoSSRC: videoSSRC, rtxSSRC: rtxSSRC)
        log("answer given to the connection: \(ok ? "accepted" : "refused")")
        if !ok { fail("Discord's stream server's answer could not be used."); return }
        state = .waiting
        sound.start()
        let stats = DispatchSource.makeTimerSource(queue: mediaQueue)
        stats.schedule(deadline: .now() + 0.02, repeating: 0.02)
        var tick = 0
        stats.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            self.pump(self.reorder.tick(now: ProcessInfo.processInfo.systemUptime))
            if tick % 25 == 0 { self.keyRequestIfNeeded() }
            if tick % 50 == 0 { self.sendReceiverReport() }
            if tick % 250 == 0 { self.logStats() }
        }
        stats.resume()
        statsTimer = stats
    }

    // MARK: Media (media queue)

    private func handleVideo(_ data: Data) {
        guard let p = DiscordRTPPacket.parse(data) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if p.payloadType == UInt8(DiscordCodecs.h264RTX) {
            // A resend: the original packet is inside it.
            guard let wanted = videoSSRC, let original = p.restoringRTX(payloadType: UInt8(DiscordCodecs.h264), ssrc: wanted) else { counts.otherPackets += 1; return }
            resent += 1
            pump(reorder.push(original, now: now, restored: true))
            return
        }
        guard p.payloadType == UInt8(DiscordCodecs.h264) else { counts.otherPackets += 1; return }
        if let wanted = videoSSRC, p.ssrc != wanted { counts.otherPackets += 1; return }
        pump(reorder.push(p, now: now))
    }

    /// What the reorder buffer gives: packets in order for the depacketizer, resend requests to send, and a note when something was given up on.
    private func pump(_ out: DiscordRTPReorder.Output) {
        if !out.nack.isEmpty, let ssrc = videoSSRC, let message = DiscordRTCP.nack(sender: ownSSRC, media: ssrc, missing: out.nack) { rtc?.sendRTCP(message) }
        if out.gaveUp { counts.lost += 1; waitingForKey = true; depacketizer.noteLoss() }
        for p in out.packets { handlePacket(p) }
    }

    private func handlePacket(_ p: DiscordRTPPacket) {
        switch depacketizer.push(p) {
        case .none: break
        case .lost: waitingForKey = true
        case .picture(let unit, let isKey, let stamp):
            counts.pictures += 1
            let arrival = ProcessInfo.processInfo.systemUptime
            if lastArrival > 0 {
                longestGap = max(longestGap, arrival - lastArrival)
                arrivalGaps.append(arrival - lastArrival)
                if let last = lastStamp {
                    let delta = Double(Int32(bitPattern: stamp &- last)) / 90.0       // milliseconds
                    if delta < 0 { negativeStamps += 1 }
                    stampGaps.append(delta)
                    if pairDump.count < 120, firstShown { pairDump.append("\(Int((arrival - lastArrival) * 1000))/\(Int(delta))") }
                }
            }
            lastArrival = arrival; lastStamp = stamp
            if waitingForKey, !isKey { return }              // a damaged picture would show as smears: wait for a key frame
            guard let plain = open(depacketizer.lastNals, first: unit) else { counts.undecryptable += 1; return }
            // Shown when the playout says (a short, adaptive time after the sender made it), in the phone's clock: the uptime clock and the layer's host clock tick together.
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            // Both timings are kept up to date whatever is used, so the log can compare them.
            let bySender = playout.schedule(timestamp: stamp, arrival: arrival) - arrival
            let bySteady = pacer.schedule(arrival: arrival) - arrival
            let mode = pacing
            let showAt = hostNow + (mode == .senderClock ? bySender : bySteady)
            guard let sample = sampler.sample(from: plain, at: CMTime(seconds: showAt, preferredTimescale: 90000), immediately: mode == .instant) else { waitingForKey = true; return }
            if isKey { waitingForKey = false }
            sink.show(sample)
            slowest = max(slowest, ProcessInfo.processInfo.systemUptime - arrival)
            counts.shown += 1
            if sampler.size != announcedSize {
                announcedSize = sampler.size
                let size = sampler.size
                Task { @MainActor in self.onSize?(size) }
            }
            if !firstShown {
                firstShown = true
                let size = sampler.size
                Task { @MainActor in
                    self.log("the first picture is showing (\(Int(size.width))x\(Int(size.height)))")
                    DiscordWatchVariant.worked(self.variantIndex)
                    self.timeout?.cancel()
                    self.state = .watching
                }
            }
        }
    }

    /// The streamer's end-to-end encryption removed from a picture. A picture that carries no encryption (before the keys, or an unencrypted stream) passes as it is.
    private func open(_ nals: [Data], first unit: Data) -> Data? {
        // The encryption covers the start codes, so the picture is put back together with the ones the sender used: the style that worked last time first, then the others.
        let order = [startStyle] + (0..<DiscordH264Depacketizer.startStyles).filter { $0 != startStyle }
        for (n, style) in order.enumerated() {
            let candidate = style == 0 ? unit : DiscordH264Depacketizer.annexB(nals, style: style)
            let (plain, code) = codec.decrypt(candidate, user: streamerID, media: DAVE_MEDIA_TYPE_VIDEO)
            lastDaveCode = code
            if let plain, !plain.isEmpty {
                if n > 0 || !openedOnce {
                    let found = style
                    Task { @MainActor in self.log("pictures open with start codes style \(found) (\(["three bytes", "four bytes", "four bytes first, then three"][found]))") }
                }
                startStyle = style; openedOnce = true
                return plain
            }
            if openedOnce { break }      // it worked before: a single failure is a damaged picture, not a different layout
        }
        if failureDumps < 2 {
            failureDumps += 1
            let head = unit.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            let tail = unit.suffix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
            let shape = nals.prefix(8).map { "\(($0.first ?? 0) & 0x1F):\($0.count)" }.joined(separator: " ")
            Task { @MainActor in self.log("a key frame would not open: \(unit.count) bytes, NAL units (type:size) [\(shape)], begins \(head), ends \(tail)") }
        }
        return nil
    }

    private func handleAudio(_ data: Data) {
        guard let p = DiscordRTPPacket.parse(data), p.payloadType == UInt8(DiscordCodecs.opus), !p.payload.isEmpty else { return }
        if let wanted = audioSSRC, p.ssrc != wanted { return }
        let payload = p.payload
        if payload.count == 3, payload[payload.startIndex] == 0xF8, payload[payload.startIndex + 1] == 0xFF, payload[payload.startIndex + 2] == 0xFE { counts.soundSilent += 1; return }
        let (frame, code) = codec.decrypt(payload, user: streamerID, media: DAVE_MEDIA_TYPE_AUDIO)
        guard let frame, !frame.isEmpty else { counts.soundUndecryptable += 1; lastDaveCode = code; return }
        if opusDecoder == nil { var err: Int32 = 0; opusDecoder = opus_decoder_create(48000, 2, &err) }
        guard let decoder = opusDecoder else { return }
        var out = [Float](repeating: 0, count: 960 * 6 * 2)
        let n = frame.withUnsafeBytes { opus_decode_float(decoder, $0.bindMemory(to: UInt8.self).baseAddress, Int32(frame.count), &out, 960 * 6, 0) }
        guard n > 0 else { return }
        counts.soundHeard += 1
        sound.play(out, frames: Int(n))
    }

    private func keyRequestIfNeeded() {
        // Before the first picture the request is repeated twice a second (the streamer's own key frames can be seconds apart); after it, at most every 1.5 s.
        let every = firstShown ? 1.5 : 0.5
        guard waitingForKey, Date().timeIntervalSince(lastKeyRequest) >= every, let ssrc = videoSSRC else { return }
        // A request sent before the connection is open goes nowhere: only a request that went counts.
        if rtc?.sendRTCP(DiscordRTCP.pictureLoss(sender: ownSSRC, media: ssrc)) == true { lastKeyRequest = Date() }
    }

    /// Tells the sender how much of its picture arrives (it adapts to this).
    private func sendReceiverReport() {
        guard let ssrc = videoSSRC, reorder.received > 0 else { return }
        let highest = reorder.extendedHighest
        let expected = Int(highest &- lastReport.highest), got = reorder.received - lastReport.received
        let lost = max(0, expected - got)
        let fraction = expected > 0 ? UInt8(min(255, lost * 256 / max(expected, 1))) : 0
        lastReport = (reorder.received, highest)
        rtc?.sendRTCP(DiscordRTCP.receiverReport(sender: ownSSRC, source: ssrc, fractionLost: fraction, cumulativeLost: reorder.givenUp, highestSequence: highest))
    }

    /// What the pictures' own stamps say next to when they came, over the last few seconds: the numbers that show whether the sender's clock can be trusted.
    private func pacingSummary() -> String? {
        guard arrivalGaps.count > 20 else { return nil }
        func stats(_ values: [Double], scale: Double) -> String {
            let v = values.map { $0 * scale }.sorted()
            func p(_ q: Double) -> Int { Int(v[min(v.count - 1, Int(Double(v.count) * q))]) }
            return "middle \(p(0.5)) ms, 90% under \(p(0.9)) ms, 99% under \(p(0.99)) ms, longest \(Int(v.last ?? 0)) ms"
        }
        let arrivalSpan = arrivalGaps.reduce(0, +), stampSpan = stampGaps.reduce(0, +) / 1000
        var line = "picture rhythm over \(arrivalGaps.count) pictures: apart on arrival: \(stats(arrivalGaps, scale: 1000)); apart by the sender's stamps: \(stats(stampGaps.map { max(0, $0) }, scale: 1)); the stamps cover \(String(format: "%.1f", stampSpan)) s while \(String(format: "%.1f", arrivalSpan)) s passed; \(negativeStamps) stamps went backwards; steady pacer: usual interval \(Int(pacer.usualInterval * 1000)) ms, buffer up to \(Int(pacer.worstBacklog * 1000)) ms, ran dry \(pacer.dry) times, caught up \(pacer.squeezed) times"
        if !pairDump.isEmpty { line += "; first pictures (ms apart on arrival / by stamp): \(pairDump.prefix(60).joined(separator: " "))"; pairDump = [] }
        arrivalGaps = []; stampGaps = []; negativeStamps = 0
        return line
    }

    private func logStats() {
        let line = "connection \(connectionName); packets: \(rtc?.videoPackets ?? 0) on the picture track, \(rtc?.audioPackets ?? 0) on the sound track, \(counts.otherPackets) skipped; pictures \(counts.pictures) (\(counts.shown) shown, \(counts.lost) lost, \(counts.undecryptable) could not be opened\(counts.undecryptable > 0 ? ", last code \(lastDaveCode)" : "")), gaps \(depacketizer.gaps); resend: asked for \(reorder.asked), \(resent) arrived, \(reorder.recovered) filled a gap, gave up on \(reorder.givenUp); pacing \(pacing.title); timing: pictures come \(String(format: "%.0f", longestGap * 1000)) ms apart at worst, jitter \(String(format: "%.0f", playout.jitter * 1000)) ms, delay added \(String(format: "%.0f", playout.delay * 1000)) ms, \(playout.late) shown late (worst \(String(format: "%.0f", playout.worstLate * 1000)) ms), \(playout.resyncs) restarts, slowest handling of a picture \(String(format: "%.0f", slowest * 1000)) ms; sound \(counts.soundHeard) played, \(counts.soundSilent) silence, \(counts.soundUndecryptable) could not be opened; waiting for a key frame \(waitingForKey)"
        let pacingLine = pacingSummary()
        slowest = 0; longestGap = 0
        Task { @MainActor in self.log(line); if let pacingLine { self.log(pacingLine) } }
    }
}
