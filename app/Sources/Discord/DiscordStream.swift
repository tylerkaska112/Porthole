// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Network
import UIKit
import VideoToolbox

// Go Live (Discord branch, experimental): this account streams a picture into the voice channel it is in. A stream is a second voice connection that Discord sets up
// for it (docs.discord.food, Voice Connections > Streams: "on the protocol side, they are identical"): own address and token, own sound and video numbers, own end-to-end
// encryption group. This first version sends a moving TEST PICTURE; the game's own picture comes after Discord is shown to accept it.

/// How big and how heavy a stream is. A phone's upload is the limit: at 4 Mbit/s the viewer in the 9043 test lost one packet in five, a key frame is dozens of packets sent at once,
/// and every lost key frame made the viewer ask for another (it froze). The default is the middle one.
enum DiscordStreamQuality: Int, CaseIterable {
    case lowData, smooth, sharp
    static let key = "f4.discord.streamQuality"
    static var saved: DiscordStreamQuality { DiscordStreamQuality(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 1) ?? .smooth }
    static func save(_ quality: DiscordStreamQuality) { UserDefaults.standard.set(quality.rawValue, forKey: key) }
    var next: DiscordStreamQuality { DiscordStreamQuality(rawValue: (rawValue + 1) % Self.allCases.count) ?? .smooth }
    var bitrate: Int { [1_500_000, 2_500_000, 4_000_000][rawValue] }
    /// The stream fits inside this box (the game's or the screen's shape is kept).
    var box: (width: Int, height: Int) { self == .lowData ? (960, 540) : (1280, 720) }
    var title: String { ["Low data", "Smooth", "Sharp"][rawValue] }
    var detail: String { ["up to 540p, 1.5 Mbit/s", "up to 720p, 2.5 Mbit/s", "up to 720p, 4 Mbit/s"][rawValue] }
}

/// Each time Go Live starts it uses the next of these, so one install can try several ways the picture could differ from Discord's own clients without a new
/// build for each. The number is in the log and drawn on the test picture; the one that shows a picture is the answer.
struct DiscordStreamVariant {
    let name: String
    var rewriteVUI = true            // the SPS gets a VUI saying "no reordering" (DiscordSPS)
    var constrainedFlags = false     // the SPS says "constrained baseline" (constraint_set0/1/2), as the offered profile-level-id 42e01f does
    var dropSEI = false              // no SEI NAL units (WebRTC encoders send none)
    var colour = false               // the SPS VUI carries a BT.709 limited-range colour description
    var width = 1280, height = 720, bitrate = 3_000_000

    /// Only the plain format is left: every variant (colour description, constrained flags, no SEI, other sizes) showed a picture once the stream had a sound track (9037), so none of
    /// them mattered. The cycling is kept for the next time a format question comes up: add entries here and each start uses the next one.
    static let all: [DiscordStreamVariant] = [
        DiscordStreamVariant(name: "plain"),
    ]
    static let indexKey = "f4.discordStreamVariant"
    /// The variant for this start; the next start uses the following one.
    static func next() -> (index: Int, variant: DiscordStreamVariant) {
        let d = UserDefaults.standard
        let i = d.integer(forKey: indexKey) % all.count
        d.set(i + 1, forKey: indexKey)
        return (i, all[i])
    }
}

/// H.264 from the phone's hardware encoder, as Annex B access units (start codes), key frames led by their parameter sets.
final class DiscordH264Encoder: @unchecked Sendable {
    /// An encoded picture: the Annex B bytes, whether it is a key frame.
    var onFrame: ((Data, Bool) -> Void)?
    private var session: VTCompressionSession?
    private let startCode = Data([0, 0, 1])      // 3-byte start codes, as Discord's own streaming clients write them

    private let variant: DiscordStreamVariant

    init?(width: Int, height: Int, fps: Int, bitrate: Int, variant: DiscordStreamVariant) {
        self.variant = variant
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { return nil }
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)      // what Discord's clients ask for (profile-level-id 42e01f)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)                       // no B-frames: Discord's packetizer cannot carry them
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 5 / 4 / 8, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 3 as CFNumber)                   // a key frame every three seconds at least
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    func encode(_ pixels: CVPixelBuffer, time: CMTime, forceKey: Bool) {
        guard let session else { return }
        let options: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            self?.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var out = Data()
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer {
                    var nal = Data(bytes: pointer, count: size)
                    // The hardware encoder's SPS has no VUI: a decoder then holds pictures back. Say "no reordering" in it (DiscordSPS).
                    if nal.first.map({ $0 & 0x1F == 7 }) == true {
                        if variant.rewriteVUI, let rewritten = DiscordSPS.rewriteVUI(nal, colour: variant.colour) { nal = rewritten }
                        if variant.constrainedFlags, nal.count > 3, nal[nal.startIndex + 1] == 66 { nal[nal.startIndex + 2] |= 0xE0 }
                    }
                    out.append(startCode); out.append(nal)
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var base: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base) == kCMBlockBufferNoErr, let base else { return }
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {      // AVCC: each NAL unit follows its 4-byte length
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard size > 0, offset + size <= length else { break }
            if variant.dropSEI, bytes[offset] & 0x1F == 6 { offset += size; continue }
            out.append(startCode)
            out.append(bytes + offset, count: size)
            offset += size
        }
        onFrame?(out, isKey)
    }
}

/// A moving picture to stream while the real game picture is not wired in: a colour that drifts, a box that travels, and a frame counter.
final class DiscordTestPattern: @unchecked Sendable {
    let width: Int, height: Int, fps: Int
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "porthole.discord.testpattern", qos: .userInitiated)
    private var frame = 0
    var label = ""

    init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }

    func start(_ onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.makeFrame() else { return }
            onFrame(buffer, self.frame)
            self.frame += 1
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }

    private func makeFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let hue = CGFloat(frame % 600) / 600
        context.setFillColor(UIColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let travel = CGFloat(width - 160)
        let x = travel * CGFloat(abs(((frame * 6) % Int(travel * 2)) - Int(travel))) / travel
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: x, y: CGFloat(height) * 0.55, width: 160, height: 160))
        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)      // UIKit text draws top-down
        let title = "Porthole Go Live test \(label)  \(frame)" as NSString
        title.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white])
        UIGraphicsPopContext()
        return buffer
    }
}

/// The stream's own voice connection.
@MainActor
final class DiscordStream {
    enum State: Equatable { case idle, starting, live, failed(String) }

    var onState: ((State) -> Void)?
    private(set) var state: State = .idle { didSet { if state != oldValue { onState?(state) } } }

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var stopped = true
    private var seq = -1
    private var identify: [String: Any] = [:]
    private var dave: DaveManager?
    private var audioSSRC: UInt32 = 0, videoSSRC: UInt32 = 0, rtxSSRC: UInt32 = 0
    private let fps = 30
    private var variant = DiscordStreamVariant.all[0]
    /// What the stream shows: a moving test picture, or what this app draws on the screen (the game).
    enum Source { case testPicture, screen, game }
    private var source = Source.testPicture
    private var outputSize = (width: 1280, height: 720)
    private var width: Int { outputSize.width }
    private var height: Int { outputSize.height }
    private var quality = DiscordStreamQuality.saved
    private var bitrate: Int { source == .testPicture ? variant.bitrate : quality.bitrate }
    private var capture: DiscordScreenCapture?
    private var gameCapture: DiscordGameCapture?
    private var gameAudio: DiscordGameAudio?
    /// Something went wrong that ends the stream (screen recording refused, for one): the session stops the stream and shows the reason.
    var onFatal: ((String) -> Void)?
    private var rtc: DiscordWebRTC?
    private var announced = false
    private let mediaQueue = DispatchQueue(label: "porthole.discord.stream", qos: .userInitiated)
    private let codec = DaveFrameCodec()
    private var checkedUnits = 0
    private let selfDecode = DiscordSelfDecode()
    private var selfDecoded = 0
    private var loggedUnits = 0
    private var lastKeyRequest = Date.distantPast
    private var encoder: DiscordH264Encoder?
    private var pattern: DiscordTestPattern?
    private var needKey = true
    private var counts = (encoded: 0, keys: 0, dropped: 0)
    private var firstPicture: Date?
    private var pictureLossRequests = 0, droppedBeforeOpen = 0, serverBitrate = 0
    private var connectionName = "none"
    private var statsTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var audioFrames: UInt32 = 0

    private func log(_ line: String) { LogStore.shared.log("[discord-stream] \(line)") }

    /// DIAGNOSTIC (9035): say this client does not do end-to-end encryption, to tell a picture the viewer cannot open (encryption) from one it cannot show. Discord may refuse
    /// the connection or turn the encryption off for everyone on the stream; the log says which.
    static let testWithoutEncryption = false      // 9035 tried true: Discord closed the connection with code 4017, so encryption is required

    func connect(endpoint: String, rtcServerID: String, userID: String, sessionID: String, token: String, source: Source = .testPicture) {
        stop(silently: true)
        self.source = source
        quality = DiscordStreamQuality.saved
        switch source {
        case .screen: outputSize = DiscordScreenCapture.outputSize(box: quality.box)
        case .game: outputSize = DiscordGameCapture.outputSize(box: quality.box) ?? quality.box
        case .testPicture: outputSize = (DiscordStreamVariant.all[0].width, DiscordStreamVariant.all[0].height)
        }
        let chosen = DiscordStreamVariant.next()
        variant = chosen.variant
        if source == .testPicture { outputSize = (variant.width, variant.height) }
        log("VARIANT \(chosen.index): \(chosen.variant.name)")
        counts = (0, 0, 0); pictureLossRequests = 0; droppedBeforeOpen = 0; serverBitrate = 0; needKey = true; firstPicture = nil; announced = false; connectionName = "none"
        stopped = false
        state = .starting
        seq = -1
        identify = ["server_id": rtcServerID, "user_id": userID, "session_id": sessionID, "token": token, "video": true,
                    "streams": [["type": "screen", "rid": "100", "quality": 100]], "max_dave_protocol_version": DiscordStream.testWithoutEncryption ? 0 : Int(daveMaxSupportedProtocolVersion())]
        // The stream has its own end-to-end encryption group, named by the stream's server id minus one.
        dave = DaveManager(selfUserID: userID, groupID: (UInt64(rtcServerID) ?? 1) &- 1)
        dave?.output = { [weak self] out in self?.daveOutput(out) }
        dave?.onRatchet = { [weak self] user, ratchet, version in
            guard let self else { return }
            self.log("encryption keys for \(user == userID ? "this account" : "another member"), protocol version \(version)\(ratchet == nil ? ", no key ratchet" : "")")
            self.mediaQueue.async { self.codec.setRatchet(user: user, isSelf: user == userID, ratchet: ratchet, version: version); self.needKey = true }
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
    }

    func stop(silently: Bool = false) {
        stopped = true
        heartbeat?.cancel()
        statsTimer?.cancel(); statsTimer = nil
        audioTimer?.cancel(); audioTimer = nil
        pattern?.stop(); pattern = nil
        capture?.stop(); capture = nil
        gameCapture?.stop(); gameCapture = nil
        gameAudio?.stop(); gameAudio = nil
        // The encoder and the connection are used on the media queue (frames, key requests, timers) while this runs on the main actor: let go of them there, so a
        // frame in flight never reads a reference that is being cleared. stop() is only called from DiscordSession (main actor), never from the media queue.
        mediaQueue.sync { [self] in
            encoder = nil
            rtc?.close(); rtc = nil
        }
        dave = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        if !silently { state = .idle }
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
                if state != .idle { state = .failed("The stream connection ended (code \(code)).") }
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
        case 2:   // ready: sound number, video number (and its retransmission number), where to send
            audioSSRC = UInt32(truncatingIfNeeded: d["ssrc"] as? Int ?? 0)
            let streams = d["streams"] as? [[String: Any]] ?? []
            if let first = streams.first {
                videoSSRC = UInt32(truncatingIfNeeded: first["ssrc"] as? Int ?? 0)
                rtxSSRC = UInt32(truncatingIfNeeded: first["rtx_ssrc"] as? Int ?? 0)
            } else {
                videoSSRC = audioSSRC &+ 1; rtxSSRC = audioSSRC &+ 2
            }
            log("ready: \(streams.count) video stream(s) offered (sound \(audioSSRC), video \(videoSSRC), resend \(rtxSSRC)); modes \((d["modes"] as? [String] ?? []).joined(separator: ", "))")
            startConnection()
        case 4:
            let version = d["dave_protocol_version"] as? Int ?? 0
            log("session accepted: video codec \(d["video_codec"] as? String ?? "?"), end-to-end encryption version \(version)")
            guard let sdp = d["sdp"] as? String else { log("the server's answer carries no connection description"); state = .failed("Discord's stream server did not answer the connection request."); return }
            let answer = rtc?.setAnswer(serverSDP: sdp)
            log("answer given to the connection: \(answer == nil ? "refused" : "accepted"); the server's own text was \(sdp.count) characters")
            dave?.onSessionDescription(version: UInt16(truncatingIfNeeded: version))
            announceVideo()
        case 21: dave?.onPrepareTransition(id: d["transition_id"] as? Int ?? 0, version: UInt16(truncatingIfNeeded: d["protocol_version"] as? Int ?? 0))
        case 22: dave?.onExecuteTransition(id: d["transition_id"] as? Int ?? 0)
        case 24:
            let epoch = (d["epoch"] as? Int) ?? Int(d["epoch"] as? String ?? "") ?? 0
            dave?.onPrepareEpoch(epoch: epoch, version: UInt16(truncatingIfNeeded: d["protocol_version"] as? Int ?? 0))
        case 11: for id in (d["user_ids"] as? [String] ?? []) { dave?.createUser(id) }
        case 13: if let id = d["user_id"] as? String { dave?.destroyUser(id) }
        case 15:
            log("a viewer asks for video: \(d.filter { $0.key != "pixelCounts" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")); picture sizes wanted \(d["pixelCounts"] ?? "none")")
            mediaQueue.async { self.requestKey() }      // someone new wants the picture: start it with a key frame
        case 5, 6, 12, 18, 20: break
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

    /// Creates the WebRTC connection; its offer goes to Discord as the select-protocol message.
    private func startConnection() {
        rtc?.close()
        let rtc = DiscordWebRTC(audioSSRC: audioSSRC, videoSSRC: videoSSRC, rtxSSRC: rtxSSRC)
        self.rtc = rtc
        rtc.log = { [weak self] line in Task { @MainActor in self?.log(line) } }
        rtc.onOffer = { [weak self] sdp in Task { @MainActor in self?.sendOffer(sdp) } }
        rtc.onState = { [weak self] name in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.connectionName = name
                self.log("connection: \(name)")
                if name == "failed" || name == "ice failed" { self.state = .failed("The connection to Discord's stream server failed (\(name)).") }
            }
        }
        rtc.onTrackOpen = { [weak self] in Task { @MainActor in self?.log("the video track is open; pictures go out now") } }
        rtc.onKeyRequest = { [weak self] in
            self?.mediaQueue.async { guard let self else { return }; self.pictureLossRequests += 1; self.requestKey() }
        }
        rtc.onBandwidth = { [weak self] kbit in self?.mediaQueue.async { self?.serverBitrate = kbit } }
        if !rtc.start() { state = .failed("The phone's WebRTC connection could not start.") }
    }

    private func sendOffer(_ sdp: String) {
        let shown = sdp.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).filter { !$0.hasPrefix("a=ice-pwd") && !$0.hasPrefix("a=ice-ufrag") && !$0.hasPrefix("a=fingerprint") }.joined(separator: " | ")
        log("offer (\(sdp.count) characters): \(shown.prefix(1500))")
        send(1, ["protocol": "webrtc", "codecs": DiscordCodecs.selectList, "data": sdp, "sdp": sdp, "rtc_connection_id": UUID().uuidString.lowercased()])
    }

    /// The server accepted the connection description: announce the video and start the pictures (they go out once the video track is open and the keys exist).
    private func announceVideo() {
        guard !announced else { return }
        announced = true
        mediaQueue.async { [codec, videoSSRC, audioSSRC] in codec.assign(ssrc: videoSSRC, codec: DAVE_CODEC_H264); codec.assign(ssrc: audioSSRC) }
        send(12, ["audio_ssrc": Int(audioSSRC), "video_ssrc": Int(videoSSRC), "rtx_ssrc": Int(rtxSSRC),
                  "streams": [["type": "screen", "rid": "100", "ssrc": Int(videoSSRC), "active": true, "quality": 100, "rtx_ssrc": Int(rtxSSRC),
                               "max_bitrate": bitrate, "max_framerate": fps, "max_resolution": ["type": "fixed", "width": width, "height": height]]]])
        send(5, ["speaking": 2, "delay": 0, "ssrc": Int(audioSSRC)])
        guard let encoder = DiscordH264Encoder(width: width, height: height, fps: fps, bitrate: bitrate, variant: variant) else { state = .failed("The phone's video encoder could not start."); return }
        self.encoder = encoder
        encoder.onFrame = { [weak self] unit, isKey in self?.mediaQueue.async { self?.encoded(unit, isKey: isKey) } }
        let submit: (CVPixelBuffer, Int) -> Void = { [weak self] buffer, frame in
            guard let self else { return }
            self.mediaQueue.async {
                let open = self.rtc?.isOpen ?? false
                let force = self.needKey && self.codec.canEncrypt && open
                if (self.needKey && !self.codec.canEncrypt) || !open { self.counts.dropped += 1; if !open { self.droppedBeforeOpen += 1 }; return }      // no keys or no connection yet: nothing to send
                if force { self.needKey = false }
                self.encoder?.encode(buffer, time: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(self.fps)), forceKey: force)
            }
        }
        switch source {
        case .testPicture:
            let pattern = DiscordTestPattern(width: width, height: height, fps: fps)
            pattern.label = "v\(UserDefaults.standard.integer(forKey: DiscordStreamVariant.indexKey) - 1)"
            self.pattern = pattern
            pattern.start(submit)
        case .game:
            let capture = DiscordGameCapture(width: width, height: height, fps: fps)
            self.gameCapture = capture
            log("streaming the game's own picture at \(width)x\(height)")
            capture.start(onFrame: submit, onFailure: { [weak self] why in
                Task { @MainActor in
                    self?.log("game capture: \(why)")
                    self?.onFatal?(why)
                }
            })
        case .screen:
            let capture = DiscordScreenCapture(width: width, height: height, fps: fps)
            self.capture = capture
            log("streaming the screen at \(width)x\(height)")
            capture.start(onFrame: submit, onFailure: { [weak self] why in
                Task { @MainActor in
                    self?.log("screen capture: \(why)")
                    self?.onFatal?(why)
                }
            })
        }
        let stats = DispatchSource.makeTimerSource(queue: mediaQueue)
        stats.schedule(deadline: .now() + 5, repeating: 5)
        stats.setEventHandler { [weak self] in self?.logStats() }
        stats.resume()
        statsTimer = stats
        // The stream's sound track, 20 ms at a time: the game's own sound when a game is streamed, else (or while the game is silent) an Opus silence packet, so the viewer sees
        // sound and picture together.
        audioFrames = 0
        if source != .testPicture, let sound = DiscordGameAudio() { sound.start(); gameAudio = sound; log("the game's sound goes on the stream") }
        let sound = DispatchSource.makeTimerSource(queue: mediaQueue)
        sound.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        sound.setEventHandler { [weak self] in
            guard let self, let rtc = self.rtc, rtc.isOpen, self.codec.canEncrypt else { return }
            let opus = self.gameAudio?.nextPacket() ?? Data([0xF8, 0xFF, 0xFE])      // the game's sound, or Opus silence
            guard let packet = self.codec.encrypt(opus, ssrc: self.audioSSRC) else { return }
            rtc.send(audio: packet, timestamp: self.audioFrames &* 960)
            self.audioFrames &+= 1
        }
        sound.resume()
        audioTimer = sound
        state = .live
    }

    /// Runs on the media queue.
    private func encoded(_ unit: Data, isKey: Bool) {
        counts.encoded += 1
        if isKey { counts.keys += 1 }
        // The first pictures are decoded again with the phone's own decoder (before encryption) and their brightness logged: black here would be the encoder's doing.
        if selfDecoded < 8 {
            if selfDecoded == 0 { selfDecode.report = { [weak self] line in Task { @MainActor in self?.log(line) } } }
            selfDecoded += 1
            selfDecode.feed(unit, isKey: isKey, number: selfDecoded)
        }
        guard codec.canEncrypt, let encrypted = codec.encrypt(unit, ssrc: videoSSRC, media: DAVE_MEDIA_TYPE_VIDEO) else { counts.dropped += 1; return }
        if isKey, loggedUnits < 3 {      // what the encryption did to a key frame, for the log
            loggedUnits += 1
            func shape(_ d: Data) -> String { DiscordAnnexB.nalUnits(d).map { "\($0[$0.startIndex] & 0x1F):\($0.count)" }.joined(separator: " ") }
            let before = shape(unit), after = shape(encrypted)
            Task { @MainActor in self.log("key frame NAL units (type:size) before encryption [\(before)] after [\(after)]") }
        }
        // The first pictures are opened again with this account's own keys, and the start of the first key frame is logged, so a viewer that cannot decode them can be told apart
        // from pictures that are not well formed.
        if checkedUnits < 6 {
            checkedUnits += 1
            let (opened, code) = codec.openOwn(encrypted, media: DAVE_MEDIA_TYPE_VIDEO)
            let verdict: String
            if let opened { verdict = opened == unit ? "opens to the same \(unit.count) bytes" : "opens, but to \(opened.count) bytes that differ from the \(unit.count) sent" }
            else { verdict = "does NOT open (result \(code))" }
            let head = encrypted.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
            let number = checkedUnits, key = isKey, count = encrypted.count
            Task { @MainActor in self.log("self-check \(number): \(key ? "key" : "delta") picture of \(count) bytes \(verdict); begins \(head)") }
        }
        let start = firstPicture ?? Date()
        firstPicture = start
        rtc?.send(accessUnit: encrypted, timestamp: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(start) * 90000)))
    }

    /// A viewer wants a key frame. A key frame is dozens of packets in one burst: asking for one after another on a connection that is already losing packets only loses more of
    /// them, so at most one is made in three seconds (the viewer asks again if it still needs one).
    private func requestKey() {
        guard Date().timeIntervalSince(lastKeyRequest) > 3 else { return }
        lastKeyRequest = Date()
        needKey = true
    }

    private func logStats() {
        let line = "connection \(connectionName); handed over \(rtc?.sent ?? 0) pictures (\(rtc?.sendErrors ?? 0) refused), encoded \(counts.encoded) (\(counts.keys) key), dropped \(counts.dropped) (\(droppedBeforeOpen) before the video track opened); keys for encryption: \(codec.canEncrypt); picture-loss requests from Discord \(pictureLossRequests); bandwidth estimate \(serverBitrate) kbit/s"
        Task { @MainActor in self.log(line) }
    }
}
