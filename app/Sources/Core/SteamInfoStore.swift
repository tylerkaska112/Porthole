// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The review score, the Steam Deck rating and the news of a Steam game, from Steam's public pages (no sign-in, only the game's number is sent). Scores are kept for a day;
/// news is read each time a screen asks, at most once an hour per game.
@MainActor
final class SteamInfoStore: ObservableObject {
    static let shared = SteamInfoStore()

    struct Info: Codable, Equatable {
        var reviews: SteamReviewSummary?
        var deck: SteamDeckStatus
        var at: Double
    }

    private static let key = "f4.steamInfo.v1"
    private static let maxAge: TimeInterval = 24 * 3600

    @Published private var entries: [String: Info] = [:]
    private var asking: Set<Int> = []
    private var newsCache: [Int: (items: [SteamNewsItem], at: Date)] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: Info].self, from: data) { entries = saved }
    }

    func info(for appID: Int?) -> Info? { appID.flatMap { entries[String($0)] } }

    /// Asks Steam unless the answer is less than a day old. Failing quietly leaves whatever is known.
    func refresh(appID: Int) async {
        let now = Date().timeIntervalSince1970
        if let known = entries[String(appID)], now - known.at < Self.maxAge { return }
        guard !asking.contains(appID) else { return }
        asking.insert(appID); defer { asking.remove(appID) }
        async let reviewData = Self.get("https://store.steampowered.com/appreviews/\(appID)?json=1&language=all&purchase_type=all&num_per_page=0")
        async let deckData = Self.get("https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=\(appID)")
        let (r, d) = await (reviewData, deckData)
        guard r != nil || d != nil else { return }                       // offline: ask again next time
        entries[String(appID)] = Info(reviews: r.flatMap(SteamStoreInfoParser.reviews), deck: d.map(SteamStoreInfoParser.deck) ?? .unknown, at: now)
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// The game's official announcements (patch notes), else whatever news Steam has for it, newest first. Nil when Steam could not be reached.
    func news(appID: Int) async -> [SteamNewsItem]? {
        if let cached = newsCache[appID], Date().timeIntervalSince(cached.at) < 3600 { return cached.items }
        let base = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appID)&count=10&maxlength=900&format=json"
        var items: [SteamNewsItem] = []
        var reached = false
        for feeds in ["&feeds=steam_community_announcements", ""] {
            guard let data = await Self.get(base + feeds) else { continue }
            reached = true
            items = SteamStoreInfoParser.news(data)
            if !items.isEmpty { break }
        }
        guard reached else { return nil }
        newsCache[appID] = (items, Date())
        return items
    }

    private nonisolated static func get(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
