// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A place games come from (a launcher with its own library). The Stores tab, the "all games" page and the badge on a game's card are all driven from this list, so
/// adding a launcher later means: a case here, its drawing in `StoreBadge`, its library screen and its entries in `StoreCatalog` (all in the same few files).
enum GameStore: String, CaseIterable, Identifiable, Hashable {
    case steam, epic, gog, itch, amazon
    var id: String { rawValue }

    var title: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .gog: "GOG"
        case .itch: "itch.io"
        case .amazon: "Amazon Games"
        }
    }
    var tint: Color {
        switch self {
        case .steam: Color(red: 0.40, green: 0.62, blue: 0.82)
        case .epic: Color(red: 0.75, green: 0.78, blue: 0.84)
        case .gog: Color(red: 0.62, green: 0.36, blue: 0.80)
        case .itch: Color(red: 0.98, green: 0.36, blue: 0.36)
        case .amazon: Color(red: 1.0, green: 0.60, blue: 0.0)
        }
    }
}

/// How a store's grid is ordered. The choice is kept and shared by every store's grid and the all-games page.
enum StoreSort: String, CaseIterable, Identifiable, Hashable {
    case name, recent, installed, size
    var id: String { rawValue }
    static let key = "f4.storeSort"
    var title: String {
        switch self {
        case .name: "A to Z"
        case .recent: "Recently played"
        case .installed: "Installed first"
        case .size: "Largest first"
        }
    }
    /// Epic does not say how big a game is before it is installed, so its grid has no size order.
    static func options(includingSize: Bool) -> [(StoreSort, String)] {
        allCases.filter { includingSize || $0 != .size }.map { ($0, $0.title) }
    }
}

extension Game {
    /// The store this game was downloaded from through Porthole (nil for a game that was added from files).
    var store: GameStore? {
        if epicAppName != nil { return .epic }
        if gogID != nil { return .gog }
        if itchID != nil { return .itch }
        if amazonID != nil { return .amazon }
        if dockAppID != nil { return .steam }
        return nil
    }
}

/// One game of a store's library, in the plain shape the all-games page needs.
struct StoreGameEntry: Identifiable, Equatable {
    enum Status: Equatable {
        case notInstalled, installed, queued, downloading(Double), paused, failed(String)
    }
    let store: GameStore
    let key: String
    let title: String
    let art: URL?
    let status: Status
    var id: String { store.rawValue + ":" + key }
}

/// What each store's library holds right now, read from the stores' own models.
@MainActor enum StoreCatalog {
    static func signedIn(_ store: GameStore) -> Bool {
        switch store {
        case .steam: SteamStore.shared.signedIn
        case .epic: EpicAuth.shared.signedIn
        case .gog: GogAuth.shared.signedIn
        case .itch: ItchAuth.shared.signedIn
        case .amazon: AmazonAuth.shared.signedIn
        }
    }

    static func account(_ store: GameStore) -> String? {
        switch store {
        case .steam: SteamStore.shared.accountName
        case .epic: EpicAuth.shared.accountName.flatMap { $0.isEmpty ? nil : $0 }
        case .gog: GogAuth.shared.accountName
        case .itch: ItchAuth.shared.accountName
        case .amazon: AmazonAuth.shared.accountName
        }
    }

    static func entries(_ store: GameStore) -> [StoreGameEntry] {
        switch store {
        case .steam:
            let steam = SteamStore.shared
            return steam.owned.map { game in
                var status: StoreGameEntry.Status = steam.isInstalled(game.id) ? .installed : .notInstalled
                if let d = steam.downloads[game.id] {
                    switch d.state {
                    case .queued: status = .queued
                    case .active: status = .downloading(d.progress.fraction)
                    case .paused: status = .paused
                    case .failed(let message): status = .failed(message)
                    }
                }
                return StoreGameEntry(store: .steam, key: String(game.id), title: game.name,
                                      art: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.id)/header.jpg"), status: status)
            }
        case .epic:
            let installer = EpicInstaller.shared
            return EpicLibrary.shared.games.map { game in
                var status = StoreGameEntry.Status.notInstalled
                if let install = installer.installs[game.appName] {
                    switch install.state {
                    case .installed: status = .installed
                    case .queued: status = .queued
                    case .active: status = .downloading(install.progress.fraction)
                    case .paused: status = .paused
                    case .failed(let message): status = .failed(message)
                    }
                }
                return StoreGameEntry(store: .epic, key: game.appName, title: game.title, art: game.heroURL ?? game.artworkURL, status: status)
            }
        case .gog:
            let installer = GogInstaller.shared
            return GogLibrary.shared.games.map { game in
                var status = StoreGameEntry.Status.notInstalled
                if let install = installer.installs[game.id] {
                    switch install.state {
                    case .installed: status = .installed
                    case .queued: status = .queued
                    case .active: status = .downloading(install.progress.fraction)
                    case .paused: status = .paused
                    case .failed(let message): status = .failed(message)
                    case .ready, .running: status = .queued
                    }
                }
                return StoreGameEntry(store: .gog, key: game.key, title: game.title, art: game.art, status: status)
            }
        case .itch:
            let installer = ItchInstaller.shared
            return ItchLibrary.shared.games.map { game in
                var status = StoreGameEntry.Status.notInstalled
                if let install = installer.installs[game.id] {
                    switch install.state {
                    case .installed: status = .installed
                    case .queued, .ready, .running: status = .queued
                    case .active: status = .downloading(install.progress.fraction)
                    case .paused: status = .paused
                    case .failed(let message): status = .failed(message)
                    }
                }
                return StoreGameEntry(store: .itch, key: game.key, title: game.title, art: game.cover, status: status)
            }
        case .amazon:
            let installer = AmazonInstaller.shared
            return AmazonLibrary.shared.games.map { game in
                var status = StoreGameEntry.Status.notInstalled
                if let install = installer.installs[game.id] {
                    switch install.state {
                    case .installed: status = .installed
                    case .queued: status = .queued
                    case .active: status = .downloading(install.progress.fraction)
                    case .paused: status = .paused
                    case .failed(let message): status = .failed(message)
                    }
                }
                return StoreGameEntry(store: .amazon, key: game.key, title: game.title, art: game.art, status: status)
            }
        }
    }

    /// "12 games, 3 installed", or why there are none.
    static func summary(_ store: GameStore) -> String {
        guard signedIn(store) else { return "Not signed in" }
        let list = entries(store)
        if list.isEmpty { return "Signed in" + (account(store).map { " as \($0)" } ?? "") + " \u{00B7} no games yet" }
        let installed = list.filter { $0.status == .installed }.count
        return "\(list.count) game\(list.count == 1 ? "" : "s") \u{00B7} \(installed) installed"
    }
}
