#!/bin/bash
# Watching somebody's Go Live: the stream's name, RTP packets, H.264 pictures put back together from them (with packets lost), and sample buffers a decoder accepts
# (Sources/Discord/DiscordWatch.swift). The pictures are made by the Mac's own hardware encoder, then split into RTP the way a sender's packetizer does.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

// Stream names
check(DiscordStreamKey.make(guild: "11", channel: "22", owner: "33") == "guild:11:22:33", "a server stream's name")
check(DiscordStreamKey.make(guild: nil, channel: "22", owner: "33") == "call:22:33", "a call stream's name")
check(DiscordStreamKey.parse("guild:11:22:33")?.owner == "33" && DiscordStreamKey.parse("guild:11:22:33")?.guild == "11", "a server name is read back")
check(DiscordStreamKey.parse("call:22:33")?.guild == nil && DiscordStreamKey.parse("call:22:33")?.channel == "22", "a call name is read back")
check(DiscordStreamKey.parse("guild:11:22") == nil && DiscordStreamKey.parse("call:") == nil && DiscordStreamKey.parse("x:1:2:3") == nil, "malformed names are refused")

// RTP packets
func rtp(pt: UInt8, marker: Bool, seq: UInt16, ts: UInt32, ssrc: UInt32, payload: [UInt8], extra: [UInt8] = [], csrc: Int = 0, padding: Int = 0) -> Data {
    var b: [UInt8] = [0x80 | (extra.isEmpty ? 0 : 0x10) | (padding > 0 ? 0x20 : 0) | UInt8(csrc), (marker ? 0x80 : 0) | pt, UInt8(seq >> 8), UInt8(seq & 255),
                      UInt8(ts >> 24), UInt8((ts >> 16) & 255), UInt8((ts >> 8) & 255), UInt8(ts & 255), UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 255), UInt8((ssrc >> 8) & 255), UInt8(ssrc & 255)]
    for _ in 0..<csrc { b += [0, 0, 0, 7] }
    if !extra.isEmpty { b += [0xBE, 0xDE, 0, UInt8(extra.count / 4)] + extra }
    b += payload
    if padding > 0 { b += [UInt8](repeating: 0, count: padding - 1) + [UInt8(padding)] }
    return Data(b)
}
let plain = DiscordRTPPacket.parse(rtp(pt: 101, marker: true, seq: 65535, ts: 0xAABBCCDD, ssrc: 0x01020304, payload: [1, 2, 3]))
check(plain?.payloadType == 101 && plain?.marker == true && plain?.sequence == 65535 && plain?.timestamp == 0xAABBCCDD && plain?.ssrc == 0x01020304 && plain?.payload == Data([1, 2, 3]), "a plain packet is read")
let fancy = DiscordRTPPacket.parse(rtp(pt: 120, marker: false, seq: 7, ts: 1, ssrc: 2, payload: [9, 9], extra: [1, 2, 3, 4, 5, 6, 7, 8], csrc: 2, padding: 3))
check(fancy?.payload == Data([9, 9]) && fancy?.payloadType == 120 && fancy?.marker == false, "contributing sources, a header extension and padding are skipped")
check(DiscordRTPPacket.parse(Data([0x80, 0xC8, 0, 6, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0])) == nil, "an RTCP sender report is not RTP")
check(DiscordRTPPacket.parse(Data([0x80, 101, 0])) == nil && DiscordRTPPacket.parse(Data()) == nil && DiscordRTPPacket.parse(Data([UInt8](repeating: 0x40, count: 20))) == nil, "short or wrong-version data is refused")

// The packetizer a sender uses: STAP-A for small NAL units that fit together, FU-A for big ones
func packetize(_ au: Data, ts: UInt32, seq: inout UInt16, max: Int = 1200) -> [DiscordRTPPacket] {
    let nals = DiscordAnnexB.nalUnits(au)
    var out: [DiscordRTPPacket] = []
    func add(_ payload: Data, last: Bool) { out.append(DiscordRTPPacket(payloadType: 101, marker: last, sequence: seq, timestamp: ts, ssrc: 5, payload: payload)); seq &+= 1 }
    for (i, n) in nals.enumerated() {
        let last = i == nals.count - 1
        if n.count <= max { add(n, last: last) }
        else {
            let type = n[n.startIndex] & 0x1F, nri = n[n.startIndex] & 0x60
            var offset = n.startIndex + 1
            while offset < n.endIndex {
                let size = min(max - 2, n.endIndex - offset)
                let first = offset == n.startIndex + 1, end = offset + size == n.endIndex
                add(Data([nri | 28, (first ? 0x80 : 0) | (end ? 0x40 : 0) | type]) + n.subdata(in: offset..<offset + size), last: last && end)
                offset += size
            }
        }
    }
    return out
}
func stap(_ nals: [Data], seq: UInt16, ts: UInt32, last: Bool) -> DiscordRTPPacket {
    var p = Data([24])
    for n in nals { p.append(contentsOf: [UInt8(n.count >> 8), UInt8(n.count & 255)]); p.append(n) }
    return DiscordRTPPacket(payloadType: 101, marker: last, sequence: seq, timestamp: ts, ssrc: 5, payload: p)
}

// Pictures from the Mac's own hardware encoder
final class Collector { var pictures: [(Data, Bool)] = [] }
func makeFrame(_ n: Int, _ w: Int, _ h: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer!)
    for y in 0..<h { for x in 0..<w { let o = y * stride + x * 4; base[o] = UInt8((x + n * 9) & 255); base[o + 1] = UInt8((y * 2 + n * 5) & 255); base[o + 2] = UInt8((x ^ y ^ n) & 255); base[o + 3] = 255 } }
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    return buffer!
}
var session: VTCompressionSession?
let (W, H) = (640, 360)
VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AverageBitRate, value: 3_000_000 as CFNumber)
VTCompressionSessionPrepareToEncodeFrames(session!)
let collected = Collector()
let lock = NSLock()
for n in 0..<12 {
    VTCompressionSessionEncodeFrame(session!, imageBuffer: makeFrame(n, W, H), presentationTimeStamp: CMTime(value: CMTimeValue(n), timescale: 30), duration: .invalid, frameProperties: n == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil, infoFlagsOut: nil) { status, _, sample in
        guard status == noErr, let sample else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var out = Data()
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?; var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let p { out.append(contentsOf: [0, 0, 1]); out.append(p, count: size) }
            }
        }
        var length = 0; var base: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sample)!, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base)
        let bytes = UnsafeRawPointer(base!).assumingMemoryBound(to: UInt8.self)
        var off = 0
        while off + 4 <= length { let size = Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3]); off += 4; out.append(contentsOf: [0, 0, 1]); out.append(bytes + off, count: size); off += size }
        lock.lock(); collected.pictures.append((out, isKey)); lock.unlock()
    }
}
VTCompressionSessionCompleteFrames(session!, untilPresentationTimeStamp: .invalid)
let pictures = collected.pictures
check(pictures.count == 12 && pictures[0].1 && !pictures[1].1, "the Mac's encoder gave 12 pictures, the first a key frame")
check(pictures[0].0.count > 1200, "the key frame is big enough to be split into several packets (\(pictures[0].0.count) bytes)")

// Whole stream with nothing lost, packetized with FU-A (and STAP-A for the key frame's SPS and PPS)
var seq: UInt16 = 65530      // wraps around
var rebuilt: [(Data, Bool)] = []
let depack = DiscordH264Depacketizer()
for (i, pic) in pictures.enumerated() {
    var packets = packetize(pic.0, ts: UInt32(i) * 3000, seq: &seq)
    if pic.1 {
        // joins the first two small NAL units (SPS, PPS) into one STAP-A packet, as WebRTC senders do
        let nals = DiscordAnnexB.nalUnits(pic.0)
        var joined = [stap(Array(nals[0..<2]), seq: packets[0].sequence, ts: UInt32(i) * 3000, last: false)]
        joined += packets.dropFirst(2).enumerated().map { j, p in var q = p; q.sequence = packets[0].sequence &+ UInt16(j + 1); return q }
        packets = joined
        seq = packets.last!.sequence &+ 1
    }
    for p in packets { if case .picture(let data, let key, let ts) = depack.push(p) { rebuilt.append((data, key)); check(ts == UInt32(i) * 3000, "picture \(i) keeps its time") } }
}
check(rebuilt.count == 12, "all 12 pictures come back")
check(zip(rebuilt, pictures).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }, "every picture is byte for byte what was sent, key frames marked")
check(depack.gaps == 0, "no gaps reported")
// The same NAL units put back with other start codes
let sample = [Data([0x67, 1]), Data([0x68, 2]), Data([0x65, 3, 4])]
check(DiscordH264Depacketizer.annexB(sample, style: 0) == Data([0,0,1,0x67,1, 0,0,1,0x68,2, 0,0,1,0x65,3,4]), "start codes style 0 is three bytes each")
check(DiscordH264Depacketizer.annexB(sample, style: 1) == Data([0,0,0,1,0x67,1, 0,0,0,1,0x68,2, 0,0,0,1,0x65,3,4]), "style 1 is four bytes each")
check(DiscordH264Depacketizer.annexB(sample, style: 2) == Data([0,0,0,1,0x67,1, 0,0,1,0x68,2, 0,0,1,0x65,3,4]), "style 2 is four bytes on the first only")
check(DiscordAnnexB.nalUnits(DiscordH264Depacketizer.annexB(sample, style: 1)) == sample, "and the NAL units read back the same")

// Packets lost: a middle packet of a big picture, then recovery
let loss = DiscordH264Depacketizer()
var s2: UInt16 = 100
var got: [String] = []
func run(_ packets: [DiscordRTPPacket], drop: Int? = nil) {
    for (i, p) in packets.enumerated() where i != drop {
        switch loss.push(p) { case .picture(_, let k, _): got.append(k ? "key" : "delta"); case .lost: got.append("lost"); case .none: break }
    }
}
run(packetize(pictures[0].0, ts: 0, seq: &s2))
let big = packetize(pictures[0].0, ts: 3000, seq: &s2)
run(big, drop: big.count / 2)
run(packetize(pictures[1].0, ts: 6000, seq: &s2))
check(got == ["key", "lost", "delta"], "a lost packet loses that picture only (\(got))")
var tailLost = packetize(pictures[2].0, ts: 9000, seq: &s2)
tailLost.removeLast()      // the last packet (with the marker) never arrives: the next picture shows it was lost
var got2: [String] = []
for p in tailLost { if case .lost = loss.push(p) { got2.append("lost") } }
for p in packetize(pictures[3].0, ts: 12000, seq: &s2) { switch loss.push(p) { case .lost: got2.append("lost"); case .picture: got2.append("picture"); case .none: break } }
check(got2.contains("lost"), "a picture whose last packet is missing is reported lost (\(got2))")
let lonelyEnd = DiscordH264Depacketizer()
check({ if case .lost = lonelyEnd.push(DiscordRTPPacket(payloadType: 101, marker: false, sequence: 1, timestamp: 1, ssrc: 5, payload: Data([0x7C, 0x40, 1, 2]))) { return false }; return true }(), "the end of a fragmented NAL with no start does not crash")

// Sample buffers: the decoder takes them and gives back pictures of the right size
let sampler = DiscordH264Sampler()
check(sampler.sample(from: pictures[1].0, at: .zero) == nil, "a delta picture before any key frame gives nothing to show")
let first = sampler.sample(from: pictures[0].0, at: CMTime(value: 0, timescale: 90000))
check(first != nil && Int(sampler.size.width) == W && Int(sampler.size.height) == H, "the key frame gives a sample of \(Int(sampler.size.width))x\(Int(sampler.size.height))")
var decoded = 0
var decodeSession: VTDecompressionSession?
if let first, let format = CMSampleBufferGetFormatDescription(first) {
    VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decodeSession)
    for (i, pic) in pictures.enumerated() {
        guard let s = sampler.sample(from: pic.0, at: CMTime(value: CMTimeValue(i * 3000), timescale: 90000)) else { continue }
        VTDecompressionSessionDecodeFrame(decodeSession!, sampleBuffer: s, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image, CVPixelBufferGetWidth(image) == W, CVPixelBufferGetHeight(image) == H { lock.lock(); decoded += 1; lock.unlock() }
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(decodeSession!)
}
check(decoded == 12, "the system decoder shows all 12 pictures (\(decoded))")
sampler.reset()
check(sampler.sample(from: pictures[1].0, at: .zero) == nil, "after a reset it waits for a key frame again")

// RTCP written by hand
check(DiscordRTCP.pictureLoss(sender: 1, media: 0x01020304) == Data([0x81, 206, 0, 2, 0, 0, 0, 1, 1, 2, 3, 4]), "a picture-loss request")
check(DiscordRTCP.nack(sender: 1, media: 2, missing: [100, 101, 103, 116, 200]) == Data([0x81, 205, 0, 4, 0,0,0,1, 0,0,0,2, 0,100, 0x80,0x05, 0,200, 0,0]), "a resend request groups packets after the first (101, 103 and 116 follow 100; 200 stands alone)")
check(DiscordRTCP.nack(sender: 1, media: 2, missing: [65535, 0, 1]) == Data([0x81, 205, 0, 3, 0,0,0,1, 0,0,0,2, 0xFF,0xFF, 0,3]), "a resend request across the wrap-around")
check(DiscordRTCP.nack(sender: 1, media: 2, missing: []) == nil, "nothing missing, no request")
let rr = DiscordRTCP.receiverReport(sender: 5, source: 6, fractionLost: 25, cumulativeLost: 300, highestSequence: 0x00010002)
check(rr.count == 32 && rr[0] == 0x81 && rr[1] == 201 && rr[3] == 7 && rr[12] == 25 && rr[13] == 0 && rr[14] == 1 && rr[15] == 44 && Array(rr[16..<20]) == [0, 1, 0, 2], "a receiver report")

// Putting packets back in order
func pkt(_ n: UInt16, ts: UInt32 = 0) -> DiscordRTPPacket { DiscordRTPPacket(payloadType: 101, marker: false, sequence: n, timestamp: ts, ssrc: 9, payload: Data([UInt8(n & 255)])) }
func seqs(_ o: DiscordRTPReorder.Output) -> [UInt16] { o.packets.map(\.sequence) }
do {
    let r = DiscordRTPReorder()
    var delivered: [UInt16] = []
    for n in [UInt16(10), 11, 12] { delivered += seqs(r.push(pkt(n), now: Double(n))) }
    check(delivered == [10, 11, 12], "packets in order pass straight through")
    // 13 arrives after 14: it is held, then both come in order, and a packet that is only a little late is not asked for at once
    check(seqs(r.push(pkt(14), now: 20)) == [] && r.tick(now: 20.005).nack.isEmpty, "a packet ahead of a gap is held, and the gap is not asked for at once")
    check(seqs(r.push(pkt(13), now: 20.008)) == [13, 14], "the late packet fills the gap and both go on in order")
    check(r.tick(now: 21).nack.isEmpty && !r.tick(now: 21).gaveUp, "nothing is left to ask for")
}
do {
    let r = DiscordRTPReorder()
    _ = r.push(pkt(65533), now: 0); _ = r.push(pkt(65534), now: 0.01)
    var out = r.push(pkt(1), now: 0.02)       // 65535 and 0 are missing
    check(out.packets.isEmpty, "across the wrap-around: held behind the gap")
    out = r.tick(now: 0.04)
    check(out.nack.sorted() == [0, 65535], "both missing numbers are asked for after a short wait (\(out.nack))")
    out = r.push(pkt(65535), now: 0.05, restored: true)
    check(seqs(out) == [65535], "the first resend comes in and goes on")
    out = r.push(pkt(0), now: 0.06, restored: true)
    check(seqs(out) == [0, 1] && r.recovered == 2, "the second resend releases what was held (\(seqs(out)), recovered \(r.recovered))")
    check(r.extendedHighest == (UInt32(1) << 16) | 1, "the highest number counts the wrap (\(r.extendedHighest))")
}
do {
    let r = DiscordRTPReorder()
    _ = r.push(pkt(1), now: 0)
    _ = r.push(pkt(4), now: 0.1)
    check(r.tick(now: 0.12).nack.sorted() == [2, 3], "two lost packets are asked for")
    check(r.tick(now: 0.13).nack.isEmpty, "not again straight away")
    check(r.tick(now: 0.17).nack.sorted() == [2, 3], "asked for again after a pause")
    let out = r.tick(now: 0.4)
    check(out.gaveUp && seqs(out) == [4], "after a quarter of a second it gives up and goes on from the next packet (\(out.gaveUp), \(seqs(out)))")
    check(r.tick(now: 0.5).nack.isEmpty, "and stops asking")
    check(r.push(pkt(2), now: 0.6, restored: true).packets.isEmpty && r.duplicates >= 1, "a resend that comes too late is ignored")
}
do {
    let r = DiscordRTPReorder()
    _ = r.push(pkt(1), now: 0)
    let out = r.push(pkt(30000), now: 0.1)
    check(out.gaveUp && seqs(out) == [30000], "a numbering that jumps far starts again")
}
let rtx = DiscordRTPPacket(payloadType: 102, marker: true, sequence: 5000, timestamp: 77, ssrc: 12, payload: Data([0x12, 0x34, 9, 8, 7]))
let back = rtx.restoringRTX(payloadType: 101, ssrc: 9)
check(back?.sequence == 0x1234 && back?.payload == Data([9, 8, 7]) && back?.marker == true && back?.timestamp == 77 && back?.ssrc == 9 && back?.payloadType == 101, "a resend packet is turned back into the original")
check(DiscordRTPPacket(payloadType: 102, marker: false, sequence: 1, timestamp: 1, ssrc: 1, payload: Data([0, 1])).restoringRTX(payloadType: 101, ssrc: 9) == nil, "a resend that carries nothing is dropped")

// When pictures are shown
do {
    // a steady 30 pictures a second: shown a fixed short time after they arrive, evenly
    let p = DiscordPlayout()
    var targets: [Double] = []
    for i in 0..<60 { targets.append(p.schedule(timestamp: UInt32(i * 3000), arrival: 100 + Double(i) / 30)) }
    check(zip(targets.dropFirst(), targets).allSatisfy { abs(($0 - $1) - 1.0 / 30) < 0.0015 }, "a steady stream is shown evenly, 1/30 s apart")
    check(abs(targets[59] - (100 + 59.0 / 30) - 0.06) < 0.002 && p.late == 0, "with the shortest delay (60 ms) and nothing late (\(p.delay))")
}
do {
    // a stall: nothing for 200 ms, then eight pictures at once, then steady again
    let p = DiscordPlayout()
    var shownAt: [Double] = []
    var arrival = 100.0
    var n = 0
    func frame(at t: Double) { shownAt.append(p.schedule(timestamp: UInt32(n * 3000), arrival: t)); n += 1 }
    for _ in 0..<30 { frame(at: arrival); arrival += 1.0 / 30 }
    let beforeDelay = p.delay
    arrival += 0.2                                             // the stall: eight pictures that should have come in the last 200 ms
    for _ in 0..<8 { frame(at: arrival) }
    arrival += 0.001
    check(p.delay > beforeDelay + 0.1, "after a stall the added delay grows (\(Int(beforeDelay * 1000)) ms -> \(Int(p.delay * 1000)) ms)")
    for _ in 0..<60 { arrival += 1.0 / 30; frame(at: arrival) }
    let burst = Array(shownAt[30..<38])
    let spread = burst.last! - burst.first!
    check(spread > 0.15 && zip(burst.dropFirst(), burst).allSatisfy { $0 > $1 }, "the burst comes out spread over time, in order (\(Int(spread * 1000)) ms for eight pictures, not all at once)")
    check(zip(shownAt.dropFirst(), shownAt).allSatisfy { $0 > $1 }, "never out of order")
    check(p.delay < p.maxDelay + 0.001 && p.delay >= p.minDelay, "the delay stays inside its limits")
}
do {
    // the sender's clock wraps
    let p = DiscordPlayout()
    var last = 0.0
    var ok = true
    for i in 0..<20 { let t = p.schedule(timestamp: UInt32(truncatingIfNeeded: 0xFFFF_F000 + i * 3000), arrival: 50 + Double(i) / 30); if t <= last { ok = false }; last = t }
    check(ok && abs(last - (50 + 19.0 / 30) - 0.06) < 0.003, "the 90 kHz clock wrapping around does not upset it")
}
do {
    // a long stall starts the timing again instead of showing pictures seconds late
    let p = DiscordPlayout()
    for i in 0..<30 { _ = p.schedule(timestamp: UInt32(i * 3000), arrival: 10 + Double(i) / 30) }
    let t = p.schedule(timestamp: UInt32(30 * 3000), arrival: 20)
    check(p.resyncs == 1 && t - 20 < 0.5, "after a ten second stall it starts again (\(String(format: "%.2f", t - 20)) s after arrival)")
}
// a picture's sample can be made for the layer's clock instead of at once
do {
    let s = DiscordH264Sampler()
    var unit = Data()
    for n in [Data([0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x05, 0x07, 0xE8, 0x40, 0, 0, 3, 0, 0x40, 0, 0, 0x0F, 3, 0xC5, 0x8B, 0xA8]), Data([0x68, 0xCE, 0x3C, 0x80]), Data([0x65, 0x88, 0x84, 0, 0x33])] { unit.append(contentsOf: [0, 0, 0, 1]); unit.append(n) }
    let later = s.sample(from: unit, at: CMTime(seconds: 5, preferredTimescale: 90000), immediately: false)
    var immediate = false
    if let later, let a = CMSampleBufferGetSampleAttachmentsArray(later, createIfNecessary: false), CFArrayGetCount(a) > 0 {
        let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFDictionary.self) as NSDictionary
        immediate = d[kCMSampleAttachmentKey_DisplayImmediately as String] != nil
    }
    check(later != nil && CMSampleBufferGetPresentationTimeStamp(later!).seconds == 5 && !immediate, "a sample for the layer's clock carries its time and is not marked to show at once")
}

// Steady pacing, from arrival times only
do {
    let p = DiscordSteadyPacer()
    var shown: [Double] = []
    var arrival = 10.0
    for _ in 0..<90 { shown.append(p.schedule(arrival: arrival)); arrival += 1.0 / 30 }
    check(zip(shown.dropFirst(), shown).allSatisfy { $0 > $1 } && abs((shown[89] - shown[60]) - 29.0 / 30) < 0.08, "a steady stream is shown at its own rhythm")
    check(shown[89] - (10 + 89.0 / 30) < 0.12 && shown[89] - (10 + 89.0 / 30) > 0.0, "with a small delay (\(Int((shown[89] - (10 + 89.0 / 30)) * 1000)) ms)")
}
do {
    // a 250 ms stall, then eight pictures at once, then steady
    let p = DiscordSteadyPacer()
    var shown: [Double] = [], arrivals: [Double] = []
    var arrival = 10.0
    for _ in 0..<60 { arrivals.append(arrival); shown.append(p.schedule(arrival: arrival)); arrival += 1.0 / 30 }
    arrival += 0.25
    for _ in 0..<8 { arrivals.append(arrival); shown.append(p.schedule(arrival: arrival)) }
    for _ in 0..<90 { arrival += 1.0 / 30; arrivals.append(arrival); shown.append(p.schedule(arrival: arrival)) }
    let burst = Array(shown[60..<68])
    let gaps = zip(burst.dropFirst(), burst).map { $0 - $1 }
    check(gaps.allSatisfy { $0 > 0.012 && $0 < 0.06 }, "the eight pictures that arrived together are shown 12 to 60 ms apart, none at once (\(gaps.map { Int($0 * 1000) }))")
    check(zip(shown.dropFirst(), shown).allSatisfy { $0 > $1 }, "never out of order")
    check(zip(shown, arrivals).map { $0 - $1 }.max()! < p.maxLag + 0.05, "the buffer never grows beyond its limit (\(Int(p.worstBacklog * 1000)) ms)")
    check(shown.last! - arrivals.last! < 0.15, "and the delay is shrinking back three seconds later (\(Int((shown.last! - arrivals.last!) * 1000)) ms)")
    // the same stall again: now there is enough in hand to hide it
    let q = DiscordSteadyPacer()
    var t = 10.0
    var out: [Double] = []
    for _ in 0..<60 { out.append(q.schedule(arrival: t)); t += 1.0 / 30 }
    t += 0.2; out.append(q.schedule(arrival: t))                      // first stall (200 ms): seen
    for _ in 0..<150 { t += 1.0 / 30; out.append(q.schedule(arrival: t)) }
    let before = out.count
    t += 0.15                                                          // second stall (150 ms)
    for _ in 0..<5 { out.append(q.schedule(arrival: t)); t += 1.0 / 30 }
    let longest = zip(out[(before - 2)...].dropFirst(), out[(before - 2)...]).map { $0 - $1 }.max()!
    check(longest < 0.075, "a second, shorter stall is hidden by the picture in hand (longest gap on screen \(Int(longest * 1000)) ms)")
}
do {
    // pictures arriving faster than they were shown for a long time: it catches up
    let p = DiscordSteadyPacer()
    var arrival = 10.0
    var last = 0.0
    for i in 0..<200 { last = p.schedule(arrival: arrival); arrival += i < 100 ? 1.0 / 30 : 1.0 / 60 }
    check(last - (arrival - 1.0 / 60) <= p.maxLag + 0.05, "a stream that speeds up does not build a growing delay")
}
check(DiscordPacing.allCases.count == 3 && DiscordPacing.steady.next == .senderClock && DiscordPacing.instant.next == .steady, "the three pacing modes cycle")

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -O -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/DiscordWatch.swift" 2>&1 | grep -v "^$" | head -30 || true
"$OUT/t"
