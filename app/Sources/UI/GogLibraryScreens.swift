// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// GOG in the Stores tab: sign in, then the grid of the games the account owns. A game opens a sheet with its install actions.

/// GOG's library as a page of its own.
struct GogStoreScreen: View {
    @ObservedObject private var auth = GogAuth.shared
    @State private var signIn = false

    var body: some View {
        Group {
            if auth.signedIn { GogOwnedList() }
            else {
                FocusScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        StoreSwitcher()
                        StoreBadgeBacked(store: .gog, size: 56)
                        Text("Sign in to GOG").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        Text("You sign in on GOG's own page. The sign-in token stays in this device's Keychain; Porthole never sees your password. Your games that have a Windows version are listed here.")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        PillButton(id: "gog-signin", title: "Sign in", symbol: "person.badge.key.fill", style: .primary) { signIn = true }
                    }
                    .padding(.top, 12).padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $signIn) { GogSignInView() }
    }
}

struct GogGameTile: View {
    let game: GogGame
    var showStore = false
    let open: () -> Void
    @ObservedObject private var installer = GogInstaller.shared

    private var install: GogInstaller.Install? { installer.installs[game.id] }

    private var badge: BadgeData? {
        switch install?.state {
        case .active?: return BadgeData(symbol: "arrow.down.circle.fill", text: "\(Int((install?.progress.fraction ?? 0) * 100))%", tint: Theme.accent)
        case .queued?: return BadgeData(symbol: "hourglass", text: "Waiting", tint: Theme.textDim)
        case .paused?: return BadgeData(symbol: "pause.circle.fill", text: "Paused", tint: Theme.warn)
        case .failed?: return BadgeData(symbol: "exclamationmark.triangle.fill", text: "Failed", tint: Theme.bad)
        case .ready?: return BadgeData(symbol: "shippingbox.fill", text: "Ready to install", tint: Theme.accent)
        case .running?: return BadgeData(symbol: "gearshape.fill", text: "Installing", tint: Theme.accent)
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
                    .overlay(alignment: .bottomTrailing) { if showStore { StoreCorner(store: .gog, size: 26).padding(8) } }
                    .storeTileStyle()
            }
            .buttonStyle(TilePress())
            .focusTarget("gg-\(game.id)", radius: 18, scale: 1.1, action: open)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if install?.state == .active {
                    TileProgress(value: install?.progress.fraction ?? 0)
                    Text(EpicText.progress(install?.progress ?? SteamDownloadProgress())).font(.caption2).foregroundStyle(Theme.textDim)
                } else if case .failed(let why)? = install?.state {
                    Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct GogOwnedList: View {
    @ObservedObject private var library = GogLibrary.shared
    @ObservedObject private var network = NetworkStatus.shared
    @State private var search = ""
    @State private var open: GogGame?
    @State private var showAccount = false

    private var shown: [GogGame] {
        search.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        StorePage {
            if !network.isOnline { OfflineChip() }
            if library.isLoading { ProgressView().tint(Theme.accent).frame(width: 44, height: 44) }
            else { IconPillButton(id: "go-refresh", symbol: "arrow.clockwise", label: "Refresh the list") { library.refresh() } }
            searchField
            IconPillButton(id: "go-account", symbol: "person.crop.circle", label: "GOG account") { showAccount = true }
        } content: {
            if let error = network.isOnline ? library.error : nil { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            if shown.isEmpty && !library.isLoading {
                Text(library.games.isEmpty ? "No games with a Windows version found on this account yet." : "No games match.")
                    .foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(shown) { game in GogGameTile(game: game) { open = game } }
            }
            Text("GOG games install by downloading GOG's own setup file and running it inside Porthole. Achievements and other Galaxy features work for games installed from GOG's own builds (Settings > Stores > GOG).")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.top, 4)
        }
        .sheet(item: $open) { game in GogGameSheet(game: game) }
        .sheet(isPresented: $showAccount) { GogSignInView() }
        .task { library.refreshIfStale() }
    }

    private var searchField: some View { SearchField(id: "go-search", prompt: "Search \(library.games.count) game\(library.games.count == 1 ? "" : "s")", text: $search) }
}

/// A GOG game: its picture and name, and the install actions for its state (install, pause, run the setup, uninstall).
struct GogGameSheet: View {
    let game: GogGame
    @ObservedObject private var installer = GogInstaller.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    private var state: GogInstaller.State? { installer.installs[game.id]?.state }

    var body: some View {
        StoreSheetShell(store: .gog, title: game.title, subtitle: nil, close: { dismiss() }, art: { EpicArtView(url: game.art) }) {
                    actions
                    if let error = installer.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                    if let page = game.storePage { Link(destination: page) { Label("Open on GOG", systemImage: "safari") }.font(.subheadline) }
        }
            .confirm("Uninstall \(game.title)?", message: "The game's folder is removed from this device. Your GOG library and your save files in Porthole's backups are not touched.",
                     confirmTitle: "Uninstall and delete its files", destructive: true, isPresented: $confirmUninstall) { installer.uninstall(game.id) }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case nil:
            button("Install", symbol: "arrow.down.circle.fill", prominent: true) { installer.install(game) }
            note("Downloads the game straight from GOG (or GOG's setup file for older games). Keep the app open while it installs.")
        case .queued?:
            Label("Waiting for its turn\u{2026}", systemImage: "hourglass").foregroundStyle(.secondary)
            button("Cancel", symbol: "xmark") { installer.cancel(game.id) }
        case .active?:
            let progress = installer.installs[game.id]?.progress ?? SteamDownloadProgress()
            TileProgress(value: progress.fraction)
            Text(EpicText.progress(progress)).font(.footnote).foregroundStyle(.secondary)
            HStack {
                button("Pause", symbol: "pause.fill") { installer.pause(game.id) }
                button("Cancel", symbol: "xmark", role: .destructive) { installer.cancel(game.id) }
            }
        case .paused?:
            TileProgress(value: installer.installs[game.id]?.progress.fraction ?? 0)
            HStack {
                button("Resume", symbol: "play.fill", prominent: true) { installer.install(game) }
                button("Remove", symbol: "trash", role: .destructive) { installer.cancel(game.id) }
            }
        case .failed(let why)?:
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            ErrorHelpButton(message: why)
            HStack {
                button("Try again", symbol: "arrow.clockwise", prominent: true) { installer.install(game) }
                button("Remove", symbol: "trash", role: .destructive) { installer.cancel(game.id) }
            }
        case .ready?:
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            button("Run the installer", symbol: "shippingbox.fill", prominent: true) { installer.runInstaller(game.id); dismiss() }
            note("The setup runs in Porthole's Wine. When it ends, the game is added to your library by itself.")
            button("Remove the download", symbol: "trash", role: .destructive) { installer.cancel(game.id) }
        case .running?:
            Label("Installing\u{2026}", systemImage: "gearshape.fill").foregroundStyle(.secondary)
            note("The setup is running. When it ends, the game is added to your library by itself.")
        case .installed?:
            Label("Installed. Find it in your library.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            button("Uninstall", symbol: "trash", role: .destructive) { confirmUninstall = true }
        }
    }

    private func note(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(Theme.textDim) }

    private func button(_ title: String, symbol: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        StoreSheetButton(title: title, symbol: symbol, prominent: prominent, destructive: role == .destructive, action: action)
    }
}
