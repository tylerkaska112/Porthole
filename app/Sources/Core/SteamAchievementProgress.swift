// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// How many of a game's achievements the signed-in account has ("12 of 50"), remembered from the last time they were read so a game's page can say it without opening the list.
/// Kept on the device only, per account.
@MainActor
final class SteamAchievementProgress: ObservableObject {
    static let shared = SteamAchievementProgress()

    struct Entry: Codable, Equatable { var unlocked: Int; var total: Int; var at: Double }
    private static let key = "f4.steamAchievementProgress.v1"
    private static let maxAge: TimeInterval = 3600

    @Published private var entries: [String: Entry] = [:]
    private var asking: Set<Int> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    }

    func entry(for appID: Int?) -> Entry? { appID.flatMap { entries[String($0)] } }

    /// "12 of 50 unlocked", "All 50 unlocked", or nil when nothing is known (or the game has none).
    func summary(for appID: Int?) -> String? {
        guard let e = entry(for: appID), e.total > 0 else { return nil }
        return e.unlocked >= e.total ? "All \(e.total) unlocked" : "\(e.unlocked) of \(e.total) unlocked"
    }

    func record(appID: Int, list: [SteamAchievement]) {
        entries[String(appID)] = Entry(unlocked: list.filter { $0.unlocked != nil }.count, total: list.count, at: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Reads the achievements again when what is known is over an hour old. Quiet when Steam can't be asked (a game is running, offline).
    func refresh(appID: Int, store: SteamStore) async {
        if let e = entries[String(appID)], Date().timeIntervalSince1970 - e.at < Self.maxAge { return }
        guard store.signedIn, !asking.contains(appID) else { return }
        asking.insert(appID); defer { asking.remove(appID) }
        _ = try? await store.achievements(appID)       // records the counts
    }

    /// Forgets everything (signing out).
    func clear() { entries = [:]; UserDefaults.standard.removeObject(forKey: Self.key) }
}
