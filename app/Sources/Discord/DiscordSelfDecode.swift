// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreMedia
import Foundation
import VideoToolbox

/// Diagnostic for Go Live: decodes the first pictures this phone sends (as they leave the encoder, before encryption) with the phone's own decoder and reports their size and
/// average brightness. If these are not black, a black picture on the viewer's side is the viewer's or the transport's doing, not the encoder's.
final class DiscordSelfDecode: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: (sps: Data, pps: Data)?
    private var decoded = 0
    /// Called with one line of the report.
    var report: ((String) -> Void)?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// One access unit in Annex B form (what goes to the packetizer, before encryption).
    func feed(_ unit: Data, isKey: Bool, number: Int) {
        let nals = DiscordAnnexB.nalUnits(unit)
        if let sps = nals.first(where: { $0.first.map { $0 & 0x1F == 7 } == true }), let pps = nals.first(where: { $0.first.map { $0 & 0x1F == 8 } == true }) {
            if parameterSets?.sps != sps || parameterSets?.pps != pps { parameterSets = (sps, pps); rebuild() }
        }
        guard let session, let format else { report?("self-decode \(number): no parameter sets yet, cannot decode"); return }
        // AVCC: 4-byte length in front of each picture NAL unit (parameter sets are in the format description).
        var avcc = Data()
        for nal in nals where nal.first.map({ let t = $0 & 0x1F; return t != 7 && t != 8 }) == true {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4)); avcc.append(nal)
        }
        guard !avcc.isEmpty else { report?("self-decode \(number): no picture data in the unit"); return }
        var block: CMBlockBuffer?
        let bytes = avcc
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }) == kCMBlockBufferNoErr else {
            report?("self-decode \(number): could not wrap the picture"); return
        }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(number), timescale: 30), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { report?("self-decode \(number): could not build the sample"); return }
        let kind = isKey ? "key" : "delta"
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else { self.report?("self-decode \(number): \(kind) picture did not decode (status \(status))"); return }
            self.report?("self-decode \(number): \(kind) picture decodes to \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)), \(Self.brightness(image))")
        }
        if status != noErr { report?("self-decode \(number): decoder refused the \(kind) picture (status \(status))") }
    }

    private func rebuild() {
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        guard let (sps, pps) = parameterSets else { return }
        var made: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p -> OSStatus in
            let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                       nalUnitHeaderLength: 4, formatDescriptionOut: &made)
        } }
        guard status == noErr, let made else { report?("self-decode: the parameter sets (SPS \(sps.count) bytes, PPS \(pps.count)) were refused (status \(status))"); return }
        format = made
        var created: VTDecompressionSession?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        let code = VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                                outputCallback: nil, decompressionSessionOut: &created)
        if code != noErr { report?("self-decode: the decoder could not start (status \(code))"); return }
        session = created
    }

    /// Mean brightness of a sample of the picture and how much of it is not near black, as text.
    private static func brightness(_ image: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return "no pixels" }
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0, lit = 0, count = 0
        for y in Swift.stride(from: 0, to: h, by: 16) {
            for x in Swift.stride(from: 0, to: w, by: 16) {
                let p = bytes + y * stride + x * 4      // BGRA
                let luma = (Int(p[0]) + Int(p[1]) * 2 + Int(p[2]) * 1) / 4
                total += luma; count += 1
                if luma > 24 { lit += 1 }
            }
        }
        guard count > 0 else { return "no pixels" }
        return "mean brightness \(total / count)/255, \(lit * 100 / count)% of the sampled points are not near black"
    }
}
