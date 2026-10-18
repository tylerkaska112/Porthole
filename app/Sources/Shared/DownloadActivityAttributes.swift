// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import ActivityKit
import AppIntents
import Foundation

// Shared by the app and its Live Activity extension (F4Activity): what the download card says, and what its buttons do.

/// One download card on the lock screen and in the Dynamic Island: one per store while that store has a queue.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The game's name.
        var title: String
        /// "1.3 GB of 3.1 GB \u{00B7} 18 MB/s \u{00B7} 7 min left"
        var line: String
        var fraction: Double
        /// The queue is paused: the card offers Resume instead of Pause.
        var paused = false
        /// Done (installed) or stopped with a problem: no buttons, the line says which.
        var finished = false
        var failed = false
        var waiting = 0
    }

    /// "steam", "epic", "gog", "itch" or "amazon".
    var store: String

    var storeTitle: String { store == "epic" ? "Epic Games" : store == "gog" ? "GOG" : store == "itch" ? "itch.io" : store == "amazon" ? "Amazon Games" : "Steam" }
}

enum DownloadActivityAction: String {
    case pause, resume, cancel
}

/// What the card's buttons call. The buttons run in the app's process (LiveActivityIntent), where the app sets this when it starts.
enum DownloadActivityBridge {
    nonisolated(unsafe) static var handler: ((DownloadActivityAction, String) -> Void)?
}

struct PauseDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause downloads"
    static var isDiscoverable = false
    @Parameter(title: "Store", default: "") var store: String
    init() {}
    init(store: String) { self.store = store }
    func perform() async throws -> some IntentResult {
        DownloadActivityBridge.handler?(.pause, store)
        return .result()
    }
}

struct ResumeDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume downloads"
    static var isDiscoverable = false
    @Parameter(title: "Store", default: "") var store: String
    init() {}
    init(store: String) { self.store = store }
    func perform() async throws -> some IntentResult {
        DownloadActivityBridge.handler?(.resume, store)
        return .result()
    }
}

struct CancelDownloadIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel download"
    static var isDiscoverable = false
    @Parameter(title: "Store", default: "") var store: String
    init() {}
    init(store: String) { self.store = store }
    func perform() async throws -> some IntentResult {
        DownloadActivityBridge.handler?(.cancel, store)
        return .result()
    }
}
