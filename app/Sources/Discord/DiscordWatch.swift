// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreMedia
import Foundation

// Watching somebody else's Go Live (Discord branch, experimental). This file is the parts that need no network and no screen, so scripts can test them:
// the stream's name, an RTP packet, the H.264 pictures put back together from RTP packets, and the sample buffers the phone's display layer shows.

/// The name Discord gives a stream: `guild:<server>:<channel>:<owner>` in a server's voice channel, `call:<channel>:<owner>` in a direct message or group call.
enum DiscordStreamKey {
    static func make(guild: String?, channel: String, owner: String) -> String {
        guard let guild else { return "call:\(channel):\(owner)" }
        return "guild:\(guild):\(channel):\(owner)"
    }

    static func parse(_ key: String) -> (guild: String?, channel: String, owner: String)? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 4, parts[0] == "guild", !parts[1].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty { return (parts[1], parts[2], parts[3]) }
        if parts.count == 3, parts[0] == "call", !parts[1].isEmpty, !parts[2].isEmpty { return (nil, parts[1], parts[2]) }
        return nil
    }
}

/// One RTP packet, as the connection library hands it over after the transport's own decryption.
struct DiscordRTPPacket {
    var payloadType: UInt8
    var marker: Bool
    var sequence: UInt16
    var timestamp: UInt32
    var ssrc: UInt32
    var payload: Data

    /// A resend (RTX): the payload starts with the original sequence number, and the rest is the original payload. nil for a resend that carries nothing.
    func restoringRTX(payloadType: UInt8, ssrc: UInt32) -> DiscordRTPPacket? {
        guard payload.count > 2 else { return nil }
        let original = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
        return DiscordRTPPacket(payloadType: payloadType, marker: marker, sequence: original, timestamp: timestamp, ssrc: ssrc, payload: payload.dropFirst(2))
    }

    /// nil for anything that is not a well-formed RTP packet (RTCP, too short, wrong version).
    static func parse(_ data: Data) -> DiscordRTPPacket? {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let padding = b[0] & 0x20 != 0, extensionBit = b[0] & 0x10 != 0, csrc = Int(b[0] & 0x0F)
        var offset = 12 + csrc * 4
        guard b.count >= offset else { return nil }
        if extensionBit {
            guard b.count >= offset + 4 else { return nil }
            offset += 4 + (Int(b[offset + 2]) << 8 | Int(b[offset + 3])) * 4
        }
        var end = b.count
        if padding { guard let last = b.last, Int(last) > 0, Int(last) <= end - offset else { return nil }; end -= Int(last) }
        guard offset <= end else { return nil }
        // RTCP shares the port: its packet types (200 to 206) land on the payload-type bits with the marker set.
        let pt = b[1] & 0x7F
        if b[1] >= 192 && b[1] <= 223 { return nil }
        return DiscordRTPPacket(payloadType: pt, marker: b[1] & 0x80 != 0, sequence: UInt16(b[2]) << 8 | UInt16(b[3]),
                                timestamp: UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]),
                                ssrc: UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11]),
                                payload: Data(b[offset..<end]))
    }
}

/// Decides WHEN each picture is shown: a picture is shown a short, adaptive time after it was made (by the sender's own clock), not the moment it arrives. Pictures that arrive in bursts
/// then come out evenly, at the cost of a little delay (60 ms at least, up to 250 ms on a bad connection, and it shrinks back when the connection settles). Times are in seconds
/// from any steady clock; `schedule` returns the time to show the picture.
final class DiscordPlayout {
    private var base: UInt32?
    private var lastStamp: UInt32 = 0
    private var elapsed = 0.0
    private var anchor = 0.0
    private var lastTarget = 0.0
    /// How uneven the arrivals are (seconds), and the delay added for it.
    private(set) var jitter = 0.0
    private(set) var delay = 0.06
    var minDelay = 0.06, maxDelay = 0.25
    private(set) var late = 0, resyncs = 0, scheduled = 0
    private(set) var worstLate = 0.0

    func reset() { base = nil; late = 0; resyncs = 0; scheduled = 0; worstLate = 0; jitter = 0; delay = minDelay }

    /// `timestamp` is the picture's 90 kHz RTP time, `arrival` when its last packet came in.
    func schedule(timestamp: UInt32, arrival: Double) -> Double {
        if base == nil { base = timestamp; lastStamp = timestamp; elapsed = 0; anchor = arrival; lastTarget = 0; jitter = 0; delay = minDelay }
        else { elapsed += Double(Int32(bitPattern: timestamp &- lastStamp)) / 90000; lastStamp = timestamp }
        scheduled += 1
        // How far behind the sender's clock this picture is: the smallest such figure seen is the connection's best case.
        let observed = arrival - elapsed
        if observed < anchor { anchor = observed }
        else {
            let excess = observed - anchor
            if excess > 1.0 { anchor = observed; jitter = 0; resyncs += 1 }       // a long stall (or a paused stream): start again from here
            else { anchor += min(excess, 0.0004) }                                  // drifts up slowly, for a sender whose clock runs a little slower than ours
        }
        let deviation = max(0, observed - anchor)
        jitter = deviation > jitter ? deviation : jitter * 0.99 + deviation * 0.01
        let wanted = min(maxDelay, max(minDelay, jitter + 0.03))
        delay = wanted > delay ? wanted : delay * 0.99 + wanted * 0.01              // grows at once, shrinks over a few seconds
        var target = anchor + elapsed + delay
        if target <= lastTarget { target = lastTarget + 0.0005 }                    // never out of order
        lastTarget = target
        if target < arrival { late += 1; worstLate = max(worstLate, arrival - target) }
        return target
    }
}

/// How pictures are paced on the screen. Instant: the moment they arrive. Sender clock: by the times the sender stamped on them (DiscordPlayout). Steady: by the rhythm in which they arrive
/// (DiscordSteadyPacer), which needs no trust in the sender's stamps.
enum DiscordPacing: Int, CaseIterable {
    case steady, senderClock, instant
    static let key = "f4.discord.streamPacing"
    static var saved: DiscordPacing { DiscordPacing(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 0) ?? .steady }
    static func save(_ p: DiscordPacing) { UserDefaults.standard.set(p.rawValue, forKey: key) }
    var next: DiscordPacing { DiscordPacing(rawValue: (rawValue + 1) % Self.allCases.count) ?? .steady }
    var title: String { ["Steady", "Sender clock", "Instant"][rawValue] }
    var detail: String {
        ["Evens out the rhythm of the pictures as they arrive (a little delay).",
         "Shows each picture at the time the sender stamped on it (a little delay).",
         "Shows each picture the moment it arrives (no delay, uneven if the connection is)."][rawValue]
    }
}

/// Spreads pictures out evenly using only when they arrive: each is shown one usual interval after the one before it (the usual interval is the recent average, so bursts and gaps average
/// out). Pictures that arrive in a burst after a stall are shown a little faster than usual until the backlog is gone; when the buffer runs dry the next picture is shown at once.
final class DiscordSteadyPacer {
    var minLag = 0.06, maxLag = 0.25
    /// How much picture is kept in hand: it grows to cover the longest gaps seen lately (a stall of 150 ms is hidden by 135 ms in hand) and shrinks back over a few seconds.
    private(set) var lag = 0.06
    private var peak = 0.0
    private var interval = 1.0 / 30
    private var lastArrival = 0.0, lastTarget = 0.0
    private var started = false
    private(set) var backlog = 0.0, worstBacklog = 0.0, dry = 0, squeezed = 0
    var usualInterval: Double { interval }

    func reset() { started = false; interval = 1.0 / 30; dry = 0; squeezed = 0; worstBacklog = 0; backlog = 0; peak = 0; lag = minLag }

    func schedule(arrival: Double) -> Double {
        guard started else { started = true; lastArrival = arrival; lastTarget = arrival + lag; return lastTarget }
        let gap = arrival - lastArrival
        lastArrival = arrival
        interval += (min(max(gap, 0.004), 0.12) - interval) * 0.03
        peak = max(max(0, gap - interval), peak * 0.99)
        lag = min(maxLag, max(minLag, peak * 0.9))
        var target = lastTarget + interval
        if target < arrival {
            target = arrival; dry += 1                           // the buffer ran dry: nothing to wait for
        } else if target - arrival > maxLag {
            target = lastTarget + interval * 0.6; squeezed += 1   // too far behind: catch up a little faster than usual
        } else if target - arrival < lag {
            target = lastTarget + interval * 1.1                  // too little in hand: stretch a little to rebuild it
        }
        if target <= lastTarget { target = lastTarget + 0.0005 }
        lastTarget = target
        backlog = target - arrival
        worstBacklog = max(worstBacklog, backlog)
        return target
    }
}

/// The few RTCP messages a viewer sends (RFC 4585 / 3550), written by hand: the connection library only sends them for a track that has no media handler.
enum DiscordRTCP {
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

    /// "Send me a new key frame."
    static func pictureLoss(sender: UInt32, media: UInt32) -> Data { Data([0x81, 206, 0, 2] + be32(sender) + be32(media)) }

    /// "I did not get these packets": a generic NACK, the packets grouped as a first number and a mask of the 16 after it.
    static func nack(sender: UInt32, media: UInt32, missing: [UInt16]) -> Data? {
        let sorted = Array(Set(missing)).sorted { Int16(bitPattern: $0 &- ($1)) < 0 }
        guard !sorted.isEmpty else { return nil }
        var entries: [(pid: UInt16, mask: UInt16)] = []
        for seq in sorted {
            if let last = entries.last {
                let d = Int(UInt16(seq &- last.pid))
                if d >= 1 && d <= 16 { entries[entries.count - 1].mask |= 1 << UInt16(d - 1); continue }
            }
            entries.append((seq, 0))
        }
        var out: [UInt8] = [0x81, 205, UInt8((2 + entries.count) >> 8), UInt8((2 + entries.count) & 255)] + be32(sender) + be32(media)
        for e in entries { out += [UInt8(e.pid >> 8), UInt8(e.pid & 255), UInt8(e.mask >> 8), UInt8(e.mask & 255)] }
        return Data(out)
    }

    /// A receiver report about one sender: what share of its packets were lost, how many in all, how far its numbering has come.
    static func receiverReport(sender: UInt32, source: UInt32, fractionLost: UInt8, cumulativeLost: Int, highestSequence: UInt32, jitter: UInt32 = 0) -> Data {
        let lost = UInt32(max(0, min(cumulativeLost, 0xFFFFFF)))
        return Data([0x81, 201, 0, 7] + be32(sender) + be32(source) + [fractionLost, UInt8(lost >> 16), UInt8((lost >> 8) & 255), UInt8(lost & 255)] + be32(highestSequence) + be32(jitter) + be32(0) + be32(0))
    }
}

/// Puts RTP packets back in order. A packet that is missing is asked for again (the caller sends the NACK and the sender answers with an RTX copy that goes through `push` like any other),
/// and given up on after a short wait, so a damaged picture never holds up the ones after it for long. Times are in seconds from any steady clock.
final class DiscordRTPReorder {
    struct Output {
        /// Packets now in order, ready for the depacketizer.
        var packets: [DiscordRTPPacket] = []
        /// Packets to ask for.
        var nack: [UInt16] = []
        /// A packet was given up on (or the numbering jumped): the picture it belonged to is lost.
        var gaveUp = false
    }

    private var next: UInt16?
    private var buffer: [UInt16: DiscordRTPPacket] = [:]
    private var missing: [UInt16: (first: Double, last: Double, tries: Int)] = [:]
    /// Longest wait for a missing packet, how often it is asked for again, and how many times.
    var giveUpAfter = 0.25, askAgainAfter = 0.04, maxAsks = 5
    /// A packet that is only a little late (out of order) arrives by itself: it is not asked for until it has been missing this long.
    var firstAskAfter = 0.012
    private(set) var recovered = 0, givenUp = 0, duplicates = 0, asked = 0
    /// For receiver reports: how many packets came (restored ones included), and the highest number so far with its wrap count.
    private(set) var received = 0, cycles: UInt32 = 0
    private(set) var highest: UInt16 = 0

    func reset() { next = nil; buffer = [:]; missing = [:] }

    var extendedHighest: UInt32 { cycles << 16 | UInt32(highest) }

    func push(_ p: DiscordRTPPacket, now: Double, restored: Bool = false) -> Output {
        var out = Output()
        received += 1
        guard let expected = next else {
            next = p.sequence &+ 1; highest = p.sequence; out.packets = [p]; return out
        }
        let d = Int(Int16(bitPattern: p.sequence &- expected))
        if d == 0 {
            if missing.removeValue(forKey: p.sequence) != nil, restored { recovered += 1 }
            out.packets.append(p); next = expected &+ 1; advanceHighest(p.sequence)
            drain(&out)
        } else if d > 0 && d < 1500 {
            if buffer[p.sequence] != nil { duplicates += 1; return out }
            buffer[p.sequence] = p
            if missing.removeValue(forKey: p.sequence) != nil, restored { recovered += 1 }
            advanceHighest(p.sequence)
            // Everything between the next expected number and this one that is not here yet is missing.
            var seq = expected
            while seq != p.sequence {
                if buffer[seq] == nil, missing[seq] == nil { missing[seq] = (now, now, 0) }
                seq &+= 1
            }
            if buffer.count > 512 { giveUp(&out) }
        } else if d < 0 {
            duplicates += 1                      // late or repeated: already delivered or given up on
        } else {
            // The numbering jumped far ahead: a new stream (or a long gap). Start again from here.
            buffer = [:]; missing = [:]
            out.gaveUp = true; givenUp += 1
            next = p.sequence &+ 1; highest = p.sequence
            out.packets.append(p)
        }
        return out
    }

    /// Call every 10 to 20 ms: asks again for what is still missing, and gives up on what has waited too long.
    func tick(now: Double) -> Output {
        var out = Output()
        guard let expected = next, !missing.isEmpty else { return out }
        if let first = missing[expected], now - first.first > giveUpAfter { giveUp(&out); return out }
        for seq in missing.keys.sorted(by: { Int16(bitPattern: $0 &- $1) < 0 }) {
            guard var m = missing[seq], m.tries < maxAsks else { continue }
            if m.tries == 0 ? now - m.first < firstAskAfter : now - m.last <= askAgainAfter { continue }
            m.last = now; m.tries += 1; missing[seq] = m
            out.nack.append(seq); asked += 1
        }
        return out
    }

    private func advanceHighest(_ seq: UInt16) {
        guard Int16(bitPattern: seq &- highest) > 0 else { return }       // an older number (a resend) never moves it back
        if seq < highest { cycles &+= 1 }                                    // ahead, but a smaller number: the numbering wrapped
        highest = seq
    }

    private func drain(_ out: inout Output) {
        while let n = next, let p = buffer.removeValue(forKey: n) { out.packets.append(p); next = n &+ 1 }
    }

    /// The oldest packet that is missing is not coming: carry on from the first one that is here.
    private func giveUp(_ out: inout Output) {
        guard let expected = next else { return }
        out.gaveUp = true; givenUp += 1
        var seq = expected
        var steps = 0
        while buffer[seq] == nil, steps < 2000 { missing.removeValue(forKey: seq); seq &+= 1; steps += 1 }
        if buffer[seq] == nil { buffer = [:]; missing = [:]; return }
        next = seq
        drain(&out)
        for key in missing.keys where Int(Int16(bitPattern: key &- (next ?? seq))) < 0 { missing.removeValue(forKey: key) }
    }
}

/// Puts a picture back together from its H.264 RTP packets (single NAL units, STAP-A, FU-A). The picture comes out as Annex B with 3-byte start codes, the shape Discord's end-to-end
/// encryption was applied to. A missing packet drops the picture it belonged to and says so, so the caller can ask for a new key frame.
final class DiscordH264Depacketizer {
    enum Result {
        case none
        /// A whole picture.
        case picture(Data, isKey: Bool, timestamp: UInt32)
        /// A picture could not be completed (a packet was missing).
        case lost
    }

    private var last: UInt16?
    private var timestamp: UInt32?
    private var nals: [Data] = []
    private var fragment: Data?
    private var broken = false
    private(set) var gaps = 0
    /// The NAL units (no start codes) of the picture that `push` returned last, so the picture can be put together again with other start codes.
    private(set) var lastNals: [Data] = []

    /// Start codes the sender may have used: end-to-end encryption covers them (they are in the checked bytes), so a picture only opens when they are put back as they were.
    /// 0: all three bytes (00 00 01), 1: all four bytes (00 00 00 01), 2: the first NAL unit four bytes and the rest three.
    static let startStyles = 3
    static func annexB(_ nals: [Data], style: Int) -> Data {
        var out = Data()
        for (i, n) in nals.enumerated() {
            let long = style == 1 || (style == 2 && i == 0)
            out.append(contentsOf: long ? [0, 0, 0, 1] : [0, 0, 1])
            out.append(n)
        }
        return out
    }

    func reset() { last = nil; timestamp = nil; nals = []; fragment = nil; broken = false }

    /// The packet source gave up on a packet: the picture being put together is not whole, and the next packet will not follow the last one.
    func noteLoss() { broken = true; fragment = nil }

    func push(_ p: DiscordRTPPacket) -> Result {
        var outcome = Result.none
        var gap = false
        if let last, p.sequence != last &+ 1 { gaps += 1; gap = true }
        last = p.sequence
        if timestamp != p.timestamp {
            // A new picture starts. The one before it never reached its last packet: it is lost.
            if timestamp != nil, !nals.isEmpty || fragment != nil { outcome = .lost }
            timestamp = p.timestamp; nals = []; fragment = nil; broken = false
        }
        // A packet is missing: the picture this one belongs to (or the one it begins) cannot be trusted.
        if gap { broken = true; fragment = nil }
        let payload = p.payload
        if let first = payload.first {
            switch first & 0x1F {
            case 1...23: nals.append(payload)
            case 24:
                var i = payload.startIndex + 1
                while i + 2 <= payload.endIndex {
                    let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                    i += 2
                    guard size > 0, i + size <= payload.endIndex else { broken = true; break }
                    nals.append(payload.subdata(in: i..<i + size))
                    i += size
                }
            case 28:
                guard payload.count >= 3 else { broken = true; break }
                let header = payload[payload.startIndex + 1]
                let start = header & 0x80 != 0, end = header & 0x40 != 0
                let body = payload.dropFirst(2)
                if start { fragment = Data([(first & 0xE0) | (header & 0x1F)]) + body }
                else if fragment != nil { fragment?.append(body) }
                else { broken = true }
                if end, let done = fragment { nals.append(done); fragment = nil }
            default: break
            }
        }
        if p.marker {
            defer { nals = []; fragment = nil; broken = false; timestamp = nil }
            if broken || fragment != nil || nals.isEmpty { return .lost }
            lastNals = nals
            let key = nals.contains { ($0.first ?? 0) & 0x1F == 5 }
            return .picture(Self.annexB(nals, style: 0), isKey: key, timestamp: p.timestamp)
        }
        return outcome
    }
}

/// Turns pictures (Annex B) into sample buffers that an `AVSampleBufferDisplayLayer` decodes and shows by itself. Needs the stream's SPS and PPS first (a key frame carries them).
final class DiscordH264Sampler {
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private(set) var size = CGSize.zero

    func reset() { sps = nil; pps = nil; format = nil; size = .zero }

    /// nil until the parameter sets have been seen, or when the picture holds nothing to show. `immediately` shows it at once; otherwise the layer shows it when its timebase reaches `time`.
    func sample(from annexB: Data, at time: CMTime, immediately: Bool = true) -> CMSampleBuffer? {
        let units = DiscordAnnexB.nalUnits(annexB)
        var avcc = Data()
        for n in units {
            guard let h = n.first else { continue }
            switch h & 0x1F {
            case 7: if sps != n { sps = n; format = nil }
            case 8: if pps != n { pps = n; format = nil }
            case 1, 5, 6: var length = UInt32(n.count).bigEndian; avcc.append(Data(bytes: &length, count: 4)); avcc.append(n)
            default: break      // access unit delimiters, end of sequence and the like
            }
        }
        if format == nil, let sps, let pps {
            var created: CMVideoFormatDescription?
            let status = sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                              nalUnitHeaderLength: 4, formatDescriptionOut: &created)
                }
            }
            if status == noErr, let created { format = created; let d = CMVideoFormatDescriptionGetDimensions(created); size = CGSize(width: Int(d.width), height: Int(d.height)) }
        }
        guard let format, !avcc.isEmpty, avcc.count > 4 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var length = avcc.count
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &out) == noErr, let out else { return nil }
        if immediately, let attachments = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return out
    }
}

/// Annex B helper: the NAL units of an access unit, without start codes (3- or 4-byte start codes).
enum DiscordAnnexB {
    static func nalUnits(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(at: Int, length: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            let from = start.at + start.length
            let to = index + 1 < starts.count ? starts[index + 1].at : b.count
            return from < to ? Data(b[from..<to]) : nil
        }
    }
}
