// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Whether a program is built on the .NET Framework. Such a program (Celeste, Stardew Valley's launcher, many indie games) cannot start without Wine Mono, the open-source
/// .NET runtime Wine uses: Wine says "Wine Mono is not installed" and the program ends at once. Porthole asks for the download before the game starts instead.
enum DotNetCheck {
    /// The program's PE header names a CLR header (data directory 14, "COM descriptor"), which every managed program has.
    static func isManaged(header data: Data) -> Bool {
        func u16(_ o: Int) -> UInt64? { o >= 0 && o + 2 <= data.count ? UInt64(data[data.startIndex + o]) | UInt64(data[data.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt64? { guard let a = u16(o), let b = u16(o + 2) else { return nil }; return a | b << 16 }
        guard u16(0) == 0x5A4D, let peOffset = u32(0x3C).map(Int.init), peOffset > 0, peOffset < 4096, u32(peOffset) == 0x0000_4550 else { return false }
        guard let sizeOfOptional = u16(peOffset + 20), sizeOfOptional >= 96 else { return false }
        let opt = peOffset + 24
        guard let magic = u16(opt), magic == 0x20B || magic == 0x10B else { return false }
        let directories = magic == 0x20B ? opt + 112 : opt + 96
        guard let count = u32(directories - 4), count > 14 else { return false }
        return (u32(directories + 14 * 8) ?? 0) != 0 && (u32(directories + 14 * 8 + 4) ?? 0) != 0
    }

    static func isManaged(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return false }
        return isManaged(header: data)
    }
}

extension WineMonoModel {
    /// How far the current download or unpacking has got, 0 to 1 (the unpacking counts as the second half).
    var progressFraction: Double {
        switch phase {
        case .idle: 0
        case .downloading(let f): f * 0.5
        case .installing(let f): 0.5 + f * 0.5
        }
    }
}
