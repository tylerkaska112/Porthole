// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// itch.io in the Stores tab: sign in with an API key, then the grid of the games the account owns. A game opens a sheet with its install actions.

struct ItchStoreScreen: View {
    @ObservedObject private var auth = ItchAuth.shared
    @State private var signIn = false

    var body: some View {
        Group {
            if auth.signedIn { ItchOwnedList() }
            else {
                FocusScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        StoreSwitcher()
                        StoreBadgeBacked(store: .itch, size: 56)
                        Text("Sign in to itch.io").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        Text("itch.io lets you make a personal API key; Porthole uses it only to list the games you own or claimed and to download them. The key stays in this device's Keychain. Games you own that have a Windows download are listed here.")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        PillButton(id: "itch-signin", title: "Sign in", symbol: "key.fill", style: .primary) { signIn = true }
                    }
                    .padding(.top, 12).padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $signIn) { ItchSignInView() }
    }
}

struct ItchGameTile: View {
    let game: ItchGame
    var showStore = false
    let open: () -> Void
    @ObservedObject private var installer = ItchInstaller.shared

    private var install: ItchInstaller.Install? { installer.installs[game.id] }

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
                    .overlay { EpicArtView(url: game.cover) }
                    .overlay(alignment: .topLeading) { if let badge { TileStatus(badge: badge).padding(8) } }
                    .overlay(alignment: .bottomTrailing) { if showStore { StoreCorner(store: .itch, size: 26).padding(8) } }
                    .storeTileStyle()
            }
            .buttonStyle(TilePress())
            .focusTarget("ig-\(game.id)", radius: 18, scale: 1.1, action: open)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if install?.state == .active {
                    TileProgress(value: install?.progress.fraction ?? 0)
                    Text(EpicText.progress(install?.progress ?? SteamDownloadProgress())).font(.caption2).foregroundStyle(Theme.textDim)
                } else if case .failed(let why)? = install?.state {
                    Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
                } else if let author = game.author {
                    Text(author).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct ItchOwnedList: View {
    @ObservedObject private var library = ItchLibrary.shared
    @ObservedObject private var installer = ItchInstaller.shared
    @ObservedObject private var network = NetworkStatus.shared
    @State private var search = ""
    @State private var filter = "all"
    @State private var open: ItchGame?
    @State private var showAccount = false

    private var shown: [ItchGame] {
        library.games.filter { g in
            (filter != "installed" || installer.isInstalled(g.id) || installer.installs[g.id]?.isDownload == true) &&
            (search.isEmpty || g.title.localizedCaseInsensitiveContains(search) || (g.author?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        StorePage {
            StoreSwitcher()
            if !network.isOnline { OfflineChip() }
            if library.isLoading { ProgressView().tint(Theme.accent).frame(width: 44, height: 44) }
            else { IconPillButton(id: "io-refresh", symbol: "arrow.clockwise", label: "Refresh the list") { library.refresh() } }
            searchField
            SegmentedPills(options: [.init(id: "all", title: "All"), .init(id: "installed", title: "Installed")], selection: filter) { filter = $0 }
            IconPillButton(id: "io-account", symbol: "person.crop.circle", label: "itch.io account") { showAccount = true }
        } content: {
            if let error = network.isOnline ? (library.error ?? installer.error) : nil { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            if shown.isEmpty && !library.isLoading {
                Text(library.games.isEmpty ? "No games with a Windows download found on this account yet. Games you bought, claimed or got in a bundle show up here." : "No games match.")
                    .foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(shown) { game in ItchGameTile(game: game) { open = game } }
            }
            Text("itch.io games are plain downloads: Porthole fetches the game's Windows file, unpacks it, and finds its program. Games that are made for a web browser are not listed.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.top, 4)
        }
        .sheet(item: $open) { game in ItchGameSheet(game: game) }
        .sheet(isPresented: $showAccount) { ItchSignInView() }
        .task { library.refreshIfStale() }
    }

    private var searchField: some View { SearchField(id: "io-search", prompt: "Search \(library.games.count) game\(library.games.count == 1 ? "" : "s")", text: $search) }
}

/// An itch.io game: its picture and name, which download to use, and the install actions for its state.
struct ItchGameSheet: View {
    let game: ItchGame
    @ObservedObject private var installer = ItchInstaller.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false
    @State private var uploads: [ItchUpload]?
    @State private var chosen: Int?

    private var state: ItchInstaller.State? { installer.installs[game.id]?.state }

    var body: some View {
        StoreSheetShell(store: .itch, title: game.title, subtitle: game.author.map { "by \($0)" }, close: { dismiss() }, art: { EpicArtView(url: game.cover) }) {
                    if let summary = game.summary, !summary.isEmpty { Text(summary).font(.footnote).foregroundStyle(.secondary) }
                    actions
                    if let error = installer.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                    if let page = game.page { Link(destination: page) { Label("Open on itch.io", systemImage: "safari") }.font(.subheadline) }
        }
            .confirm("Uninstall \(game.title)?", message: "The game's folder is removed from this device. Your itch.io library is not touched.",
                     confirmTitle: "Uninstall and delete its files", destructive: true, isPresented: $confirmUninstall) { installer.uninstall(game.id) }
            .task { if state == nil, uploads == nil { uploads = await installer.uploads(for: game) } }
        .presentationDetents([.medium, .large])
    }

    private var selectedUpload: ItchUpload? { uploads?.first { $0.id == chosen } ?? uploads?.first }

    @ViewBuilder private var actions: some View {
        switch state {
        case nil:
            if let uploads, uploads.isEmpty {
                Label("No Windows download found for this game.", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            } else if let uploads, let upload = selectedUpload {
                if uploads.count > 1 {
                    Menu {
                        ForEach(uploads) { u in
                            Button { chosen = u.id } label: { Text("\(u.title) \u{00B7} \(EpicText.size(u.size))") }
                        }
                    } label: {
                        Label("\(upload.title) \u{00B7} \(EpicText.size(upload.size))", systemImage: "square.stack.3d.down.right").font(.subheadline)
                    }
                } else {
                    Label("\(upload.title) \u{00B7} \(EpicText.size(upload.size))", systemImage: "doc.zipper").font(.subheadline).foregroundStyle(.secondary)
                }
                button("Install", symbol: "arrow.down.circle.fill", prominent: true) { installer.install(game, uploadID: upload.id) }
                note("Downloads the game's Windows file from itch.io and unpacks it. Keep the app open while it installs.")
            } else {
                HStack { ProgressView(); Text("Looking up the download\u{2026}").font(.footnote).foregroundStyle(.secondary) }
            }
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
            HStack {
                button("Try again", symbol: "arrow.clockwise", prominent: true) { installer.install(game) }
                button("Remove", symbol: "trash", role: .destructive) { installer.cancel(game.id) }
            }
        case .ready?:
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            button("Run the installer", symbol: "shippingbox.fill", prominent: true) { installer.runInstaller(game.id); dismiss() }
            note("This game comes with an installer. It runs in Porthole's Wine; follow its steps, and when it ends the game is added to your library.")
            button("Remove the download", symbol: "trash", role: .destructive) { installer.cancel(game.id) }
        case .running?:
            Label("Installing\u{2026}", systemImage: "gearshape.fill").foregroundStyle(.secondary)
            note("The installer is running. When it ends, the game is added to your library by itself.")
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
