// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The last list of reported games the server gave, kept in Caches so the Reports tab has something to show without a connection.
enum CompatListCache {
    private struct Saved: Codable { var date: Date; var games: [CompatGameSummary] }

    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("compat-list.json")
    }

    static func save(_ games: [CompatGameSummary]) {
        guard !games.isEmpty, let data = try? JSONEncoder().encode(Saved(date: Date(), games: games)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> (date: Date, games: [CompatGameSummary])? {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return (saved.date, saved.games)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
