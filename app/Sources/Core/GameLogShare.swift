// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A game's own log, cleaned and written to one file the share sheet can hand to Files, AirDrop or a message: what a person sends when something went wrong and no full report is wanted.
/// The log is the newest session log named after the game (Documents/logs, see CompatLogPicker); when the game left none (it never started), the log of the run before.
enum GameLogShare {
    static func latestLog(for game: Game) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("logs", isDirectory: true)
        let modified: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "txt" }
            .map { (url: $0, modified: modified($0)) }
        if let newest = CompatLogPicker.matches(files, keys: CompatLogPicker.keys(gameName: game.name, exe: game.exe), limit: 1).first { return newest }
        let previous = docs.appendingPathComponent("madeira-log.prev.txt")
        return FileManager.default.fileExists(atPath: previous.path) ? previous : nil
    }

    /// The cleaned log with the install facts above it, in a temporary file; nil when there is no log or it cannot be read. The caller removes the file when the share sheet closes.
    @MainActor static func prepare(for game: Game) async -> URL? {
        guard let log = latestLog(for: game) else { return nil }
        let names = [EpicAuth.shared.accountName, SteamStore.shared.accountName, GogAuth.shared.accountName, ItchAuth.shared.accountName, AmazonAuth.shared.accountName, EAAuth.shared.accountName]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let facts = ProblemReport.facts()
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmm"; stamp.locale = Locale(identifier: "en_US_POSIX")
        let safe = String(game.name.map { "/\\:*?\"<>|".contains($0) ? "_" : $0 })
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Porthole-\(safe)-log-\(stamp.string(from: Date())).txt")
        let gameName = game.name
        return await Task.detached(priority: .utility) { () -> URL? in
            guard let raw = ProblemReport.read(log, cap: 40 * 1024 * 1024), !raw.isEmpty else { return nil }
            var out = Data("# Porthole log: \(gameName)\n## About this install\n\(facts)\n\n## Log (\(log.lastPathComponent))\n".utf8)
            out.append(LogCleaner.cleanData(raw, accountNames: names))
            do { try out.write(to: target, options: .atomic); return target } catch { return nil }
        }.value
    }
}
