// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Amazon Games in the Stores tab: sign in, then the grid of the games the account owns. A game opens a sheet with its install actions.

/// Amazon Games' library as a page of its own.
struct AmazonStoreScreen: View {
    @ObservedObject private var auth = AmazonAuth.shared
    @State private var signIn = false

    var body: some View {
        Group {
            if auth.signedIn { AmazonOwnedList() }
            else {
                FocusScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        StoreSwitcher()
                        StoreBadgeBacked(store: .amazon, size: 56)
                        Text("Sign in to Amazon Games").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        Text("You sign in on Amazon's own page. The sign-in token stays in this device's Keychain; Porthole never sees your password. The games you bought on Amazon or claimed with Prime Gaming are listed here.")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        PillButton(id: "amazon-signin", title: "Sign in", symbol: "person.badge.key.fill", style: .primary) { signIn = true }
                    }
                    .padding(.top, 12).padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $signIn) { AmazonSignInView() }
    }
}

struct AmazonGameTile: View {
    let game: AmazonGame
    var showStore = false
    let open: () -> Void
    @ObservedObject private var installer = AmazonInstaller.shared

    private var install: AmazonInstaller.Install? { installer.installs[game.id] }

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
                    .overlay(alignment: .topLeading) { if let badge { BadgePill(badge: badge).padding(8) } }
                    .overlay(alignment: .bottomTrailing) { if showStore { StoreCorner(store: .amazon, size: 26).padding(8) } }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .focusTarget("ag-\(game.id)", radius: 18, scale: 1.1, action: open)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if install?.state == .active {
                    ProgressView(value: install?.progress.fraction ?? 0).tint(Theme.accent)
                    Text(EpicText.progress(install?.progress ?? SteamDownloadProgress())).font(.caption2).foregroundStyle(Theme.textDim)
                } else if case .failed(let why)? = install?.state {
                    Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct AmazonOwnedList: View {
    @ObservedObject private var library = AmazonLibrary.shared
    @ObservedObject private var network = NetworkStatus.shared
    @State private var search = ""
    @State private var open: AmazonGame?
    @State private var showAccount = false

    private var shown: [AmazonGame] {
        search.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        FocusScroll {
            VStack(alignment: .leading, spacing: 18) {
                FlowLayout(spacing: 10) {
                    StoreSwitcher()
                    if !network.isOnline { OfflineChip() }
                    if library.isLoading { ProgressView().tint(Theme.accent).frame(width: 44, height: 44) }
                    else { IconPillButton(id: "am-refresh", symbol: "arrow.clockwise", label: "Refresh the list") { library.refresh() } }
                    searchField
                    IconPillButton(id: "am-account", symbol: "person.crop.circle", label: "Amazon account") { showAccount = true }
                }
                if let error = network.isOnline ? library.error : nil { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
                if shown.isEmpty && !library.isLoading {
                    Text(library.games.isEmpty ? "No games found on this account yet. Games from Prime Gaming show up once they are claimed." : "No games match.")
                        .foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                    ForEach(shown) { game in AmazonGameTile(game: game) { open = game } }
                }
                Text("Amazon games are downloaded straight from Amazon's servers. Some need the Amazon Games app's online services to start and may not run.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.top, 4)
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 18)
            .frame(maxWidth: 1400).frame(maxWidth: .infinity)
        }
        .sheet(item: $open) { game in AmazonGameSheet(game: game) }
        .sheet(isPresented: $showAccount) { AmazonSignInView() }
        .task { library.refreshIfStale() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
            TextField("Search \(library.games.count) game\(library.games.count == 1 ? "" : "s")", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14).frame(minWidth: 200, minHeight: 40)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .focusTarget("am-search", radius: 20, scale: 1.02, action: {})
    }
}

/// An Amazon game: its picture and name, and the install actions for its state (install, pause, uninstall).
struct AmazonGameSheet: View {
    let game: AmazonGame
    @ObservedObject private var installer = AmazonInstaller.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    private var state: AmazonInstaller.State? { installer.installs[game.id]?.state }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                        .overlay { EpicArtView(url: game.art) }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(game.title).font(.system(size: 24, weight: .heavy, design: .rounded))
                    actions
                    if let error = installer.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                }
                .padding(20)
            }
            .navigationTitle("Amazon Games").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirm("Uninstall \(game.title)?", message: "The game's folder is removed from this device. Your Amazon library and your save files in Porthole's backups are not touched.",
                     confirmTitle: "Uninstall and delete its files", destructive: true, isPresented: $confirmUninstall) { installer.uninstall(game.id) }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case nil:
            button("Install", symbol: "arrow.down.circle.fill", prominent: true) { installer.install(game) }
            note("Downloads the game straight from Amazon. Keep the app open while it installs.")
        case .queued?:
            Label("Waiting for its turn\u{2026}", systemImage: "hourglass").foregroundStyle(.secondary)
            button("Cancel", symbol: "xmark") { installer.cancel(game.id) }
        case .active?:
            let progress = installer.installs[game.id]?.progress ?? SteamDownloadProgress()
            ProgressView(value: progress.fraction)
            Text(EpicText.progress(progress)).font(.footnote).foregroundStyle(.secondary)
            HStack {
                button("Pause", symbol: "pause.fill") { installer.pause(game.id) }
                button("Cancel", symbol: "xmark", role: .destructive) { installer.cancel(game.id) }
            }
        case .paused?:
            ProgressView(value: installer.installs[game.id]?.progress.fraction ?? 0)
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
        case .installed?:
            Label("Installed. Find it in your library.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            button("Uninstall", symbol: "trash", role: .destructive) { confirmUninstall = true }
        }
    }

    private func note(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary) }

    private func button(_ title: String, symbol: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent).tint(prominent ? Theme.accent : (role == .destructive ? .red : .gray))
    }
}
