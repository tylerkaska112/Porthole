// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Reads the compiled shaders out of Lossless Scaling's `Lossless.dll` (in memory: the file itself is never written anywhere in the clear). Foundation only; app/Tests/Licence runs it.
///
/// The DLL keeps its Direct3D 11 compute shaders as resources of type RCDATA (10) with the ids 101-302, each one a DXBC blob. Which id is which stage of the frame generation, and how the
/// stages are chained, is worked out from lsfg-vk 1.0.0 (https://github.com/PancakeTAS/lsfg-vk, tag v1.0.0, MIT licence, copyright (c) 2025 lsfg-vk), whose `extract.cpp` lists
/// the ids. This file is Porthole's own PE reader; the ids are the only thing taken from there. Newer lsfg-vk versions are under a licence that forbids derivative works and are not used.
enum LosslessShaders {
    /// RCDATA, where the DLL keeps them.
    static let resourceType: UInt32 = 10

    /// Resource id -> the DXBC blob.
    static func extract(from dll: Data) -> [Int: Data] {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= dll.count ? Int(dll[dll.startIndex + o]) | Int(dll[dll.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= dll.count ? (0..<4).reduce(0) { $0 | Int(dll[dll.startIndex + o + $1]) << (8 * $1) } : nil }
        guard dll.count > 0x40, u16(0) == 0x5a4d, let pe = u32(0x3c), u32(pe) == 0x4550, let nsec = u16(pe + 6), let opt = u16(pe + 20) else { return [:] }
        // The sections: where each one is in the file and in memory.
        var secs: [(name: String, va: Int, size: Int, raw: Int)] = []
        for i in 0..<min(nsec, 96) {
            let o = pe + 24 + opt + i * 40
            guard let vs = u32(o + 8), let va = u32(o + 12), let rs = u32(o + 16), let rp = u32(o + 20) else { return [:] }
            let name = String(decoding: dll.subdata(in: (dll.startIndex + o)..<(dll.startIndex + o + 8)).prefix { $0 != 0 }, as: UTF8.self)
            secs.append((name, va, max(vs, rs), rp))
        }
        func fileOffset(_ rva: Int) -> Int? { secs.first { $0.va <= rva && rva < $0.va + $0.size }.map { $0.raw + (rva - $0.va) } }
        guard let rsrc = secs.first(where: { $0.name == ".rsrc" }) else { return [:] }
        let base = rsrc.raw
        func entries(_ dir: Int) -> [(id: Int, offset: Int)] {
            guard let named = u16(dir + 12), let ids = u16(dir + 14), named + ids < 4096 else { return [] }
            return (0..<(named + ids)).compactMap { i in
                guard let n = u32(dir + 16 + i * 8), let o = u32(dir + 20 + i * 8) else { return nil }
                return (n & 0x8000_0000 != 0 ? -1 : n, o)
            }
        }
        var out: [Int: Data] = [:]
        for type in entries(base) where type.id == Int(resourceType) && type.offset & 0x8000_0000 != 0 {
            for item in entries(base + (type.offset & 0x7fff_ffff)) where item.id >= 0 && item.offset & 0x8000_0000 != 0 {
                // One language per resource is all the DLL has; the first is taken.
                guard let lang = entries(base + (item.offset & 0x7fff_ffff)).first, lang.offset & 0x8000_0000 == 0,
                      let rva = u32(base + lang.offset), let size = u32(base + lang.offset + 4), size > 32, size < 16 << 20,
                      let off = fileOffset(rva), off + size <= dll.count else { continue }
                let blob = dll.subdata(in: (dll.startIndex + off)..<(dll.startIndex + off + size))
                if blob.prefix(4) == Data("DXBC".utf8) { out[item.id] = blob }
            }
        }
        return out
    }

    /// The shader ids frame generation (the "quality" layout) cannot run without.
    static let required: [Int] = [255, 256, 267, 268, 269, 270, 275, 276, 277, 278, 279, 257, 259, 260, 261, 262, 263, 264, 265, 266, 258, 271, 272, 273, 274, 290, 291, 292, 293, 298, 299, 300, 301, 302, 280, 282, 283, 284, 285, 286, 287, 288, 289, 281, 294, 295, 296, 297]

    /// The shaders as the file the engine reads inside the game: "LSFG", u32 version 1, u32 count, then (u32 id, u32 size, bytes) each, little-endian. nil when a needed shader is missing
    /// (a different version of the program).
    static func container(from dll: Data) -> Data? {
        let shaders = extract(from: dll)
        guard required.allSatisfy({ shaders[$0] != nil }) else { return nil }
        var out = Data("LSFG".utf8)
        func put(_ v: Int) { var le = UInt32(v).littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        put(1); put(shaders.count)
        for (id, blob) in shaders.sorted(by: { $0.key < $1.key }) { put(id); put(blob.count); out.append(blob) }
        return out
    }
}
