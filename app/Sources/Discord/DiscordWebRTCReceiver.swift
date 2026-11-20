// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// Watching somebody's Go Live over WebRTC (Discord branch, experimental): the same way in as DiscordWebRTC (libdatachannel does ICE, DTLS and SRTP), but with two receive-only
// tracks. libdatachannel hands each RTP packet to the track whose SSRC the descriptions name, so the streamer's two numbers (sound and picture, from the voice server's video
// message) go into the answer text.

/// Ways the viewer's connection can differ, to try when a stream will not show. Each attempt uses the next one (the log says which); the one that shows a picture is the answer.
struct DiscordWatchVariant {
    let name: String
    /// How the server's side is described in the answer: "sendonly" is what it really does, "inactive" is what the sending client's answer says.
    var direction = "sendonly"
    /// Name the streamer's numbers in the answer (needed to route the packets to a track).
    var ssrcLines = true
    /// Send the same stream description in the identify message as a streamer does.
    var identifyStreams = false

    static let all: [DiscordWatchVariant] = [
        DiscordWatchVariant(name: "receive-only"),
        DiscordWatchVariant(name: "receive-only, announces a stream", identifyStreams: true),
        DiscordWatchVariant(name: "inactive answer", direction: "inactive"),
    ]
    static let indexKey = "f4.discordWatchVariant"
    /// The variant for this attempt; the next attempt uses the following one.
    static func next() -> (index: Int, variant: DiscordWatchVariant) {
        let d = UserDefaults.standard
        let i = d.integer(forKey: indexKey) % all.count
        d.set(i + 1, forKey: indexKey)
        return (i, all[i])
    }
    /// A picture showed: the next watch starts with the same variant again.
    static func worked(_ index: Int) { UserDefaults.standard.set(index, forKey: indexKey) }
}

final class DiscordWebRTCReceiver: @unchecked Sendable {
    /// Called on libdatachannel's threads.
    var onOffer: ((String) -> Void)?
    var onState: ((String) -> Void)?
    /// A raw RTP packet (already opened by the transport) on the video or the sound track.
    var onVideo: ((Data) -> Void)?
    var onAudio: ((Data) -> Void)?
    var log: ((String) -> Void)?

    private var pc: Int32 = -1, audioTrack: Int32 = -1, videoTrack: Int32 = -1
    private var retained: Unmanaged<DiscordWebRTCReceiver>?
    private(set) var videoPackets = 0, audioPackets = 0
    private let variant: DiscordWatchVariant

    init(variant: DiscordWatchVariant) { self.variant = variant }

    /// Creates the connection and its two receive-only tracks, and asks for the offer (delivered to `onOffer`).
    func start() -> Bool {
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
            Unmanaged<DiscordWebRTCReceiver>.fromOpaque(ptr).takeUnretainedValue().onOffer?(String(cString: sdp))
        }
        rtcSetStateChangeCallback(pc) { _, state, ptr in
            guard let ptr else { return }
            let names = ["new", "connecting", "connected", "disconnected", "failed", "closed"]
            let name = Int(state.rawValue) < names.count ? names[Int(state.rawValue)] : "state \(state.rawValue)"
            Unmanaged<DiscordWebRTCReceiver>.fromOpaque(ptr).takeUnretainedValue().onState?(name)
        }
        rtcSetIceStateChangeCallback(pc) { _, state, ptr in
            guard let ptr else { return }
            let names = ["new", "checking", "connected", "completed", "failed", "disconnected", "closed"]
            let name = Int(state.rawValue) < names.count ? names[Int(state.rawValue)] : "state \(state.rawValue)"
            Unmanaged<DiscordWebRTCReceiver>.fromOpaque(ptr).takeUnretainedValue().onState?("ice \(name)")
        }
        audioTrack = rtcAddTrack(pc, audioSection())
        videoTrack = rtcAddTrack(pc, videoSection())
        guard audioTrack >= 0, videoTrack >= 0 else { log?("could not add the tracks (\(audioTrack), \(videoTrack))"); return false }
        for track in [audioTrack, videoTrack] {
            rtcSetUserPointer(track, me.toOpaque())
            rtcSetMessageCallback(track) { id, message, size, ptr in
                guard let message, let ptr, size > 0 else { return }
                let this = Unmanaged<DiscordWebRTCReceiver>.fromOpaque(ptr).takeUnretainedValue()
                let data = Data(bytes: message, count: Int(size))
                if id == this.videoTrack { this.videoPackets += 1; this.onVideo?(data) } else { this.audioPackets += 1; this.onAudio?(data) }
            }
        }
        // The sound track has the library's own receiver reports. The picture track has no media handler on purpose: only then does the library let a track send RTCP, and the picture
        // track has to (resend requests, picture-loss requests and receiver reports are written by hand, see DiscordRTCP).
        let a = rtcChainRtcpReceivingSession(audioTrack)
        log?("tracks added (sound \(audioTrack), picture \(videoTrack)); sound receiver reports \(a); variant \(variant.name)")
        let result = rtcSetLocalDescription(pc, nil)
        if result < 0 { log?("could not create the offer (\(result))"); return false }
        return true
    }

    /// Writes a complete answer from the few lines of the server's incomplete one, with the streamer's numbers. `audioSSRC` / `videoSSRC` are nil when the server has not said yet.
    func setAnswer(serverSDP: String, audioSSRC: UInt32?, videoSSRC: UInt32?, rtxSSRC: UInt32? = nil) -> Bool {
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
            return false
        }
        let pt = DiscordCodecs.opus
        var audio = """
        m=audio \(port) UDP/TLS/RTP/SAVPF \(pt)
        \(ip)
        a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
        a=setup:passive
        a=mid:0
        a=maxptime:60
        a=\(variant.direction)
        \(ufrag)
        \(pwd)
        \(fingerprint)
        \(candidate)
        a=rtcp-mux
        a=rtpmap:\(pt) opus/48000/2
        a=fmtp:\(pt) minptime=10;useinbandfec=1;usedtx=1
        a=rtcp-fb:\(pt) nack
        a=ice-lite
        """
        if variant.ssrcLines, let audioSSRC { audio += "\na=ssrc:\(audioSSRC) cname:stream" }
        var video = """
        m=video \(port) UDP/TLS/RTP/SAVPF \(DiscordCodecs.h264) \(DiscordCodecs.h264RTX)
        \(ip)
        a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
        a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay
        a=setup:passive
        a=mid:1
        a=\(variant.direction)
        \(ufrag)
        \(pwd)
        \(fingerprint)
        \(candidate)
        a=rtcp-mux
        a=ice-lite
        a=rtpmap:\(DiscordCodecs.h264) H264/90000
        a=rtpmap:\(DiscordCodecs.h264RTX) rtx/90000
        a=fmtp:\(DiscordCodecs.h264RTX) apt=\(DiscordCodecs.h264)
        a=fmtp:\(DiscordCodecs.h264) profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1
        a=rtcp-fb:\(DiscordCodecs.h264) nack
        a=rtcp-fb:\(DiscordCodecs.h264) nack pli
        a=rtcp-fb:\(DiscordCodecs.h264) goog-remb
        """
        if variant.ssrcLines, let videoSSRC { video += "\na=ssrc:\(videoSSRC) cname:stream" }
        if variant.ssrcLines, let rtxSSRC, let videoSSRC { video += "\na=ssrc:\(rtxSSRC) cname:stream\na=ssrc-group:FID \(videoSSRC) \(rtxSSRC)" }
        let answer = [audio, video].joined(separator: "\n")
        let result = rtcSetRemoteDescription(pc, answer, "answer")
        if result < 0 { log?("the connection refused the server's answer (\(result))") }
        return result >= 0
    }

    /// Sends one RTCP message on the picture track.
    /// False when it could not go (the track is not open yet).
    @discardableResult
    func sendRTCP(_ message: Data) -> Bool {
        guard videoTrack >= 0, rtcIsOpen(videoTrack) else { return false }
        let result = message.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
            return rtcSendMessage(videoTrack, base, Int32(message.count))
        }
        return result >= 0
    }

    var isOpen: Bool { videoTrack >= 0 && rtcIsOpen(videoTrack) }

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
        a=recvonly
        a=rtcp-mux
        a=rtpmap:\(DiscordCodecs.opus) opus/48000/2
        a=fmtp:\(DiscordCodecs.opus) minptime=10;useinbandfec=1
        """
    }

    private func videoSection() -> String {
        let h = DiscordCodecs.h264, r = DiscordCodecs.h264RTX
        return ["m=video 9 UDP/TLS/RTP/SAVPF \(h) \(r)", "c=IN IP4 0.0.0.0", "a=mid:1", "a=recvonly", "a=rtcp-mux",
                "a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay",
                "a=rtpmap:\(h) H264/90000", "a=rtcp-fb:\(h) nack", "a=rtcp-fb:\(h) nack pli", "a=rtcp-fb:\(h) goog-remb",
                "a=fmtp:\(h) profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1",
                "a=rtpmap:\(r) rtx/90000", "a=fmtp:\(r) apt=\(h)"].joined(separator: "\n")
    }
}
