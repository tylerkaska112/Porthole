// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// The wire formats Steam's servers speak, written from the public protocol descriptions: protobuf, Steam's message
// framing, and the compression and encryption used for game content. Foundation and CommonCrypto only, so it is
// unit-testable on the Mac.
import Foundation
import CommonCrypto
import Compression

// MARK: - Protobuf (only what Steam's messages need)

struct PBWriter {
    private(set) var data = Data()

    private mutating func key(_ field: Int, _ wire: Int) { rawVarint(UInt64(field << 3 | wire)) }
    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func varint(_ field: Int, _ value: UInt64) { key(field, 0); rawVarint(value) }
    mutating func int32(_ field: Int, _ value: Int32) { varint(field, UInt64(bitPattern: Int64(value))) }
    mutating func bool(_ field: Int, _ value: Bool) { varint(field, value ? 1 : 0) }
    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, 1); for i in 0..<8 { data.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
    }
    mutating func bytes(_ field: Int, _ value: Data) { key(field, 2); rawVarint(UInt64(value.count)); data.append(value) }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ value: PBWriter) { bytes(field, value.data) }
}

enum PBValue { case varint(UInt64), fixed64(UInt64), fixed32(UInt32), bytes(Data) }

/// A decoded message: every field number with the values seen for it (repeated fields have several).
struct PBFields {
    private(set) var values: [Int: [PBValue]] = [:]

    init() {}
    init?(_ data: Data) {
        var bytes = Array(data)[...]
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while let b = bytes.first {
                bytes = bytes.dropFirst()
                if shift >= 64 { return nil }
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while !bytes.isEmpty {
            guard let tag = varint() else { return nil }
            let field = Int(tag >> 3)
            guard field > 0 else { return nil }
            switch tag & 7 {
            case 0: guard let v = varint() else { return nil }; values[field, default: []].append(.varint(v))
            case 1:
                guard bytes.count >= 8 else { return nil }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[bytes.startIndex + i]) << (8 * UInt64(i)) }
                bytes = bytes.dropFirst(8); values[field, default: []].append(.fixed64(v))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count) else { return nil }
                let count = Int(length)
                values[field, default: []].append(.bytes(Data(bytes.prefix(count)))); bytes = bytes.dropFirst(count)
            case 5:
                guard bytes.count >= 4 else { return nil }
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(bytes[bytes.startIndex + i]) << (8 * UInt32(i)) }
                bytes = bytes.dropFirst(4); values[field, default: []].append(.fixed32(v))
            default: return nil                      // groups are not used by Steam's messages
            }
        }
    }

    func uint(_ field: Int) -> UInt64? {
        switch values[field]?.last { case .varint(let v)?: return v; case .fixed64(let v)?: return v; case .fixed32(let v)?: return UInt64(v); default: return nil }
    }
    func int(_ field: Int) -> Int? { uint(field).map { Int(Int32(truncatingIfNeeded: $0)) } }
    func bool(_ field: Int) -> Bool? { uint(field).map { $0 != 0 } }
    func data(_ field: Int) -> Data? { if case .bytes(let d)? = values[field]?.last { return d }; return nil }
    func string(_ field: Int) -> String? { data(field).flatMap { String(data: $0, encoding: .utf8) } }
    func allUInts(_ field: Int) -> [UInt64] { (values[field] ?? []).compactMap { if case .varint(let v) = $0 { return v } else { return nil } } }
    func messages(_ field: Int) -> [PBFields] { (values[field] ?? []).compactMap { if case .bytes(let d) = $0 { return PBFields(d) } else { return nil } } }
}

// MARK: - Steam's message framing

/// SteamIDs pack (universe, account type, instance, account number) into 64 bits.
enum SteamIDs {
    static func make(account: UInt32, instance: UInt32, type: UInt64, universe: UInt64 = 1) -> UInt64 {
        universe << 56 | type << 52 | UInt64(instance & 0xFFFFF) << 32 | UInt64(account)
    }
    static let individual: UInt64 = 1, anonUser: UInt64 = 10
    static func anonymous() -> UInt64 { make(account: 0, instance: 0, type: anonUser) }
    static func user(account: UInt32) -> UInt64 { make(account: account, instance: 1, type: individual) }
    static func account(of steamID: UInt64) -> UInt32 { UInt32(steamID & 0xFFFFFFFF) }
}

enum EMsg {
    static let multi = 1, serviceMethodResponse = 147, serviceMethodCall = 151, heartBeat = 703, logOff = 706
    static let logOnResponse = 751, licenseList = 780, getDepotDecryptionKey = 5438, getDepotDecryptionKeyResponse = 5439, checkAppBetaPassword = 5450, checkAppBetaPasswordResponse = 5451
    static let getUserStats = 818, getUserStatsResponse = 819
    static let enumerateSubscribedFiles = 7378, enumerateSubscribedFilesResponse = 7379
    static let logOn = 5514, picsProductInfoRequest = 8903, picsProductInfoResponse = 8904
    static let picsAccessTokenRequest = 8905, picsAccessTokenResponse = 8906
}

struct SteamPacket {
    var emsg: Int
    var steamID: UInt64 = 0
    var sessionID: Int32 = 0
    var jobSource: UInt64 = UInt64.max            // "no job" is all ones
    var jobTarget: UInt64 = UInt64.max
    var targetJobName: String?
    var eresult: Int?
    var errorMessage: String?
    var body = Data()

    /// A protobuf message from us: emsg with the protobuf flag, the header, then the body.
    func encoded() -> Data {
        var header = PBWriter()
        header.fixed64(1, steamID)
        header.int32(2, sessionID)
        if jobSource != UInt64.max { header.fixed64(10, jobSource) }
        if jobTarget != UInt64.max { header.fixed64(11, jobTarget) }
        if let targetJobName { header.string(12, targetJobName) }
        var out = Data()
        func put32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        put32(UInt32(emsg) | 0x8000_0000)
        put32(UInt32(header.data.count))
        out.append(header.data); out.append(body)
        return out
    }

    /// Reads one framed message (only protobuf ones; the old binary framing is not used by anything we call).
    static func decode(_ raw: Data) -> SteamPacket? {
        let bytes = Array(raw)
        guard bytes.count >= 8 else { return nil }
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        let tag = u32(0)
        guard tag & 0x8000_0000 != 0 else { return nil }
        let headerLength = Int(u32(4))
        guard headerLength >= 0, 8 + headerLength <= bytes.count, let header = PBFields(Data(bytes[8..<8 + headerLength])) else { return nil }
        var packet = SteamPacket(emsg: Int(tag & 0x7FFF_FFFF))
        packet.steamID = header.uint(1) ?? 0
        packet.sessionID = Int32(truncatingIfNeeded: header.int(2) ?? 0)
        packet.jobSource = header.uint(10) ?? UInt64.max
        packet.jobTarget = header.uint(11) ?? UInt64.max
        packet.targetJobName = header.string(12)
        packet.eresult = header.int(13)
        packet.errorMessage = header.string(14)
        packet.body = Data(bytes[(8 + headerLength)...])
        return packet
    }

    /// EMsg 1 wraps several messages, optionally gzip-compressed: body is { size_unzipped = 1, message_body = 2 }, and inside it each
    /// message is preceded by its 4-byte length.
    static func unpackMulti(_ body: Data) -> [SteamPacket]? {
        guard let fields = PBFields(body), var inner = fields.data(2) else { return nil }
        if let size = fields.uint(1), size > 0 {
            guard let unzipped = Deflate.gunzip(inner, expectedSize: Int(size)) else { return nil }
            inner = unzipped
        }
        let bytes = Array(inner)
        var packets: [SteamPacket] = [], at = 0
        while at + 4 <= bytes.count {
            let length = Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
            at += 4
            guard length >= 0, at + length <= bytes.count else { return nil }
            if let packet = decode(Data(bytes[at..<at + length])) { packets.append(packet) }
            at += length
        }
        return packets
    }
}

// MARK: - Deflate, gzip and zip

enum Deflate {
    /// Raw DEFLATE (RFC 1951) to bytes. The output size must be known.
    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        guard expectedSize > 0, expectedSize < 1 << 30 else { return nil }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? out : nil
    }

    static func gunzip(_ data: Data, expectedSize: Int) -> Data? {
        let b = Array(data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var at = 10
        if flags & 4 != 0 { guard at + 2 <= b.count else { return nil }; at += 2 + Int(b[at]) + Int(b[at + 1]) << 8 }
        if flags & 8 != 0 { while at < b.count, b[at] != 0 { at += 1 }; at += 1 }
        if flags & 16 != 0 { while at < b.count, b[at] != 0 { at += 1 }; at += 1 }
        if flags & 2 != 0 { at += 2 }
        guard at < b.count - 8 else { return nil }
        return inflate(Data(b[at..<b.count - 8]), expectedSize: expectedSize)
    }

    /// The first file of a zip archive. Steam wraps manifests and some chunks in a zip with one entry.
    static func unzipFirstEntry(_ data: Data) -> Data? {
        let b = Array(data)
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        // The central directory has the real sizes even when the local header defers them to a data descriptor.
        guard b.count >= 22 else { return nil }
        var end = b.count - 22
        while end >= 0, !(b[end] == 0x50 && b[end + 1] == 0x4B && b[end + 2] == 5 && b[end + 3] == 6) { end -= 1; if b.count - end > 66_000 { return nil } }
        guard end >= 0, u16(end + 10) >= 1 else { return nil }
        let central = u32(end + 16)
        guard central + 46 <= b.count, u32(central) == 0x02014B50 else { return nil }
        let method = u16(central + 10), compressed = u32(central + 20), original = u32(central + 24), localAt = u32(central + 42)
        guard localAt + 30 <= b.count, u32(localAt) == 0x04034B50 else { return nil }
        let start = localAt + 30 + u16(localAt + 26) + u16(localAt + 28)
        guard start + compressed <= b.count else { return nil }
        let payload = Data(b[start..<start + compressed])
        switch method {
        case 0: return payload.count == original ? payload : nil
        case 8: return inflate(payload, expectedSize: original)
        default: return nil
        }
    }
}

// MARK: - LZMA (Steam's "VZip" chunks)

enum LZMA {
    /// LZMA with the 5 properties bytes given separately and the output size known: the same stream 7-Zip's LZMA SDK decodes.
    static func decode(properties: [UInt8], input: [UInt8], start: Int, outputSize: Int) -> [UInt8]? {
        guard properties.count >= 5, outputSize >= 0, outputSize < 1 << 30 else { return nil }
        var d = properties[0]
        guard d < 9 * 5 * 5 else { return nil }
        let lc = Int(d % 9); d /= 9
        let lp = Int(d % 5), pb = Int(d / 5)
        var dictSize = Int(properties[1]) | Int(properties[2]) << 8 | Int(properties[3]) << 16 | Int(properties[4]) << 24
        if dictSize < 4096 { dictSize = 4096 }
        _ = dictSize                                                 // the output buffer is the window: the whole result is kept in memory
        var out = [UInt8](repeating: 0, count: outputSize)
        var outPos = 0
        var pos = start
        guard input.count - start >= 5 else { return nil }
        var range: UInt32 = 0xFFFF_FFFF, code: UInt32 = 0
        guard input[pos] == 0 else { return nil }
        for i in 1...4 { code = code << 8 | UInt32(input[pos + i]) }
        pos += 5
        let kTop: UInt32 = 1 << 24
        let literalSize = 0x300 << (lc + lp)
        var probs = [UInt16](repeating: 1024, count: 1846 + literalSize)
        // Offsets in the probability array.
        let isMatch = 0, isRep = 192, isRepG0 = 204, isRepG1 = 216, isRepG2 = 228, isRep0Long = 240
        let posSlot = 432, specPos = 688, align = 802, lenCoder = 818, repLenCoder = 1332, literal = 1846
        var failed = false

        @inline(__always) func normalize() {
            if range < kTop {
                if pos >= input.count { failed = true; return }
                range <<= 8; code = code << 8 | UInt32(input[pos]); pos += 1
            }
        }
        @inline(__always) func decodeBit(_ index: Int) -> Int {
            normalize()
            let p = UInt32(probs[index])
            let bound = (range >> 11) &* p
            if code < bound { range = bound; probs[index] = UInt16(p + ((2048 - p) >> 5)); return 0 }
            range &-= bound; code &-= bound; probs[index] = UInt16(p - (p >> 5)); return 1
        }
        func bitTree(_ base: Int, _ bits: Int) -> Int {
            var m = 1
            for _ in 0..<bits { m = m << 1 | decodeBit(base + m) }
            return m - (1 << bits)
        }
        func reverseBitTree(_ base: Int, _ bits: Int) -> Int {
            var m = 1, symbol = 0
            for i in 0..<bits { let bit = decodeBit(base + m); m = m << 1 | bit; symbol |= bit << i }
            return symbol
        }
        func directBits(_ count: Int) -> Int {
            var result = 0
            for _ in 0..<count {
                normalize()
                range >>= 1
                code &-= range
                let t = 0 &- (code >> 31)                       // all ones when code went "negative"
                code &+= range & t
                result = result << 1 | Int(t &+ 1)
            }
            return result
        }
        // Length coder layout: choice, choice2, low[16 * 8], mid[16 * 8], high[256]
        func decodeLength(_ base: Int, _ posState: Int) -> Int {
            if decodeBit(base) == 0 { return bitTree(base + 2 + (posState << 3), 3) }
            if decodeBit(base + 1) == 0 { return 8 + bitTree(base + 2 + 128 + (posState << 3), 3) }
            return 16 + bitTree(base + 2 + 256, 8)
        }

        var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
        var state = 0
        let pbMask = (1 << pb) - 1, lpMask = (1 << lp) - 1
        while outPos < outputSize {
            if failed { return nil }
            let posState = outPos & pbMask
            if decodeBit(isMatch + (state << 4) + posState) == 0 {
                let prev = outPos > 0 ? Int(out[outPos - 1]) : 0
                let base = literal + 0x300 * (((outPos & lpMask) << lc) + (prev >> (8 - lc)))
                var symbol = 1
                if state >= 7 {
                    var matchByte = Int(out[outPos - rep0 - 1])
                    repeat {
                        let matchBit = (matchByte >> 7) & 1; matchByte <<= 1
                        let bit = decodeBit(base + ((1 + matchBit) << 8) + symbol)
                        symbol = symbol << 1 | bit
                        if matchBit != bit { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 { symbol = symbol << 1 | decodeBit(base + symbol) }
                out[outPos] = UInt8(symbol & 0xFF); outPos += 1
                state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6
                continue
            }
            var length: Int
            if decodeBit(isRep + state) != 0 {
                if outPos == 0 { return nil }
                if decodeBit(isRepG0 + state) == 0 {
                    if decodeBit(isRep0Long + (state << 4) + posState) == 0 {
                        state = state < 7 ? 9 : 11
                        out[outPos] = out[outPos - rep0 - 1]; outPos += 1
                        continue
                    }
                } else {
                    var distance: Int
                    if decodeBit(isRepG1 + state) == 0 { distance = rep1 }
                    else {
                        if decodeBit(isRepG2 + state) == 0 { distance = rep2 } else { distance = rep3; rep3 = rep2 }
                        rep2 = rep1
                    }
                    rep1 = rep0; rep0 = distance
                }
                length = decodeLength(repLenCoder, posState)
                state = state < 7 ? 8 : 11
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                length = decodeLength(lenCoder, posState)
                state = state < 7 ? 7 : 10
                let slotBase = posSlot + (min(length, 3) << 6)
                let slot = bitTree(slotBase, 6)
                if slot < 4 { rep0 = slot }
                else {
                    let bits = (slot >> 1) - 1
                    rep0 = (2 | (slot & 1)) << bits
                    if slot < 14 { rep0 += reverseBitTree(specPos + rep0 - slot, bits) }
                    else {
                        rep0 += directBits(bits - 4) << 4
                        rep0 += reverseBitTree(align, 4)
                    }
                    if rep0 == 0xFFFF_FFFF { break }                       // end marker
                }
                if rep0 >= outPos { return nil }
            }
            length += 2
            if rep0 >= outPos { return nil }
            var copy = min(length, outputSize - outPos)
            var from = outPos - rep0 - 1
            while copy > 0 { out[outPos] = out[from]; outPos += 1; from += 1; copy -= 1 }
        }
        return failed || outPos != outputSize ? nil : out
    }
}

// MARK: - Content decryption and unpacking

enum SteamCipher {
    /// Steam's symmetric scheme: the first 16 bytes are the IV, encrypted (AES-256-ECB) with the key; the rest is AES-256-CBC with PKCS#7 padding.
    static func decrypt(_ input: Data, key: Data) -> Data? {
        guard key.count == 32, input.count >= 32, (input.count - 16) % 16 == 0 else { return nil }
        guard let iv = crypt(op: CCOperation(kCCDecrypt), mode: CCMode(kCCModeECB), key: key, iv: nil, data: input.prefix(16), padding: CCPadding(ccNoPadding)) else { return nil }
        return crypt(op: CCOperation(kCCDecrypt), mode: CCMode(kCCModeCBC), key: key, iv: iv, data: input.dropFirst(16), padding: CCPadding(ccPKCS7Padding))
    }

    /// The reverse (used by the tests to build content like Steam's servers hold it).
    static func encrypt(_ plain: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 32, iv.count == 16,
              let head = crypt(op: CCOperation(kCCEncrypt), mode: CCMode(kCCModeECB), key: key, iv: nil, data: iv, padding: CCPadding(ccNoPadding)),
              let body = crypt(op: CCOperation(kCCEncrypt), mode: CCMode(kCCModeCBC), key: key, iv: iv, data: plain, padding: CCPadding(ccPKCS7Padding)) else { return nil }
        return head + body
    }

    /// AES-256 in ECB mode with no padding, for input that is a whole number of 16-byte blocks (used for password-branch manifest ids).
    static func decryptECB(_ input: Data, key: Data) -> Data? {
        guard key.count == 32, !input.isEmpty, input.count % 16 == 0 else { return nil }
        return crypt(op: CCOperation(kCCDecrypt), mode: CCMode(kCCModeECB), key: key, iv: nil, data: input, padding: CCPadding(ccNoPadding))
    }
    static func encryptECB(_ input: Data, key: Data) -> Data? {
        guard key.count == 32, !input.isEmpty, input.count % 16 == 0 else { return nil }
        return crypt(op: CCOperation(kCCEncrypt), mode: CCMode(kCCModeECB), key: key, iv: nil, data: input, padding: CCPadding(ccNoPadding))
    }

    private static func crypt(op: CCOperation, mode: CCMode, key: Data, iv: Data?, data: Data, padding: CCPadding) -> Data? {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in
            (iv ?? Data()).withUnsafeBytes { v in
                CCCryptorCreateWithMode(op, mode, CCAlgorithm(kCCAlgorithmAES), padding, iv == nil ? nil : v.baseAddress, k.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: CCCryptorGetOutputLength(cryptor, data.count, true))
        var moved = 0, final = 0
        let status = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src -> CCCryptorStatus in
                var produced = 0
                var status = CCCryptorUpdate(cryptor, src.baseAddress, data.count, dst.baseAddress, dst.count, &produced)
                if status == kCCSuccess {
                    moved = produced
                    status = CCCryptorFinal(cryptor, dst.baseAddress?.advanced(by: produced), dst.count - produced, &final)
                }
                return status
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange((moved + final)...)
        return out
    }

    static func sha1(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    /// Adler-32 as Steam uses it for chunk checksums: it starts from 0, not from 1 as zlib does.
    static func adler32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var a = seed & 0xFFFF, b = seed >> 16
        data.withUnsafeBytes { raw in
            var index = 0
            let bytes = raw.bindMemory(to: UInt8.self)
            while index < bytes.count {
                let end = min(index + 5552, bytes.count)
                while index < end { a &+= UInt32(bytes[index]); b &+= a; index += 1 }
                a %= 65521; b %= 65521
            }
        }
        return b << 16 | a
    }

    /// What a downloaded chunk turns into: decrypt, then undo VZip (LZMA) or zip compression. Nil if it does not decode.
    static func unpackChunk(_ encrypted: Data, key: Data, originalSize: Int) -> Data? {
        guard let plain = decrypt(encrypted, key: key) else { return nil }
        let b = Array(plain)
        if b.count > 4, b[0] == 0x50, b[1] == 0x4B, b[2] == 3, b[3] == 4 { return Deflate.unzipFirstEntry(plain) }
        // VZstd: "VSZa", crc(4), one Zstandard frame, then a 15-byte footer: crc(4), size(8, little endian), "zsv".
        if b.count > 8 + 15, b[0] == 0x56, b[1] == 0x53, b[2] == 0x5A, b[3] == 0x61 {
            guard b[b.count - 3] == 0x7A, b[b.count - 2] == 0x73, b[b.count - 1] == 0x76 else { return nil }
            var size = 0
            for i in 0..<4 { size |= Int(b[b.count - 11 + i]) << (8 * i) }
            guard b[b.count - 7] == 0, b[b.count - 6] == 0, b[b.count - 5] == 0, b[b.count - 4] == 0,
                  size == originalSize || originalSize == 0 else { return nil }
            guard let out = Zstd.decompress(b, from: 8, to: b.count - 15, expectedSize: size) else { return nil }
            return Data(out)
        }
        // VZip: "VZa", crc(4), 5 property bytes, LZMA data, then crc(4), size(4), "zv".
        guard b.count > 3 + 4 + 5 + 10, b[0] == 0x56, b[1] == 0x5A, b[2] == 0x61 else { return nil }
        let size = Int(b[b.count - 6]) | Int(b[b.count - 5]) << 8 | Int(b[b.count - 4]) << 16 | Int(b[b.count - 3]) << 24
        guard size == originalSize || originalSize == 0, b[b.count - 2] == 0x7A, b[b.count - 1] == 0x76 else { return nil }
        guard let out = LZMA.decode(properties: Array(b[7..<12]), input: b, start: 12, outputSize: size) else { return nil }
        return Data(out)
    }
}
