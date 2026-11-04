// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The EA app in the Stores tab: sign in, then the grid of the PC games the account owns. A game opens a sheet with its install actions.

/// The EA app's library as a page of its own.
struct EAStoreScreen: View {
    @ObservedObject private var auth = EAAuth.shared
    @State private var signIn = false

    var body: some View {
        Group {
            if auth.signedIn { EAOwnedList() }
            else {
                FocusScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        StoreSwitcher()
                        StoreBadgeBacked(store: .ea, size: 56)
                        Text("Sign in to the EA app").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        Text("You sign in on EA's own page. The sign-in token stays in this device's Keychain; Porthole never sees your password. The PC games on your EA account are listed here, and Porthole starts them without the EA app: it asks EA for each game's licence itself and answers the game's questions the way the EA app would.")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        PillButton(id: "ea-signin", title: "Sign in", symbol: "person.badge.key.fill", style: .primary) { signIn = true }
                    }
                    .padding(.top, 12).padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $signIn) { EASignInView() }
    }
}

struct EAGameTile: View {
    let game: EAOwnedGame
    var showStore = false
    let open: () -> Void
    @ObservedObject private var installer = EAInstaller.shared

    private var install: EAInstaller.Install? { installer.installs[game.id] }

    private var badge: BadgeData? {
        switch install?.state {
        case .active?: return BadgeData(symbol: "arrow.down.circle.fill", text: "\(Int((install?.progress.fraction ?? 0) * 100))%", tint: Theme.accent)
        case .queued?: return BadgeData(symbol: "hourglass", text: "Waiting", tint: Theme.textDim)
        case .paused?: return BadgeData(symbol: "pause.circle.fill", text: "Paused", tint: Theme.warn)
        case .failed?: return BadgeData(symbol: "exclamationmark.triangle.fill", text: "Failed", tint: Theme.bad)
        case .installed?: return BadgeData(symbol: "checkmark.circle.fill", text: "Installed", tint: Theme.good)
        case nil: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                    .overlay { EpicArtView(url: game.art) }
                    .overlay(alignment: .topLeading) { if let badge { TileStatus(badge: badge).padding(8) } }
                    .overlay(alignment: .bottomTrailing) { if showStore { StoreCorner(store: .ea, size: 26).padding(8) } }
                    .storeTileStyle()
            }
            .buttonStyle(TilePress())
            .focusTarget("ea-\(game.id)", radius: 18, scale: 1.1, action: open)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if install?.state == .active {
                    TileProgress(value: install?.progress.fraction ?? 0)
                    Text(install?.step ?? EpicText.progress(install?.progress ?? SteamDownloadProgress())).font(.caption2).foregroundStyle(Theme.textDim)
                } else if case .failed(let why)? = install?.state {
                    Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct EAOwnedList: View {
    @ObservedObject private var library = EALibrary.shared
    @ObservedObject private var installer = EAInstaller.shared
    @ObservedObject private var network = NetworkStatus.shared
    @State private var search = ""
    @State private var open: EAOwnedGame?
    @State private var showAccount = false

    private var shown: [EAOwnedGame] {
        search.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        StorePage {
            StoreSwitcher()
            if !network.isOnline { OfflineChip() }
            if library.isLoading { ProgressView().tint(Theme.accent).frame(width: 44, height: 44) }
            else { IconPillButton(id: "ea-refresh", symbol: "arrow.clockwise", label: "Refresh the list") { library.refresh() } }
            SearchField(id: "ea-search", prompt: "Search \(library.games.count) game\(library.games.count == 1 ? "" : "s")", text: $search)
            IconPillButton(id: "ea-account", symbol: "person.crop.circle", label: "EA account") { showAccount = true }
        } content: {
            if let error = network.isOnline ? library.error : nil { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            if shown.isEmpty && !library.isLoading {
                Text(library.games.isEmpty ? "No PC games were found in this EA account." : "No games match.")
                    .foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(shown) { game in EAGameTile(game: game) { open = game } }
            }
            Text("EA games download straight from EA's servers. Games that use EA's kernel anti-cheat (Battlefield 2042 and later, EA SPORTS FC, Madden) cannot run here. Cloud saves, friends and EA's in-game overlay are not supported.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.top, 4)
        }
        .sheet(item: $open) { game in EAGameSheet(game: game) }
        .sheet(isPresented: $showAccount) { EASignInView() }
        .task { library.refreshIfStale() }
    }
}

/// An EA game: its picture and name, its size, and the install actions for its state (install, pause, update, repair, uninstall).
struct EAGameSheet: View {
    let game: EAOwnedGame
    @ObservedObject private var installer = EAInstaller.shared
    @ObservedObject private var library = EALibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    private var install: EAInstaller.Install? { installer.installs[game.id] }

    var body: some View {
        StoreSheetShell(store: .ea, title: game.title, subtitle: nil, close: { dismiss() }, art: { EpicArtView(url: game.art) }) {
                    sizeLine
                    actions
                    if let error = installer.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
        }
            .confirm("Uninstall \(game.title)?", message: "The game's folder is removed from this device. Your EA library and your save files in Porthole's backups are not touched.",
                     confirmTitle: "Uninstall and delete its files", destructive: true, isPresented: $confirmUninstall) { installer.uninstall(game.id) }
            .task {
                await library.loadSize(game.id)
                await library.checkForUpdate(game.id)
            }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var sizeLine: some View {
        switch library.sizes[game.id] {
        case .known(let download, let size)?:
            Text("Download \(ByteCountFormatter.string(fromByteCount: download, countStyle: .file)) \u{00B7} installed \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                .font(.footnote).foregroundStyle(.secondary)
        case .unavailable(let why)?:
            Text(why).font(.footnote).foregroundStyle(.secondary)
        case nil:
            if installer.installed[game.id] == nil { Text("Looking up the size\u{2026}").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var actions: some View {
        let installed = installer.installed[game.id] != nil
        switch install?.state {
        case nil:
            button("Install", symbol: "arrow.down.circle.fill", prominent: true) { installer.install(game.id) }
            note("Downloads the game straight from EA. Keep the app open while it installs.")
        case .queued?:
            Label("Waiting for its turn\u{2026}", systemImage: "hourglass").foregroundStyle(.secondary)
            button("Cancel", symbol: "xmark") { installer.cancel(game.id) }
        case .active?:
            let progress = install?.progress ?? SteamDownloadProgress()
            TileProgress(value: progress.fraction)
            Text(progress.phase == .preparing ? (install?.step ?? "Preparing\u{2026}") : EpicText.progress(progress)).font(.footnote).foregroundStyle(.secondary)
            HStack {
                button("Pause", symbol: "pause.fill") { installer.pause(game.id) }
                button("Cancel", symbol: "xmark", role: .destructive) { installer.cancel(game.id) }
            }
        case .paused?:
            TileProgress(value: install?.progress.fraction ?? 0)
            HStack {
                button("Resume", symbol: "play.fill", prominent: true) { installer.resume(game.id) }
                button(installed ? "Stop" : "Remove", symbol: installed ? "xmark" : "trash", role: .destructive) { installer.cancel(game.id) }
            }
        case .failed(let why)?:
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            HStack {
                button("Try again", symbol: "arrow.clockwise", prominent: true) { installer.resume(game.id) }
                button(installed ? "Stop" : "Remove", symbol: installed ? "xmark" : "trash", role: .destructive) { installer.cancel(game.id) }
            }
        case .installed?:
            Label("Installed. Find it in your library.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            if installer.updateAvailable(game.id) {
                button("Update", symbol: "arrow.triangle.2.circlepath", prominent: true) { installer.install(game.id) }
            }
            button("Check and repair files", symbol: "wrench.and.screwdriver") { installer.repair(game.id) }
            button("Uninstall", symbol: "trash", role: .destructive) { confirmUninstall = true }
        }
    }

    private func note(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(Theme.textDim) }

    private func button(_ title: String, symbol: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        StoreSheetButton(title: title, symbol: symbol, prominent: prominent, destructive: role == .destructive, action: action)
    }
}
