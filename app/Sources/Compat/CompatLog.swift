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

    /// The log of the run that played this game: of this run's log, the run before, and the game's own session logs (Documents/logs), the most recently written one that
    /// mentions the game's launch (`game=<name>` in the launch-screen lines). A report is usually written after the app was opened again (the game ended, or iOS closed the app),
    /// and by then this run's log is only a few seconds of start-up: it is always the newest file, but it holds no game. When no file mentions the game the newest one is used,
    /// as before. Nil when none can be read.
    @MainActor static func gather(for game: Game) async -> Gathered? {
        let current = LogStore.shared.logFileURL
        let docs = current.deletingLastPathComponent()
        let previous = docs.appendingPathComponent("madeira-log.prev.txt")
        let logs = docs.appendingPathComponent("logs", isDirectory: true)
        let modified: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var candidates: [(url: URL, label: String)] = [(current, "this run"), (previous, "the run before")]
        let sessions = ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "txt" }
        for newest in sessions.sorted(by: { modified($0) > modified($1) }).prefix(3) { candidates.append((newest, "the game's log (\(newest.lastPathComponent))")) }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.url.path) }.sorted { modified($0.url) > modified($1.url) }
        let marker = Data("game=\(game.name)".utf8)
        let mentionsGame = await Task.detached(priority: .utility) { () -> [Bool] in
            existing.map { c in
                guard let data = try? Data(contentsOf: c.url, options: .mappedIfSafe) else { return false }
                return data.range(of: marker) != nil
            }
        }.value
        guard let pick = zip(existing, mentionsGame).first(where: { $0.1 })?.0 ?? existing.first else { return nil }
        let names = [EpicAuth.shared.accountName, SteamStore.shared.accountName, GogAuth.shared.accountName, ItchAuth.shared.accountName, AmazonAuth.shared.accountName, EAAuth.shared.accountName]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let facts = ProblemReport.facts()
        let label = pick.label
        let text: Data? = await Task.detached(priority: .utility) {
            guard let raw = ProblemReport.read(pick.url) else { return nil }
            var out = Data("# Porthole compatibility report log: \(game.name)\n## About this install\n\(facts)\n\n## Log (\(label))\n".utf8)
            out.append(LogCleaner.cleanData(raw, accountNames: names))
            return out
        }.value
        guard let text, text.count > 0, let packed = try? (text as NSData).compressed(using: .zlib) as Data else { return nil }
        return Gathered(packed: packed, textBytes: text.count, source: label)
    }
}
