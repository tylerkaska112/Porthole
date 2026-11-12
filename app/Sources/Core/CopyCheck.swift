// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Looks, once per game and start, whether the game's folder holds files of a modified release (CopyMarkers) and remembers it for the game's page and the launch screen. It only
/// ever informs: nothing is blocked, hidden or changed for the game.
@MainActor
final class CopyCheck: ObservableObject {
    static let shared = CopyCheck()

    @Published private(set) var found: [UUID: [String]] = [:]

    func marks(for game: Game) -> [String] { found[game.id] ?? [] }
    func has(_ game: Game?) -> Bool { game.map { !marks(for: $0).isEmpty } ?? false }

    /// Scans off the main thread. `log`: write the one line about it to the log (at a start, so a run's log says it).
    func refresh(for game: Game, log: Bool = false) {
        let id = game.id, exe = game.exe, name = game.name
        Task.detached(priority: .utility) {
            var marks = CopyMarkers.markers(forTitle: name)
            if let url = AppModel.unixURL(forWindows: exe) {
                let folder = url.deletingLastPathComponent()
                marks += CopyMarkers.markers(inFolder: folder)
                // Unreal games keep the exe two folders down (Game/Binaries/Win64): the release's files sit beside the game's own root.
                if folder.pathComponents.contains(where: { $0.lowercased() == "binaries" }) {
                    var root = folder
                    while root.lastPathComponent.lowercased() != "binaries", root.pathComponents.count > 1 { root.deleteLastPathComponent() }
                    marks += CopyMarkers.markers(inFolder: root.deletingLastPathComponent())
                }
            }
            var unique: [String] = []
            for m in marks where !unique.contains(m) { unique.append(m) }
            let result = unique
            await MainActor.run {
                if CopyCheck.shared.found[id] != result { CopyCheck.shared.found[id] = result }
                if log, !result.isEmpty {
                    LogStore.shared.log("[copy] files of a modified release are in this game's folder (\(result.joined(separator: ", "))): there is no support for this copy")
                }
            }
        }
    }
}
