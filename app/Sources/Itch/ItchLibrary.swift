// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// The games an itch.io account owns (bought, claimed, from bundles or gifted) that have a Windows download. Kept on disk so the library shows at once.

import Foundation
import Combine

@MainActor
final class ItchLibrary: ObservableObject {
    static let shared = ItchLibrary()

    @Published private(set) var games: [ItchGame] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private var lastRefresh: Date?
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("itch-library.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? JSONDecoder().decode([ItchGame].self, from: data) { games = cached }
    }

    func refreshIfStale() {
        guard ItchAuth.shared.signedIn else { return }
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
        guard !isLoading, let key = ItchAuth.shared.apiKey() else { return }
        guard NetworkStatus.shared.isOnline else { LogStore.shared.log("[itch-library] offline: keeping the saved list"); return }
        isLoading = true
        lastRefresh = Date()
        error = nil
        Task {
            do {
                let list = try await ItchAPI.ownedGames(key: key)
                if let data = try? JSONEncoder().encode(list) {
                    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.cacheURL, options: .atomic)
                }
                games = list
                ItchInstaller.shared.refreshArt(from: list)
                LogStore.shared.log("[itch-library] \(list.count) game(s) with a Windows download")
            } catch {
                LogStore.shared.log("[itch-library] refresh failed: \(error.localizedDescription)", level: .error)
                self.error = ErrorText.plain(error)
            }
            isLoading = false
        }
    }
}
