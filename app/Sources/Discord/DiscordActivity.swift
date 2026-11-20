// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What Porthole tells Discord this account is doing, when the person turned that on: playing a game ("Firewatch on Porthole"), or what they are doing in the app (browsing the library,
/// downloading, adjusting settings). Pure, so it is tested without a connection.
enum DiscordActivity {
    static let maxName = 128
    static let app = "Porthole"

    /// What the person is doing.
    enum Kind: Equatable {
        case game(String)
        /// One game's name, or nil for several (or an unnamed one).
        case downloading(String?)
        case browsingLibrary
        case browsingStores
        case readingReports
        case settings
        case other
    }

    /// The text without line breaks and stray spaces, at most `limit` characters. Nil when nothing is left.
    static func cleanName(_ raw: String, limit: Int = maxName) -> String? {
        let one = raw.components(separatedBy: .newlines).joined(separator: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return one.isEmpty ? nil : String(one.prefix(limit))
    }

    /// What to show for what is going on: a game that is running comes first, then a download, then the screen the person is on. `tab` is the app's section.
    static func kind(game: String?, downloading: [String], tab: String) -> Kind {
        if let game, cleanName(game) != nil { return .game(game) }
        if !downloading.isEmpty { return .downloading(downloading.count == 1 ? downloading[0] : nil) }
        switch tab {
        case "library": return .browsingLibrary
        case "stores": return .browsingStores
        case "compatibility": return .readingReports
        case "settings": return .settings
        default: return .other
        }
    }

    /// The line under "Playing Porthole" for the kinds that are not a game.
    static func details(_ kind: Kind) -> String? {
        switch kind {
        case .game: nil
        case .downloading(let name): name.flatMap { cleanName($0, limit: 80) }.map { "Downloading \($0)" } ?? "Downloading games"
        case .browsingLibrary: "Browsing their library"
        case .browsingStores: "Browsing the game stores"
        case .readingReports: "Reading game reports"
        case .settings: "Adjusting settings"
        case .other: "Using the app"
        }
    }

    /// The `activities` entry (type 0 is "Playing"): "<game> on Porthole" while a game runs, else "Porthole" with a line about what is going on. Since a time.
    static func activity(for kind: Kind, since: Date) -> [String: Any]? {
        let ms = Int(since.timeIntervalSince1970 * 1000)
        var entry: [String: Any] = ["type": 0, "created_at": ms, "timestamps": ["start": ms]]
        switch kind {
        case .game(let title):
            guard let clean = cleanName(title, limit: maxName - " on \(app)".count) else { return nil }
            entry["name"] = "\(clean) on \(app)"
        default:
            entry["name"] = app
            if let line = details(kind) { entry["details"] = line }
        }
        return entry
    }

    /// The gateway's presence object (sent when connecting, and as op 3 when the activity changes). No activity means none is shown.
    static func presence(activity: [String: Any]?) -> [String: Any] {
        ["since": NSNull(), "activities": activity.map { [$0] } ?? [], "status": "online", "afk": false]
    }
}
