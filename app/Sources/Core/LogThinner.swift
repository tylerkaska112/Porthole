// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Takes the repetition out of a game's log before it is cleaned, packed and sent with a compatibility report. A run of a big game writes tens of megabytes, and most of it is one
/// diagnostic repeated (thread stacks, draw dumps, file-descriptor traces, per-second counters): the first lines of each kind say everything the rest do. Keeping the first
/// `firstPerKind` lines of every kind and one in `thenEvery` after that makes a 45 MB log about 6 MB, so reading, cleaning, packing and sending it take a seventh of the time,
/// and the developer's Launcher downloads less. What is never thinned: the app's own timestamped lines (`[hh:mm:ss.mmm] [INFO] ...`), the tags that carry the measurements and
/// the game's own log (`[guest-log]`, `[telemetry]`, `[xp]`, `[lsfg]`, `[swap]`, ...), the first and last lines of the log (the end says how it ended), and any line that names a
/// crash or a failure (one in five of those once a kind has been seen 150 times, so a storm of them still shrinks). A note at the top says what was left out.
enum LogThinner {
    static let firstPerKind = 150
    static let thenEvery = 40
    static let keepFirstLines = 300
    static let keepLastLines = 400

    struct Output {
        var data: Data
        var linesIn: Int
        var linesKept: Int
    }

    /// Kinds that are always kept whole: what the app writes about itself, and the measurements the developer reads.
    private static let alwaysTags: Set<UInt64> = Set([
        "xp", "guest-log", "lsfg", "telemetry", "mem-pressure", "gpu-perf", "FRAME_STATS", "PRESENT_GAP", "pso-warm", "pso-archive", "footprint", "swap", "autofix", "pad", "settings",
        "game-cfg", "engine", "compat", "crash", "jit", "dock", "display", "power", "audio", "prefix", "phase", "sc-cef", "thread-sample", "app", "steam-input", "rumble", "hwinput",
        "mem-alert", "bg-run", "promote", "clamp-diag", "f4-hud", "cloud", "dock-installers", "dock-offline", "dock-launch", "dock-handoff", "dock-wow", "dock-game-scm", "exe-window",
    ].map { fnv(Array($0.utf8)) })

    /// Substrings that make a line worth keeping even in a storm of its kind.
    private static let important: [[UInt8]] = ["Assertion", "abort_process", "Game exited", "FATAL", "Timed out", "failed to", "ERR_", "nhandled exception", "Game End", "crash"].map { Array($0.utf8) }

    private static func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    @inline(__always) private static func isHexOrX(_ b: UInt8) -> Bool { (b >= 48 && b <= 57) || (b >= 97 && b <= 102) || b == 120 }
    @inline(__always) private static func isTagByte(_ b: UInt8) -> Bool { (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 45 || b == 46 }

    /// "[18:41:14.123] [INFO] ..." (the app's own line).
    private static func isAppLine(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> Bool {
        guard e - s > 20, p[s] == 91, p[s + 3] == 58, p[s + 6] == 58, p[s + 9] == 46, p[s + 13] == 93, p[s + 14] == 32, p[s + 15] == 91 else { return false }
        return p[s + 16] >= 65 && p[s + 16] <= 90
    }

    /// The kind of a line: the first `[tag]` in its first 60 bytes; a Wine `0198:err:module:function` prefix; else its first 24 bytes with digits and hex letters made equal.
    /// Returns the tag's hash and whether it was a `[tag]`.
    private static func kind(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> (hash: UInt64, isTag: Bool) {
        let limit = min(e, s + 60)
        var i = s
        while i < limit {
            if p[i] == 91 {   // [
                var j = i + 1
                while j < e, j - i <= 25, isTagByte(p[j]) { j += 1 }
                if j < e, p[j] == 93, j - i >= 3 {
                    var h: UInt64 = 0xcbf29ce484222325
                    for k in (i + 1)..<j { h = (h ^ UInt64(p[k])) &* 0x100000001b3 }
                    return (h, true)
                }
            }
            i += 1
        }
        // 0198:err:seh:function ...
        if e - s > 12, p[s + 4] == 58, isHexOrX(p[s]), isHexOrX(p[s + 1]), isHexOrX(p[s + 2]), isHexOrX(p[s + 3]) {
            var colons = 0, j = s + 5
            while j < e, colons < 2 { if p[j] == 58 { colons += 1 }; j += 1 }
            while j < e, p[j] != 32, p[j] != 58 { j += 1 }
            var h: UInt64 = 0x84222325cbf29ce4
            for k in (s + 5)..<j { h = (h ^ UInt64(p[k])) &* 0x100000001b3 }
            return (h, false)
        }
        var h: UInt64 = 0x1234567
        for k in s..<min(e, s + 24) { let b = isHexOrX(p[k]) ? UInt8(35) : p[k]; h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return (h, false)
    }

    private static func contains(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard e - s >= n, let base = p.baseAddress else { return false }
        return needle.withUnsafeBufferPointer { nb in memmem(base + s, e - s, nb.baseAddress!, n) != nil }
    }

    static func thin(_ data: Data) -> Output {
        var lines: [(Int, Int)] = []     // start, end (without the newline)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            guard let base = p.baseAddress else { return }
            var s = 0
            let n = p.count
            lines.reserveCapacity(n / 90)
            while s < n {
                if let nl = memchr(base + s, 10, n - s) {
                    let e = base.distance(to: nl.assumingMemoryBound(to: UInt8.self))
                    lines.append((s, e)); s = e + 1
                } else { lines.append((s, n)); s = n }
            }
        }
        let total = lines.count
        // Nothing to thin in a log that is already small.
        if data.count < 1_500_000 { return Output(data: data, linesIn: total, linesKept: total) }
        var out = [UInt8]()
        out.reserveCapacity(data.count / 4)
        var counts: [UInt64: Int] = [:]
        var names: [UInt64: (name: String, dropped: Int)] = [:]
        var kept = 0, dropped = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for (index, line) in lines.enumerated() {
                let (s, e) = line
                var keep = index < keepFirstLines || index >= total - keepLastLines || isAppLine(p, s, e)
                if !keep {
                    let (k, isTag) = kind(p, s, e)
                    if isTag, alwaysTags.contains(k) { keep = true }
                    else {
                        let n = (counts[k] ?? 0) + 1
                        counts[k] = n
                        if n <= firstPerKind || n % thenEvery == 0 { keep = true }
                        else if n % 5 == 0, important.contains(where: { contains(p, s, e, $0) }) { keep = true }
                        if !keep {
                            var entry = names[k] ?? (name: "", dropped: 0)
                            if entry.name.isEmpty { entry.name = String(decoding: p[s..<min(e, s + 28)], as: UTF8.self) }
                            entry.dropped += 1
                            names[k] = entry
                        }
                    }
                }
                if keep { out.append(contentsOf: p[s..<e]); out.append(10); kept += 1 } else { dropped += 1 }
            }
        }
        let top = names.values.sorted { $0.dropped > $1.dropped }.prefix(8).map { "\($0.name.trimmingCharacters(in: .whitespaces)) x\($0.dropped)" }.joined(separator: "; ")
        let note = "[... \(dropped) of \(total) lines of repeated diagnostics were thinned out of this log to keep the report small (the first \(firstPerKind) of every kind and one in \(thenEvery) after that stay; the app's own lines, the measurements and the end of the log are whole). Most thinned: \(top) ...]\n"
        var result = Data(note.utf8)
        result.append(contentsOf: out)
        return Output(data: result, linesIn: total, linesKept: kept)
    }
}
