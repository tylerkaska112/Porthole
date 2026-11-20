// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Numbers the engine only writes to the game's log (the swap file, the memory split, the page-in rate), read back from the end of the log so the performance readout can
/// show them. The engine does not export them, and a read of the last ~100 KB once a second is cheap. Parsing is by hand: no formatter or regex library.
struct EngineStats: Equatable {
    var swapBackedMB: Int?      // memory currently held in the swap file ("file-backed now")
    var swapPeakMB: Int?
    var swapFileUsedMB: Int?    // how much of the swap file has been handed out
    var swapFileCapMB: Int?
    var swapRefused: Int?       // requests the swap file turned down (it was full)
    var swapCoverage: String?
    var compressedMB: Int?      // compressed memory, which iOS counts at full size against the app
    var internalMB: Int?
    var externalMB: Int?
    var pageInsPerSample: Int?  // page-ins in the last engine sample
    var readMBPerSecond: Double?// data paged in from the swap file / disk

    var isEmpty: Bool { self == EngineStats() }

    /// The newest values in the log.
    static func read(from url: URL) -> EngineStats {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return EngineStats() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let span: UInt64 = 120_000
        try? handle.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return EngineStats() }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        var stats = EngineStats()
        var haveSwap = false, haveFootprint = false, haveXP = false
        for line in lines.reversed() {
            if !haveSwap, line.contains("[swap] census file-backed") {
                haveSwap = true
                stats.swapBackedMB = number(after: "now=", in: line)
                stats.swapPeakMB = number(after: "peak=", in: line)
                stats.swapFileUsedMB = number(after: " file=", in: line)
                if let slash = line.range(of: " file="), let cap = line[slash.upperBound...].firstIndex(of: "/") { stats.swapFileCapMB = number(at: line.index(after: cap), in: line) }
                // `file=` is how far into the swap file the engine has handed out ranges: the file is sparse, so in the broad and wide modes it runs to tens of GB while little
                // of it is on the disk. The cap (the number after the slash) limits what is really on the disk, which the line gives as `disk=` in those modes: that is the figure to show.
                if let disk = number(after: " disk=", in: line) { stats.swapFileUsedMB = disk }
                stats.swapRefused = number(after: "refused=", in: line)
                if let r = line.range(of: "coverage=") { stats.swapCoverage = String(line[r.upperBound...].prefix { $0 != " " }) }
            } else if !haveFootprint, line.contains("[footprint]") {
                haveFootprint = true
                stats.compressedMB = number(after: "compressed=", in: line)
                stats.internalMB = number(after: "internal=", in: line)
                stats.externalMB = number(after: "external=", in: line)
            } else if !haveXP, line.contains("[xp] "), !line.contains("[xp-") {
                haveXP = true
                stats.pageInsPerSample = number(after: " pin=", in: line)
                if let dt = number(after: " dt=", in: line), dt > 0, let kb = number(after: "rdKB=", in: line) { stats.readMBPerSecond = Double(kb) / 1024 * 1000 / Double(dt) }
            }
            if haveSwap && haveFootprint && haveXP { break }
        }
        return stats
    }

    private static func number(after marker: String, in line: Substring) -> Int? {
        guard let r = line.range(of: marker) else { return nil }
        return number(at: r.upperBound, in: line)
    }
    private static func number(at start: Substring.Index, in line: Substring) -> Int? {
        Int(line[start...].prefix { $0.isNumber })
    }
}
