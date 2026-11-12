// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// The games a GOG account owns. The owned ids need the signed-in token; titles, art and "has a Windows version" come from GOG's public product endpoint.
// The last list is kept on disk so the library shows at once, before (or without) the network.

import Foundation
import Combine

struct GogGame: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let slug: String
    /// A wide picture, already cropped to the tile's shape; nil when GOG has none.
    let artURL: String?

    var key: String { String(id) }
    var art: URL? { artURL.flatMap(URL.init(string:)) }
    var storePage: URL? { URL(string: "https://www.gog.com/game/\(slug)") }
}

@MainActor
final class GogLibrary: ObservableObject {
    static let shared = GogLibrary()

    @Published private(set) var games: [GogGame] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private var lastRefresh: Date?
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("gog-library.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? JSONDecoder().decode([GogGame].self, from: data) { games = cached }
    }

    func refreshIfStale() {
        guard GogAuth.shared.signedIn else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        refresh()
    }

    func clear() {
        games = []
        error = nil
        lastRefresh = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    func refresh() {
        guard !isLoading else { return }
        guard NetworkStatus.shared.isOnline else { LogStore.shared.log("[gog-library] offline: keeping the saved list"); return }
        isLoading = true
        lastRefresh = Date()
        error = nil
        Task {
            do {
                let token = try await GogAuth.shared.validAccessToken()
                let list = try await Self.fetchAll(token: token, known: Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0.artURL) }))
                if let data = try? JSONEncoder().encode(list) {
                    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.cacheURL, options: .atomic)
                }
                games = list
                GogInstaller.shared.refreshArt(from: list)
            } catch {
                LogStore.shared.log("[gog-library] refresh failed: \((error as? GogAuthError)?.message ?? "\(error)")", level: .error)
                self.error = (error as? GogAuthError)?.message ?? ErrorText.plain(error)
            }
            isLoading = false
        }
    }

    // MARK: Fetching

    private nonisolated static func fetchAll(token: String, known: [Int: String?]) async throws -> [GogGame] {
        var request = URLRequest(url: URL(string: "https://embed.gog.com/user/data/games")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await StoreNetwork.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let owned = json["owned"] as? [Any] else {
            LogStore.shared.log("[gog-library] owned list not understood: status \(status), \(data.count) bytes", level: .error)
            throw GogAuthError.rejected("the library answered \(status)")
        }
        let ids = Array(Set(owned.compactMap { ($0 as? Int) ?? Int("\($0)") })).sorted()
        var games: [GogGame] = []
        var skipped = 0
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = ids[start ..< min(start + 50, ids.count)].map(String.init).joined(separator: ",")
            var c = URLComponents(string: "https://api.gog.com/products")!
            c.queryItems = [URLQueryItem(name: "ids", value: batch)]
            var r = URLRequest(url: c.url!)
            r.timeoutInterval = 20
            let (d, resp) = try await StoreNetwork.session.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let items = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
                throw GogAuthError.network
            }
            for item in items {
                guard let id = item["id"] as? Int, let title = item["title"] as? String else { continue }
                // Only whole games with a Windows build: add-ons, packs and Mac/Linux-only titles are not shown.
                let windows = ((item["content_system_compatibility"] as? [String: Any])?["windows"] as? Bool) ?? false
                guard (item["game_type"] as? String ?? "game") == "game", windows else { skipped += 1; continue }
                games.append(GogGame(id: id, title: title, slug: item["slug"] as? String ?? "", artURL: art(from: item["images"] as? [String: Any])))
            }
        }
        // Card art (GOG's own 16:9 picture of the game with its title). The store background used before fades to white at the bottom, so it is only the fallback.
        var cards: [Int: String] = [:]
        for (id, art) in known { if let art, art.contains("product_card") { cards[id] = art } }
        let missing = games.map(\.id).filter { cards[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 8) {
            let batch = Array(missing[start ..< min(start + 8, missing.count)])
            await withTaskGroup(of: (Int, String?).self) { group in
                for id in batch { group.addTask { (id, await cardArt(id: id)) } }
                for await (id, art) in group { if let art { cards[id] = art } }
            }
        }
        games = games.map { GogGame(id: $0.id, title: $0.title, slug: $0.slug, artURL: cards[$0.id] ?? $0.artURL) }
        LogStore.shared.log("[gog-library] \(ids.count) owned, \(games.count) with a Windows version, \(skipped) left out, \(cards.count) card picture(s)")
        return games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private nonisolated static func cardArt(id: Int) async -> String? {
        guard let url = URL(string: "https://api.gog.com/v2/games/\(id)?locale=en-US") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await StoreNetwork.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = (json["_embedded"] as? [String: Any])?["product"] as? [String: Any],
              let link = (product["_links"] as? [String: Any])?["image"] else { return nil }
        let href = ((link as? [String: Any])?["href"] as? String) ?? (link as? String)
        guard let href, href.contains("{formatter}") else { return nil }
        return href.replacingOccurrences(of: "{formatter}.png", with: "product_card_v2_mobile_slider_639.jpg")
    }

    /// The account's hero picture, cropped to the tile's shape by GOG's image service (about 85 KB instead of the 270 KB original).
    private nonisolated static func art(from images: [String: Any]?) -> String? {
        guard var raw = images?["background"] as? String, !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        if raw.hasSuffix(".jpg") { raw = String(raw.dropLast(4)) + "_bg_crop_1366x655.jpg" }
        return raw
    }
}
