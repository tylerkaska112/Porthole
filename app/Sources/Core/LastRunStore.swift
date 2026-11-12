// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The summary of each game's last run (LastRun), kept on the device. Written after a run's log was read (AutoFixStore does the reading), shown on the game's page.
@MainActor
final class LastRunStore: ObservableObject {
    static let shared = LastRunStore()
    @Published private(set) var summaries: [String: LastRun.Summary] = [:]

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("f4-lastrun.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: LastRun.Summary].self, from: data) { summaries = saved }
    }

    func summary(for gameID: UUID) -> LastRun.Summary? { summaries[gameID.uuidString] }

    func record(_ summary: LastRun.Summary) {
        summaries[summary.gameID.uuidString] = summary
        // The newest sixty games are enough.
        if summaries.count > 60 { for key in summaries.sorted(by: { $0.value.at < $1.value.at }).prefix(summaries.count - 60).map(\.key) { summaries[key] = nil } }
        if let data = try? JSONEncoder().encode(summaries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
