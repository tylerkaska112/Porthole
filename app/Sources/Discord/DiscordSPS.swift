// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Rewrites an H.264 sequence parameter set (SPS) so that its VUI says "no frame reordering, a decoded picture buffer as small as the reference frames need". The phone's hardware
/// encoder writes an SPS without that, and a decoder that finds none has to assume it may hold back as many pictures as the level allows, so it shows nothing for a while or
/// asks for key frames. This is what WebRTC's own SpsVuiRewriter does on the receiving side (webrtc/common_video/h264/sps_vui_rewriter.cc); Discord's own streaming clients do it
/// before sending. Everything is read and written bit by bit following the H.264 specification (7.3.2.1.1 and Annex E); the colour description in the VUI is dropped, as WebRTC does.
enum DiscordSPS {
    /// `nal` is one SPS NAL unit, with its header byte and without a start code. Nil when it cannot be read (the caller then sends it as it is).
    /// `colour`: also write a colour description (BT.709, limited range) into the VUI, so that a viewer's renderer that reads the colour attributes of decoded pictures has them.
    static func rewriteVUI(_ nal: Data, colour: Bool = false) -> Data? {
        guard nal.count > 4, nal[nal.startIndex] & 0x1F == 7 else { return nil }
        let header = nal[nal.startIndex]
        var reader = BitReader(rbsp: unescape([UInt8](nal.dropFirst())))
        var writer = BitWriter()
        do {
            writer.bits(8, UInt64(try reader.bits(8)))                      // profile_idc
            let profile = Int(writer.lastByte)
            writer.bits(8, UInt64(try reader.bits(8)))                      // constraint flags and reserved bits
            writer.bits(8, UInt64(try reader.bits(8)))                      // level_idc
            writer.ue(try reader.ue())                                      // seq_parameter_set_id
            if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
                let chroma = try reader.ue(); writer.ue(chroma)
                if chroma == 3 { writer.bits(1, UInt64(try reader.bits(1))) }
                writer.ue(try reader.ue()); writer.ue(try reader.ue())      // bit depths
                writer.bits(1, UInt64(try reader.bits(1)))                  // qpprime_y_zero_transform_bypass_flag
                let matrix = try reader.bits(1); writer.bits(1, UInt64(matrix))
                if matrix == 1 {
                    for i in 0..<(chroma != 3 ? 8 : 12) {
                        let present = try reader.bits(1); writer.bits(1, UInt64(present))
                        if present == 1 {
                            var last = 8, next = 8
                            for _ in 0..<(i < 6 ? 16 : 64) {
                                let delta = try reader.se(); writer.se(delta)
                                next = (last + delta + 256) % 256
                                if next != 0 { last = next }
                            }
                        }
                    }
                }
            }
            writer.ue(try reader.ue())                                      // log2_max_frame_num_minus4
            let pocType = try reader.ue(); writer.ue(pocType)
            if pocType == 0 {
                writer.ue(try reader.ue())                                  // log2_max_pic_order_cnt_lsb_minus4
            } else if pocType == 1 {
                writer.bits(1, UInt64(try reader.bits(1)))                  // delta_pic_order_always_zero_flag
                writer.se(try reader.se()); writer.se(try reader.se())      // offset_for_non_ref_pic, offset_for_top_to_bottom_field
                let cycle = try reader.ue(); writer.ue(cycle)
                guard cycle <= 255 else { return nil }
                for _ in 0..<cycle { writer.se(try reader.se()) }
            }
            let maxRefFrames = try reader.ue(); writer.ue(maxRefFrames)
            writer.bits(1, UInt64(try reader.bits(1)))                      // gaps_in_frame_num_value_allowed_flag
            writer.ue(try reader.ue()); writer.ue(try reader.ue())          // pic_width_in_mbs_minus1, pic_height_in_map_units_minus1
            let frameMbsOnly = try reader.bits(1); writer.bits(1, UInt64(frameMbsOnly))
            if frameMbsOnly == 0 { writer.bits(1, UInt64(try reader.bits(1))) }   // mb_adaptive_frame_field_flag
            writer.bits(1, UInt64(try reader.bits(1)))                      // direct_8x8_inference_flag
            let cropping = try reader.bits(1); writer.bits(1, UInt64(cropping))
            if cropping == 1 { for _ in 0..<4 { writer.ue(try reader.ue()) } }

            func writeColour() {
                guard colour else { writer.bits(1, 0); return }
                writer.bits(1, 1)                                           // video_signal_type_present_flag
                writer.bits(3, 5)                                           // video_format: unspecified
                writer.bits(1, 0)                                           // video_full_range_flag: limited range
                writer.bits(1, 1)                                           // colour_description_present_flag
                writer.bits(8, 1); writer.bits(8, 1); writer.bits(8, 1)     // colour_primaries, transfer_characteristics, matrix_coefficients: BT.709
            }

            func bitstreamRestriction() {
                writer.bits(1, 1)                                           // motion_vectors_over_pic_boundaries_flag
                writer.ue(2); writer.ue(1)                                  // max_bytes_per_pic_denom, max_bits_per_mb_denom (their defaults)
                writer.ue(16); writer.ue(16)                                // log2_max_mv_length_horizontal / vertical (their defaults)
                writer.ue(0)                                                // max_num_reorder_frames: none, this is the point
                writer.ue(maxRefFrames)                                     // max_dec_frame_buffering
            }

            let vuiPresent = try reader.bits(1)
            writer.bits(1, 1)                                               // the rewritten SPS always has a VUI
            if vuiPresent == 0 {
                writer.bits(2, 0)                                           // aspect_ratio_info_present_flag, overscan_info_present_flag
                writeColour()                                               // video_signal_type_present_flag (and the description when asked for)
                writer.bits(5, 0)                                           // chroma_loc_info, timing_info, nal_hrd, vcl_hrd, pic_struct_present_flag
                writer.bits(1, 1)                                           // bitstream_restriction_flag
                bitstreamRestriction()
            } else {
                let aspect = try reader.bits(1); writer.bits(1, UInt64(aspect))
                if aspect == 1 {
                    let idc = try reader.bits(8); writer.bits(8, UInt64(idc))
                    if idc == 255 { writer.bits(16, UInt64(try reader.bits(16))); writer.bits(16, UInt64(try reader.bits(16))) }
                }
                let overscan = try reader.bits(1); writer.bits(1, UInt64(overscan))
                if overscan == 1 { writer.bits(1, UInt64(try reader.bits(1))) }
                let signal = try reader.bits(1); writeColour()              // the colour description is read and dropped (or replaced by BT.709 when asked for)
                if signal == 1 {
                    _ = try reader.bits(3); _ = try reader.bits(1)
                    if try reader.bits(1) == 1 { _ = try reader.bits(8); _ = try reader.bits(8); _ = try reader.bits(8) }
                }
                let chromaLoc = try reader.bits(1); writer.bits(1, UInt64(chromaLoc))
                if chromaLoc == 1 { writer.ue(try reader.ue()); writer.ue(try reader.ue()) }
                let timing = try reader.bits(1); writer.bits(1, UInt64(timing))
                if timing == 1 {
                    writer.bits(32, UInt64(try reader.bits(32))); writer.bits(32, UInt64(try reader.bits(32)))
                    writer.bits(1, UInt64(try reader.bits(1)))              // fixed_frame_rate_flag
                }
                func hrd() throws {
                    let count = try reader.ue(); writer.ue(count)
                    guard count < 32 else { throw ParseError.invalid }
                    writer.bits(4, UInt64(try reader.bits(4))); writer.bits(4, UInt64(try reader.bits(4)))   // bit_rate_scale, cpb_size_scale
                    for _ in 0...count { writer.ue(try reader.ue()); writer.ue(try reader.ue()); writer.bits(1, UInt64(try reader.bits(1))) }
                    for _ in 0..<4 { writer.bits(5, UInt64(try reader.bits(5))) }
                }
                let nalHrd = try reader.bits(1); writer.bits(1, UInt64(nalHrd))
                if nalHrd == 1 { try hrd() }
                let vclHrd = try reader.bits(1); writer.bits(1, UInt64(vclHrd))
                if vclHrd == 1 { try hrd() }
                if nalHrd == 1 || vclHrd == 1 { writer.bits(1, UInt64(try reader.bits(1))) }   // low_delay_hrd_flag
                writer.bits(1, UInt64(try reader.bits(1)))                  // pic_struct_present_flag
                let restriction = try reader.bits(1); writer.bits(1, 1)
                if restriction == 0 {
                    bitstreamRestriction()
                } else {
                    writer.bits(1, UInt64(try reader.bits(1)))              // motion_vectors_over_pic_boundaries_flag
                    for _ in 0..<4 { writer.ue(try reader.ue()) }           // max_bytes_per_pic_denom, max_bits_per_mb_denom, log2_max_mv_length_*
                    _ = try reader.ue(); writer.ue(0)                       // max_num_reorder_frames -> 0
                    _ = try reader.ue(); writer.ue(maxRefFrames)            // max_dec_frame_buffering
                }
            }
            writer.bits(1, 1)                                               // rbsp_stop_one_bit
        } catch { return nil }
        return Data([header]) + Data(escape(writer.finish()))
    }

    private enum ParseError: Error { case invalid, short }

    /// Removes emulation prevention bytes (00 00 03 -> 00 00).
    private static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Adds emulation prevention bytes where 00 00 would be followed by 00, 01, 02 or 03.
    private static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(bytes.count + 8)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b <= 3 { out.append(3); zeros = 0 }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitReader {
        let rbsp: [UInt8]
        var position = 0
        init(rbsp: [UInt8]) { self.rbsp = rbsp }
        mutating func bits(_ n: Int) throws -> Int {
            guard n <= 32, position + n <= rbsp.count * 8 else { throw ParseError.short }
            var value = 0
            for _ in 0..<n {
                value = value << 1 | Int(rbsp[position >> 3] >> (7 - UInt8(position & 7)) & 1)
                position += 1
            }
            return value
        }
        mutating func ue() throws -> Int {
            var zeros = 0
            while try bits(1) == 0 { zeros += 1; if zeros > 31 { throw ParseError.invalid } }
            return zeros == 0 ? 0 : (1 << zeros) - 1 + (try bits(zeros))
        }
        mutating func se() throws -> Int {
            let k = try ue()
            return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }

    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var current: UInt8 = 0
        private var count = 0
        var lastByte: UInt8 { bytes.last ?? 0 }
        mutating func bits(_ n: Int, _ value: UInt64) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                current = current << 1 | UInt8(value >> UInt64(i) & 1)
                count += 1
                if count == 8 { bytes.append(current); current = 0; count = 0 }
            }
        }
        mutating func ue(_ v: Int) {
            let x = UInt64(v + 1)
            let length = 64 - x.leadingZeroBitCount
            bits(length - 1, 0)
            bits(length, x)
        }
        mutating func se(_ v: Int) { ue(v > 0 ? 2 * v - 1 : -2 * v) }
        /// The bytes so far, the last one padded with zero bits.
        mutating func finish() -> [UInt8] {
            if count > 0 { bytes.append(current << UInt8(8 - count)); current = 0; count = 0 }
            return bytes
        }
    }
}
