// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The log that goes with a compatibility report. A report that says a game does not work is only worth something next to the log that shows why, so every report carries the
/// game's own log: the install facts first, then the log of the run, with personal paths, account names, e-mail and public IP addresses taken out (the same cleaning a problem
/// report gets). It is sent packed, kept private on the server, and read only in the developer's Launcher after the report is approved or rejected there: it is never shown in Reports.
enum CompatLog {
    struct Gathered {
        /// Raw deflate, which is what the server unpacks.
        var packed: Data
        /// The cleaned text it was made from.
        var textBytes: Int
        /// Where it came from, for the person: "this run" or the name of the game's own log.
        var source: String

        var base64: String { packed.base64EncodedString() }
        /// "8.2 MB of text, about 900 KB sent".
        var summary: String {
            func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
            return "\(source): \(size(textBytes)) of text, about \(size(packed.count)) sent"
        }
    }

    /// The logs that go with this game. First the game's own session logs (Documents/logs, "<program>.exe-<date>.txt"): every one whose name holds the game's name, its program's
    /// name or its Steam folder's name (CompatLogPicker), up to five of the newest, and, for what is left of those five, the newest session logs that mention the game's program
    /// inside. They are what the game wrote, so the problem is in them. Only when no game log is found (the game never started: a missing program, a failed JIT, a refused
    /// launch) the log of Porthole itself is used, as before: of this run's log, the run before, and the newest session logs, the one most recently written that mentions the
    /// game's launch (`game=<name>`), else the newest. The text goes oldest first, so that its end is the newest log's end. Nil when nothing can be read.
    @MainActor static func gather(for game: Game) async -> Gathered? {
        let current = LogStore.shared.logFileURL
        let docs = current.deletingLastPathComponent()
        let previous = docs.appendingPathComponent("madeira-log.prev.txt")
        let logs = docs.appendingPathComponent("logs", isDirectory: true)
        let modified: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let sessions = ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "txt" }
        let keys = CompatLogPicker.keys(gameName: game.name, exe: game.exe)
        let programFile = game.exe.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let programKey = CompatLogPicker.normalized(programFile.lowercased().hasSuffix(".exe") ? String(programFile.dropLast(4)) : programFile)
        let markers: [Data] = [Data("game=\(game.name)".utf8)] + (programKey.count >= 4 && !CompatLogPicker.generic.contains(programKey) ? [Data(programFile.utf8)] : [])
        let names = [EpicAuth.shared.accountName, SteamStore.shared.accountName, GogAuth.shared.accountName, ItchAuth.shared.accountName, AmazonAuth.shared.accountName, EAAuth.shared.accountName]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let facts = ProblemReport.facts()

        // The game's own logs.
        let files = sessions.map { (url: $0, modified: modified($0)) }
        let chosen: [URL] = await Task.detached(priority: .utility) { () -> [URL] in
            var picked = CompatLogPicker.matches(files, keys: keys, limit: 5)
            if picked.count < 5 {
                // Not named after the game, but about it: the newest few that mention its program (or its launch) inside.
                let others = files.filter { f in !picked.contains(f.url) && Date().timeIntervalSince(f.modified) < 14 * 24 * 3600 }.sorted { $0.modified > $1.modified }.prefix(6)
                for f in others where picked.count < 5 {
                    guard let data = try? Data(contentsOf: f.url, options: .mappedIfSafe) else { continue }
                    if markers.contains(where: { data.range(of: $0) != nil }) { picked.append(f.url) }
                }
            }
            return picked
        }.value
        if !chosen.isEmpty {
            let sections = chosen.sorted { modified($0) > modified($1) }.map { (url: $0, label: "the game's log (\($0.lastPathComponent))") }
            let label = sections.count == 1 ? sections[0].label : "\(sections.count) of the game's logs, newest \(sections[0].url.lastPathComponent)"
            if let built = await assemble(sections, title: game.name, facts: facts, names: names) { return Gathered(packed: built.packed, textBytes: built.bytes, source: label) }
        }

        // No game log: Porthole's own.
        var candidates: [(url: URL, label: String)] = [(current, "this run"), (previous, "the run before")]
        for newest in sessions.sorted(by: { modified($0) > modified($1) }).prefix(3) { candidates.append((newest, "the game's log (\(newest.lastPathComponent))")) }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.url.path) }.sorted { modified($0.url) > modified($1.url) }
        let marker = Data("game=\(game.name)".utf8)
        let mentionsGame = await Task.detached(priority: .utility) { () -> [Bool] in
            existing.map { c in
                guard let data = try? Data(contentsOf: c.url, options: .mappedIfSafe) else { return false }
                return data.range(of: marker) != nil
            }
        }.value
        guard let pick = zip(existing, mentionsGame).first(where: { $0.1 })?.0 ?? existing.first,
              let built = await assemble([pick], title: game.name, facts: facts, names: names) else { return nil }
        return Gathered(packed: built.packed, textBytes: built.bytes, source: pick.label)
    }

    /// Where the logs that are being prepared on several cores are collected.
    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [Data?]
        init(_ count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ data: Data) { lock.lock(); items[index] = data; lock.unlock() }
    }

    /// The report text for these logs (newest first in, oldest first out): the install facts, then each log thinned of its repetition (LogThinner), cleaned of personal data and
    /// headed with where it came from. Each log is read, thinned and cleaned on a core of its own. The server takes 16 MB packed and 120 MB of text; what is sent is far below that
    /// (a 45 MB log is about 6 MB after thinning), the newest logs get their share first and the budget is halved until the whole fits.
    private static func assemble(_ sections: [(url: URL, label: String)], title: String, facts: String, names: [String]) async -> (packed: Data, bytes: Int)? {
        await Task.detached(priority: .utility) { () -> (packed: Data, bytes: Int)? in
            let slots = Slots(sections.count)
            DispatchQueue.concurrentPerform(iterations: sections.count) { i in
                guard let raw = ProblemReport.read(sections[i].url, cap: 60 * 1024 * 1024) else { return }
                let thinned = LogThinner.thin(raw).data
                var part = Data("\n## Log (\(sections[i].label))\n".utf8)
                part.append(LogCleaner.cleanData(thinned, accountNames: names))
                slots.set(i, part)
            }
            let prepared = slots.items
            var budget = 48 * 1024 * 1024
            for _ in 0..<4 {
                var remaining = budget
                var parts: [Data] = []
                for part in prepared {
                    guard let part, remaining > 256 * 1024 else { continue }
                    if part.count <= remaining { parts.append(part); remaining -= part.count; continue }
                    // Too much for what is left: its end is kept (the end of a log says how it ended), from a whole line.
                    var tail = part.suffix(remaining)
                    if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: newline + 1) }
                    parts.append(Data("\n[... the first part of this log is left out to keep the report small ...]\n".utf8) + tail)
                    remaining = 0
                }
                guard !parts.isEmpty else { return nil }
                var out = Data("# Porthole compatibility report log: \(title)\n## About this install\n\(facts)\n".utf8)
                for part in parts.reversed() { out.append(part) }       // oldest first: the end of the text is the newest log's end
                if let packed = try? (out as NSData).compressed(using: .zlib) as Data, packed.count <= 15 * 1024 * 1024 { return (packed, out.count) }
                budget /= 2
            }
            return nil
        }.value
    }
}
