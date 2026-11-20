// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// Go Live over WebRTC (Discord branch, experimental). Discord's own apps (and the working open-source Go Live client) reach the stream server as a WebRTC peer:
// the voice gateway's "select protocol" carries an SDP offer (protocol "webrtc"), the server answers with an incomplete SDP, and the pictures travel as SRTP.
// libdatachannel (MPL-2.0, built by tools/build_datachannel.sh) does the ICE / DTLS / SRTP / RTCP part; Porthole keeps its own H.264 encoder and Discord's
// end-to-end encryption (DAVE) and hands it finished, encrypted access units. The earlier raw-UDP way never got a single report on the video from the server.

/// The codec table Discord's clients and the open-source client announce (payload type, retransmission payload type).
enum DiscordCodecs {
    static let opus = 120
    static let h264 = 101, h264RTX = 102
    static let video: [(name: String, pt: Int, rtx: Int)] = [("H264", 101, 102), ("H265", 103, 104), ("VP8", 105, 106), ("VP9", 107, 108), ("AV1", 109, 110)]

    /// The list a viewer sends: it only opens H.264 pictures, and sends none.
    static var viewerList: [[String: Any]] {
        var list: [[String: Any]] = [["name": "opus", "type": "audio", "priority": 1000, "payload_type": opus]]
        for c in video { list.append(["name": c.name, "type": "video", "priority": 1000, "payload_type": c.pt, "rtx_payload_type": c.rtx, "encode": false, "decode": c.name == "H264"]) }
        return list
    }

    /// The list sent in the voice gateway's select-protocol message.
    static var selectList: [[String: Any]] {
        var list: [[String: Any]] = [["name": "opus", "type": "audio", "priority": 1000, "payload_type": opus]]
        for c in video { list.append(["name": c.name, "type": "video", "priority": 1000, "payload_type": c.pt, "rtx_payload_type": c.rtx, "encode": true, "decode": true]) }
        return list
    }
}

final class DiscordWebRTC: @unchecked Sendable {
    /// Called on libdatachannel's threads.
    var onOffer: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onTrackOpen: (() -> Void)?
    var onKeyRequest: (() -> Void)?
    var onBandwidth: ((Int) -> Void)?
    var log: ((String) -> Void)?

    private let audioSSRC: UInt32, videoSSRC: UInt32, rtxSSRC: UInt32
    private var pc: Int32 = -1, audioTrack: Int32 = -1, videoTrack: Int32 = -1
    private var retained: Unmanaged<DiscordWebRTC>?
    private(set) var sendErrors = 0, sent = 0

    private static var loggerStarted = false

    init(audioSSRC: UInt32, videoSSRC: UInt32, rtxSSRC: UInt32) {
        self.audioSSRC = audioSSRC; self.videoSSRC = videoSSRC; self.rtxSSRC = rtxSSRC
    }

    var isOpen: Bool { videoTrack >= 0 && rtcIsOpen(videoTrack) }

    /// Creates the connection and its two media tracks and asks for the offer (delivered to `onOffer`).
    func start() -> Bool {
        if !Self.loggerStarted {
            Self.loggerStarted = true
            rtcInitLogger(RTC_LOG_INFO) { _, message in
                guard let message else { return }
                let text = String(cString: message)
                Task { @MainActor in LogStore.shared.log("[discord-rtc] \(text)") }
            }
        }
        var config = rtcConfiguration()
        config.disableAutoNegotiation = true
        config.forceMediaTransport = true
        pc = rtcCreatePeerConnection(&config)
        guard pc >= 0 else { log?("could not create the connection (\(pc))"); return false }
        let me = Unmanaged.passRetained(self)
        retained = me
        rtcSetUserPointer(pc, me.toOpaque())
        rtcSetLocalDescriptionCallback(pc) { _, sdp, _, ptr in
            guard let sdp, let ptr else { return }
            Unmanaged<DiscordWebRTC>.fromOpaque(ptr).takeUnretainedValue().onOffer?(String(cString: sdp))
        }
        rtcSetStateChangeCallback(pc) { _, state, ptr in
            guard let ptr else { return }
            let names = ["new", "connecting", "connected", "disconnected", "failed", "closed"]
            let name = Int(state.rawValue) < names.count ? names[Int(state.rawValue)] : "state \(state.rawValue)"
            Unmanaged<DiscordWebRTC>.fromOpaque(ptr).takeUnretainedValue().onState?(name)
        }
        rtcSetIceStateChangeCallback(pc) { _, state, ptr in
            guard let ptr else { return }
            let names = ["new", "checking", "connected", "completed", "failed", "disconnected", "closed"]
            let name = Int(state.rawValue) < names.count ? names[Int(state.rawValue)] : "state \(state.rawValue)"
            Unmanaged<DiscordWebRTC>.fromOpaque(ptr).takeUnretainedValue().onState?("ice \(name)")
        }
        audioTrack = rtcAddTrack(pc, audioSection())
        videoTrack = rtcAddTrack(pc, videoSection())
        guard audioTrack >= 0, videoTrack >= 0 else { log?("could not add the tracks (\(audioTrack), \(videoTrack))"); return false }
        rtcSetUserPointer(videoTrack, me.toOpaque())
        rtcSetOpenCallback(videoTrack) { _, ptr in
            guard let ptr else { return }
            Unmanaged<DiscordWebRTC>.fromOpaque(ptr).takeUnretainedValue().onTrackOpen?()
        }
        // H.264 packetizer: Annex B access units in, RTP out, with the playout-delay extension (id 5) Discord's receivers expect.
        var init264 = rtcPacketizerInit()
        let cname = strdup("porthole")
        defer { free(cname) }
        init264.ssrc = videoSSRC
        init264.cname = UnsafePointer(cname)
        init264.payloadType = UInt8(DiscordCodecs.h264)
        init264.clockRate = 90000
        init264.sequenceNumber = UInt16.random(in: 0...UInt16.max)
        init264.timestamp = 0
        init264.maxFragmentSize = 1200
        init264.nalSeparator = RTC_NAL_SEPARATOR_START_SEQUENCE
        init264.playoutDelayId = 5
        init264.playoutDelayMin = 0
        init264.playoutDelayMax = 10
        let packetized = rtcSetH264Packetizer(videoTrack, &init264)
        // The stream's sound track: Opus packets (silence for now) so that a viewer's app sees a live sound stream beside the picture, as with Discord's own clients.
        var initOpus = rtcPacketizerInit()
        let audioCname = strdup("porthole")
        defer { free(audioCname) }
        initOpus.ssrc = audioSSRC
        initOpus.cname = UnsafePointer(audioCname)
        initOpus.payloadType = UInt8(DiscordCodecs.opus)
        initOpus.clockRate = 48000
        initOpus.sequenceNumber = UInt16.random(in: 0...UInt16.max)
        initOpus.timestamp = 0
        let opusPacketized = rtcSetOpusPacketizer(audioTrack, &initOpus)
        let audioReporter = rtcChainRtcpSrReporter(audioTrack)
        log?("sound track: packetizer \(opusPacketized), sender reports \(audioReporter)")
        let reporter = rtcChainRtcpSrReporter(videoTrack)
        let nack = rtcChainRtcpNackResponder(videoTrack, 512)
        let pli = rtcChainPliHandler(videoTrack) { _, ptr in
            guard let ptr else { return }
            Unmanaged<DiscordWebRTC>.fromOpaque(ptr).takeUnretainedValue().onKeyRequest?()
        }
        let remb = rtcChainRembHandler(videoTrack) { _, bitrate, ptr in
            guard let ptr else { return }
            Unmanaged<DiscordWebRTC>.fromOpaque(ptr).takeUnretainedValue().onBandwidth?(Int(bitrate) / 1000)
        }
        log?("tracks added (audio \(audioTrack), video \(videoTrack)); packetizer \(packetized), sender reports \(reporter), resend answers \(nack), picture-loss \(pli), bandwidth \(remb)")
        let result = rtcSetLocalDescription(pc, nil)
        if result < 0 { log?("could not create the offer (\(result))"); return false }
        return true
    }

    /// Discord's answer is incomplete, so (like the working client) a complete one is written from the few lines that matter.
    func setAnswer(serverSDP: String) -> String? {
        var ip = "", port = "", ufrag = "", pwd = "", fingerprint = "", candidate = ""
        for raw in serverSDP.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("c=") { ip = line }
            else if line.hasPrefix("a=rtcp:") { port = String(line.dropFirst(7).split(separator: " ").first ?? "") }
            else if line.hasPrefix("a=ice-ufrag") { ufrag = line }
            else if line.hasPrefix("a=ice-pwd") { pwd = line }
            else if line.hasPrefix("a=fingerprint") { fingerprint = line }
            else if line.hasPrefix("a=candidate") { candidate = line }
        }
        guard !port.isEmpty, !ufrag.isEmpty, !fingerprint.isEmpty, !candidate.isEmpty else {
            log?("the server's answer lacks something (port \(!port.isEmpty), user \(!ufrag.isEmpty), fingerprint \(!fingerprint.isEmpty), candidate \(!candidate.isEmpty))")
            return nil
        }
        let audioPT = DiscordCodecs.opus
        let audio = """
        m=audio \(port) UDP/TLS/RTP/SAVPF \(audioPT)
        \(ip)
        a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
        a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
        a=setup:passive
        a=mid:0
        a=maxptime:60
        a=inactive
        \(ufrag)
        \(pwd)
        \(fingerprint)
        \(candidate)
        a=rtcp-mux
        a=rtpmap:\(audioPT) opus/48000/2
        a=fmtp:\(audioPT) minptime=10;useinbandfec=1;usedtx=1
        a=rtcp-fb:\(audioPT) transport-cc
        a=rtcp-fb:\(audioPT) nack
        a=ice-lite
        """
        let types = DiscordCodecs.video.flatMap { [String($0.pt), String($0.rtx)] }.joined(separator: " ")
        let video = """
        m=video \(port) UDP/TLS/RTP/SAVPF \(types)
        \(ip)
        a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
        a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
        a=extmap:14 urn:ietf:params:rtp-hdrext:toffset
        a=extmap:13 urn:3gpp:video-orientation
        a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay
        a=setup:passive
        a=mid:1
        a=inactive
        \(ufrag)
        \(pwd)
        \(fingerprint)
        \(candidate)
        a=rtcp-mux
        a=ice-lite
        """
        let maps = DiscordCodecs.video.flatMap { c in
            ["a=rtpmap:\(c.pt) \(c.name)/90000", "a=rtpmap:\(c.rtx) rtx/90000", "a=fmtp:\(c.rtx) apt=\(c.pt)",
             "a=rtcp-fb:\(c.pt) ccm fir", "a=rtcp-fb:\(c.pt) nack", "a=rtcp-fb:\(c.pt) nack pli", "a=rtcp-fb:\(c.pt) goog-remb", "a=rtcp-fb:\(c.pt) transport-cc"]
        }.joined(separator: "\n")
        let answer = [audio, video, maps].joined(separator: "\n")
        let result = rtcSetRemoteDescription(pc, answer, "answer")
        if result < 0 { log?("the connection refused the server's answer (\(result))") }
        return result < 0 ? nil : answer
    }

    /// One encrypted access unit (Annex B). `timestamp` is the 90 kHz picture clock.
    func send(accessUnit: Data, timestamp: UInt32) {
        guard videoTrack >= 0, rtcIsOpen(videoTrack) else { return }
        rtcSetTrackRtpTimestamp(videoTrack, timestamp)
        let result = accessUnit.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
            return rtcSendMessage(videoTrack, base, Int32(accessUnit.count))
        }
        if result < 0 { sendErrors += 1 } else { sent += 1 }
    }

    /// One Opus packet (already end-to-end encrypted) on the stream's sound track. `timestamp` counts 48 kHz samples.
    func send(audio: Data, timestamp: UInt32) {
        guard audioTrack >= 0, rtcIsOpen(audioTrack) else { return }
        rtcSetTrackRtpTimestamp(audioTrack, timestamp)
        _ = audio.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
            return rtcSendMessage(audioTrack, base, Int32(audio.count))
        }
    }

    func close() {
        if pc >= 0 {
            rtcClosePeerConnection(pc)
            rtcDeletePeerConnection(pc)
            pc = -1; videoTrack = -1; audioTrack = -1
        }
        if let held = retained {      // the library may still be running a last callback: let go a little later
            retained = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { held.release() }
        }
    }

    // MARK: the offer's media sections

    private func audioSection() -> String {
        """
        m=audio 9 UDP/TLS/RTP/SAVPF \(DiscordCodecs.opus)
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=rtcp-mux
        a=rtpmap:\(DiscordCodecs.opus) opus/48000/2
        a=fmtp:\(DiscordCodecs.opus) minptime=10;useinbandfec=1
        a=ssrc:\(audioSSRC) cname:porthole
        """
    }

    private func videoSection() -> String {
        let types = DiscordCodecs.video.flatMap { [String($0.pt), String($0.rtx)] }.joined(separator: " ")
        var lines = ["m=video 9 UDP/TLS/RTP/SAVPF \(types)", "c=IN IP4 0.0.0.0", "a=mid:1", "a=sendrecv", "a=rtcp-mux",
                     "a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"]
        for c in DiscordCodecs.video {
            lines.append("a=rtpmap:\(c.pt) \(c.name)/90000")
            lines.append("a=rtcp-fb:\(c.pt) nack")
            lines.append("a=rtcp-fb:\(c.pt) nack pli")
            lines.append("a=rtcp-fb:\(c.pt) goog-remb")
            if c.name == "H264" { lines.append("a=fmtp:\(c.pt) profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1") }
            lines.append("a=rtpmap:\(c.rtx) rtx/90000")
            lines.append("a=fmtp:\(c.rtx) apt=\(c.pt)")
        }
        lines.append("a=ssrc-group:FID \(videoSSRC) \(rtxSSRC)")
        lines.append("a=ssrc:\(videoSSRC) cname:porthole")
        lines.append("a=ssrc:\(rtxSSRC) cname:porthole")
        return lines.joined(separator: "\n")
    }
}
