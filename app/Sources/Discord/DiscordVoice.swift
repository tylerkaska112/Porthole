// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import AVFoundation
import Foundation
import Network


/// Voice so far: join a voice channel, speak Discord's end-to-end encryption (DAVE) handshake through libdave, and say whether Discord accepted it. (An earlier test without DAVE was refused with close code 4017.) It connects to the voice gateway, introduces itself,
/// finds its public address (IP discovery over UDP), picks an encryption mode and reads the session key. No sound is sent or played yet. Its main job is to show,
/// in the log and on screen, what Discord does with a client that does not speak DAVE (the documentation says such clients are refused with close code 4017).
@MainActor
final class DiscordVoice {
    enum State: Equatable {
        case idle
        case joining(String)
        /// Everything up to the session key worked: the connection is accepted. (Sound comes in a later step.)
        case ready(String)
        case refused(String)
    }

    var onState: ((State) -> Void)?
    var onSpeakingUsers: ((Set<String>) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var state: State = .idle { didSet { if state != oldValue { onState?(state) } } }

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var udp: NWConnection?
    private var stopped = true
    private var ssrc: UInt32 = 0
    private var seq = -1
    private var label = ""
    private var mode = "aead_xchacha20_poly1305_rtpsize"
    private var identify: [String: Any] = [:]
    private var dave: DaveManager?
    private var audio: DiscordAudio?
    private var ssrcUsers: [UInt32: String] = [:]
    private var muted = false
    private var deafened = false
    private var pushToTalk = false
    private var talkHeld = false
    private var reduceEcho = false
    private var personGains: [String: Float] = [:]
    private var sessionAccepted = false

    func connect(endpoint: String, serverID: String, userID: String, sessionID: String, token: String, channelID: String, label: String) {
        stop(silently: true)
        stopped = false
        self.label = label
        state = .joining(label)
        seq = -1
        identify = ["server_id": serverID, "user_id": userID, "session_id": sessionID, "token": token, "max_dave_protocol_version": Int(daveMaxSupportedProtocolVersion())]
        dave = DaveManager(selfUserID: userID, groupID: UInt64(channelID) ?? 0)
        dave?.output = { [weak self] out in self?.daveOutput(out) }
        dave?.onRatchet = { [weak self] user, ratchet, version in self?.audio?.setRatchet(user: user, ratchet: ratchet, version: version) }
        dave?.onStatus = { [weak self] line in
            LogStore.shared.log("[discord-voice] \(line)")
            guard let self, self.sessionAccepted else { return }
            switch self.state { case .joining, .ready: self.state = .ready(self.label + " (" + line + ")"); default: break }
        }
        sessionAccepted = false
        let host = endpoint.replacingOccurrences(of: ":80", with: "")
        guard let url = URL(string: "wss://\(host)/?v=8") else { state = .refused("Discord sent a voice address this version cannot read."); return }
        var request = URLRequest(url: url)
        request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        LogStore.shared.log("[discord-voice] connecting to the voice server for \(label)")
        Task { await receiveLoop(task) }
    }

    func stop(silently: Bool = false) {
        stopped = true
        heartbeat?.cancel()
        audio?.stop(); audio = nil
        ssrcUsers = [:]
        udp?.cancel(); udp = nil
        dave = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        if !silently { state = .idle }
    }

    private func send(_ op: Int, _ d: Any) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: ["op": op, "d": d]), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

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
                let meaning: String
                switch code {
                case 4017: meaning = "Discord refused: this channel needs end-to-end encryption (DAVE) and the handshake did not go through."
                case 4003: meaning = "Discord says it was not authenticated."
                case 4004: meaning = "Discord says the sign-in is no longer valid."
                case 4006: meaning = "Discord says the voice session is no longer valid."
                case 4014: meaning = "Discord says it was disconnected from the channel."
                case 4015: meaning = "Discord's voice server crashed."
                case 4016: meaning = "Discord does not accept this encryption mode."
                default: meaning = "The voice connection ended (code \(code))."
                }
                LogStore.shared.log("[discord-voice] closed with code \(code): \(meaning)")
                if case .ready = state { state = .idle } else { state = .refused(meaning) }
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let op = object["op"] as? Int else { return }
        if let s = object["seq"] as? Int { seq = s }
        let d = object["d"] as? [String: Any] ?? [:]
        if op != 6 { LogStore.shared.log("[discord-voice] message op \(op) fields: \(d.keys.sorted().filter { $0 != "secret_key" && $0 != "token" }.joined(separator: ","))") }
        switch op {
        case 8:   // hello
            let interval = (d["heartbeat_interval"] as? Double ?? 41250) / 1000
            startHeartbeat(interval: interval)
            send(0, identify)
        case 2:   // ready
            ssrc = UInt32(truncatingIfNeeded: d["ssrc"] as? Int ?? 0)
            guard let ip = d["ip"] as? String, let port = d["port"] as? Int else { state = .refused("Discord's voice server did not say where to send sound."); return }
            let modes = d["modes"] as? [String] ?? []
            LogStore.shared.log("[discord-voice] ready; the server offers \(modes.count) encryption mode(s): \(modes.joined(separator: ", "))")
            guard modes.contains("aead_aes256_gcm_rtpsize") else { state = .refused("Discord's voice server offers no sound encryption this version can do."); return }
            mode = "aead_aes256_gcm_rtpsize"    // hardware-accelerated on every iPhone, and CryptoKit has it
            discoverAddress(ip: ip, port: port)
        case 4:   // session description
            let version = d["dave_protocol_version"] as? Int ?? 0
            let keyBytes = (d["secret_key"] as? [Int])?.count ?? 0
            LogStore.shared.log("[discord-voice] session accepted: mode \(d["mode"] as? String ?? "?"), key \(keyBytes) bytes, DAVE version \(version)")
            sessionAccepted = true
            if let key = (d["secret_key"] as? [Int])?.map({ UInt8(truncatingIfNeeded: $0) }), key.count == 32 { startAudio(secret: Data(key)) }
            dave?.onSessionDescription(version: UInt16(truncatingIfNeeded: version))
            if version == 0 { state = .ready(label) }
        case 21:
            dave?.onPrepareTransition(id: d["transition_id"] as? Int ?? 0, version: UInt16(truncatingIfNeeded: d["protocol_version"] as? Int ?? 0))
        case 22:
            dave?.onExecuteTransition(id: d["transition_id"] as? Int ?? 0)
        case 24:
            let epoch = (d["epoch"] as? Int) ?? Int(d["epoch"] as? String ?? "") ?? 0
            dave?.onPrepareEpoch(epoch: epoch, version: UInt16(truncatingIfNeeded: d["protocol_version"] as? Int ?? 0))
        case 11:
            for id in (d["user_ids"] as? [String] ?? []) { dave?.createUser(id) }
        case 13:
            if let id = d["user_id"] as? String { dave?.destroyUser(id) }
        case 6: break
        case 5:   // someone started or stopped talking: this is how a sound's source number gets a name
            if let user = d["user_id"] as? String, let source = d["ssrc"] as? Int {
                // Kept here as well: the first of these arrive before the sound connection exists.
                ssrcUsers[UInt32(truncatingIfNeeded: source)] = user
                audio?.mapSSRC(UInt32(truncatingIfNeeded: source), user: user)
            }
        default:
            LogStore.shared.log("[discord-voice] message with opcode \(op)")
        }
    }

    /// Binary messages from the voice server: 2 bytes of sequence number, 1 byte of opcode, then the payload.
    private func handleBinary(_ data: Data) {
        guard data.count >= 3 else { return }
        seq = Int(data[0]) << 8 | Int(data[1])
        let op = Int(data[2])
        let payload = data.dropFirst(3)
        LogStore.shared.log("[discord-voice] binary op \(op), \(payload.count) bytes")
        switch op {
        case 25: dave?.onExternalSender(Data(payload))
        case 27: dave?.onProposals(Data(payload))
        case 29, 30:
            guard payload.count > 2 else { return }
            let id = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
            let rest = Data(payload.dropFirst(2))
            if op == 29 { dave?.onCommit(transitionID: id, commit: rest) } else { dave?.onWelcome(transitionID: id, welcome: rest) }
        default: LogStore.shared.log("[discord-voice] binary message with opcode \(op)")
        }
    }

    private func startAudio(secret: Data) {
        guard let udp, let userID = identify["user_id"] as? String else { return }
        let audio = DiscordAudio(connection: udp, ssrc: ssrc, secretKey: secret, selfID: userID)
        audio.onLog = { line in Task { @MainActor in LogStore.shared.log("[discord-audio] \(line)") } }
        audio.onSpeaking = { [weak self] talking in Task { @MainActor in self?.sendSpeaking(talking) } }
        audio.onLevel = { [weak self] level in Task { @MainActor in self?.onLevel?(level) } }
        audio.onSpeakingUsers = { [weak self] ids in Task { @MainActor in self?.onSpeakingUsers?(ids) } }
        audio.setMuted(muted)
        audio.setPushToTalk(enabled: pushToTalk, held: talkHeld)
        audio.setReduceEcho(reduceEcho)
        audio.setDeafened(deafened)
        audio.setPersonGains(personGains)
        for (source, user) in ssrcUsers { audio.mapSSRC(source, user: user) }
        self.audio = audio
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor [weak audio] in audio?.start(microphone: granted) }
        }
    }

    private func sendSpeaking(_ talking: Bool) { send(5, ["speaking": talking ? 1 : 0, "delay": 0, "ssrc": Int(ssrc)]) }

    func setMuted(_ on: Bool) { muted = on; audio?.setMuted(on) }
    func setReduceEcho(_ on: Bool) { reduceEcho = on; audio?.setReduceEcho(on) }
    func setPushToTalk(enabled: Bool, held: Bool) { pushToTalk = enabled; talkHeld = held; audio?.setPushToTalk(enabled: enabled, held: held) }
    func setPersonGains(_ gains: [String: Float]) { personGains = gains; audio?.setPersonGains(gains) }
    func setDeafened(_ on: Bool) { deafened = on; audio?.setDeafened(on) }
    func volumesChanged() { audio?.applyVolumes() }
    func sensitivityChanged() { audio?.applySensitivity() }
    var hearing: Int { audio?.speakers ?? 0 }

    private func daveOutput(_ out: DaveManager.Output) {
        switch out {
        case .keyPackage(let bytes): LogStore.shared.log("[discord-voice] sending key package (\(bytes.count) bytes)"); sendBinary(26, bytes)
        case .commitWelcome(let bytes): LogStore.shared.log("[discord-voice] sending commit/welcome (\(bytes.count) bytes)"); sendBinary(28, bytes)
        case .readyForTransition(let id): LogStore.shared.log("[discord-voice] ready for transition \(id)"); send(23, ["transition_id": id])
        case .invalidCommitWelcome(let id): LogStore.shared.log("[discord-voice] telling the server the commit/welcome was not usable (transition \(id))"); send(31, ["transition_id": id])
        }
    }

    private func sendBinary(_ op: UInt8, _ payload: Data) {
        task?.send(.data(Data([op]) + payload)) { _ in }
    }

    private func startHeartbeat(interval: Double) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await MainActor.run {
                    guard let self, !self.stopped else { return }
                    var d: [String: Any] = ["t": Int(Date().timeIntervalSince1970 * 1000)]
                    d["seq_ack"] = self.seq
                    self.send(3, d)
                }
            }
        }
    }

    /// IP discovery: send 74 bytes to the voice server's UDP port; it answers with the address and port it sees.
    private func discoverAddress(ip: String, port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .udp)
        udp = connection
        connection.stateUpdateHandler = { [weak self] newState in
            if case .failed(let error) = newState {
                Task { @MainActor in self?.state = .refused("The sound connection failed: \(error.localizedDescription)") }
            }
        }
        connection.start(queue: .main)
        var packet = Data([0x00, 0x01, 0x00, 0x46])
        packet.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian) { Array($0) })
        packet.append(Data(count: 66))
        connection.send(content: packet, completion: .contentProcessed { _ in })
        connection.receiveMessage { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                guard let data, data.count >= 74, data[0] == 0x00, data[1] == 0x02 else { self.state = .refused("Discord's voice server did not answer the address check."); return }
                let addressBytes = data[8..<72].prefix { $0 != 0 }
                let address = String(decoding: addressBytes, as: UTF8.self)
                let publicPort = Int(data[72]) << 8 | Int(data[73])
                LogStore.shared.log("[discord-voice] address check answered (port \(publicPort))")
                self.send(1, ["protocol": "udp", "data": ["address": address, "port": publicPort, "mode": self.mode]])
            }
        }
    }
}
