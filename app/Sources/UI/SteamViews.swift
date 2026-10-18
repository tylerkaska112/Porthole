// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The Steam section: sign in, then browse your owned games and download them into the library.
struct SteamScreen: View {
    @ObservedObject var store = SteamStore.shared

    var body: some View {
        if store.signedIn { SteamOwnedList(store: store) }
        else {
            VStack(alignment: .leading, spacing: 0) {
                StoreSwitcher().padding(.horizontal, 24).padding(.top, 10)
                SteamSignInScreen()
            }
        }
    }
}

// MARK: Sign in

struct SteamSignInScreen: View {
    @ObservedObject private var model = SteamSignInModel.shared
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    /// The QR code is the first choice: Steam's own mobile app approves the sign-in and this app never handles the password.
    @State private var useQR = true

    var body: some View {
        FocusScroll {
            PageScaffold(title: "Sign in to Steam", symbol: "person.badge.key.fill") {
                if useQR { qrPanel } else { passwordPanel }
                if let error = model.signInError { Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                SettingsGroup {
                    ActionRow(id: "ss-qr", symbol: useQR ? "keyboard" : "qrcode", title: useQR ? "Use my account name and password instead" : "Sign in with a QR code instead", chevron: false) {
                        model.cancelSignIn(); useQR.toggle()
                        if useQR { model.beginQR() }
                    }
                }
                Text("A QR code signs in without this app ever seeing your password. If you type your password instead, it is encrypted before it leaves the device and is never saved. Only a sign-in token is kept, in this device's Keychain. Porthole is unofficial and is not affiliated with or endorsed by Valve.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .onAppear { if useQR, model.qrImage == nil, !model.signInBusy { model.beginQR() } }
        .onDisappear { model.cancelSignIn() }
    }

    private var passwordPanel: some View {
        SettingsGroup {
            if let prompt = model.guardPrompt {
                if let type = prompt.codeType {
                    Text(type == .device ? "Enter the code from the Steam mobile app." : "Enter the code Steam emailed you\(prompt.hint.isEmpty ? "" : " (\(prompt.hint))").")
                        .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                    TextFieldRow(id: "ss-code", symbol: "shield.fill", title: "Steam Guard code", placeholder: "Code", text: $code)
                    ActionRow(id: "ss-submit", symbol: "checkmark", title: "Submit code", chevron: false) { if !code.isEmpty { model.submitGuardCode(code) } }
                }
                if prompt.canApprove {
                    Text("You can also approve this sign-in in the Steam mobile app; this screen continues by itself.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
                if model.signInBusy { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            } else {
                TextFieldRow(id: "ss-account", symbol: "person.fill", title: "Account name", placeholder: "Steam account name", text: $account)
                TextFieldRow(id: "ss-password", symbol: "lock.fill", title: "Password", placeholder: "Password", secure: true, text: $password)
                ActionRow(id: "ss-go", symbol: "arrow.right.circle.fill", title: model.signInBusy ? "Signing in\u{2026}" : "Sign in", chevron: false) {
                    if !account.isEmpty && !password.isEmpty && !model.signInBusy { model.signIn(account: account, password: password) }
                }
            }
        }
    }

    private var qrPanel: some View {
        VStack(spacing: 12) {
            if let image = model.qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                Text("Open the Steam mobile app, choose Sign in with QR code and scan this.").font(.footnote).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            } else { ProgressView().tint(Theme.accent).frame(height: 220) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Owned games

struct SteamOwnedList: View {
    @ObservedObject var store: SteamStore
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var filter = "all"            // all, installed, controller
    @ObservedObject private var controllers = SteamControllers.shared
    @ObservedObject private var network = NetworkStatus.shared
    @State private var notice: String?
    @State private var clientInstalled = MadeiraDock.clientInstalled
    @State private var clientBusy = false
    @State private var clientStatus: String?
    @State private var controllerLayer = SteamSDL3.installed
    @State private var controllerBusy = false
    @State private var controllerStatus: String?
    @State private var removing: SteamStore.Owned?
    @State private var open: SteamStore.Owned?
    @Environment(AppRouter.self) private var router
    @State private var selecting = false
    @State private var selected = Set<Int>()
    @ObservedObject private var compat = CompatStore.shared
    @Environment(\.focusScope) private var scope

    @AppStorage(StoreSort.key) private var sortRaw = StoreSort.name.rawValue
    @State private var showSort = false
    @State private var showFriends = false
    @State private var friendsScope = FocusScope()
    @State private var sortScope = FocusScope()
    private var sort: StoreSort { StoreSort(rawValue: sortRaw) ?? .name }

    private var shown: [SteamStore.Owned] {
        let list = store.owned.filter { g in
            (filter != "installed" || store.isInstalled(g.id) || store.downloads[g.id] != nil) &&
            (filter != "controller" || controllers.level(for: g.id) != nil) &&
            (search.isEmpty || g.name.localizedCaseInsensitiveContains(search))
        }
        switch sort {
        case .name: return list                         // the library arrives sorted by name
        case .recent:
            let played = Dictionary(model.games.compactMap { g -> (Int, Date)? in
                guard let id = g.steamAppID ?? g.dockAppID, let at = g.lastPlayed else { return nil }
                return (id, at)
            }, uniquingKeysWith: max)
            return list.enumerated().sorted { a, b in
                let x = played[a.element.id], y = played[b.element.id]
                if x != y { return (x ?? .distantPast) > (y ?? .distantPast) }
                return a.offset < b.offset
            }.map(\.element)
        case .installed:
            return list.enumerated().sorted { a, b in
                let x = store.isInstalled(a.element.id), y = store.isInstalled(b.element.id)
                if x != y { return x }
                return a.offset < b.offset
            }.map(\.element)
        case .size:
            return list.enumerated().sorted { a, b in
                if a.element.sizeBytes != b.element.sizeBytes { return a.element.sizeBytes > b.element.sizeBytes }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    var body: some View {
        // The list stays alive under the game's page, so coming back keeps the scroll position and the pictures instead of rebuilding everything.
        ZStack {
            list
                .opacity(open == nil ? 1 : 0)
                .allowsHitTesting(open == nil)
                .accessibilityHidden(open != nil)
                .focusSuspended(open != nil)
            if let game = open {
                SteamGamePage(game: store.owned.first { $0.id == game.id } ?? game, store: store) {
                    open = nil
                    scope?.focused = "sg-\(game.id)"
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Picking several to download

    private func needsDownload(_ g: SteamStore.Owned) -> Bool { store.downloads[g.id] == nil && (!store.isInstalled(g.id) || store.updateAvailable(g)) }
    private var selectedGames: [SteamStore.Owned] { store.owned.filter { selected.contains($0.id) && needsDownload($0) } }
    private func toggle(_ g: SteamStore.Owned) {
        guard needsDownload(g) else { return }
        if selected.contains(g.id) { selected.remove(g.id) } else { selected.insert(g.id) }
    }

    private func downloadSelected() {
        let games = selectedGames
        var free = SteamGameTile.freeSpace() ?? Int64.max
        free = free == Int64.max ? free : free - 500_000_000
        var used: Int64 = 0, queued = 0, skipped = 0
        for g in games {
            let need = Int64(Double(g.sizeBytes) * 1.15)
            if used + need <= free { store.install(g.id); used += need; queued += 1 } else { skipped += 1 }
        }
        notice = skipped > 0 ? "Queued \(queued) of \(games.count). The other \(skipped) need more free space than the device has left." : nil
        selecting = false; selected = []
        if queued > 0 { router.openDownloads() }
    }

    private var selectionBar: some View {
        let games = selectedGames
        let total = games.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        return VStack(spacing: 8) {
            if let free = SteamGameTile.freeSpace(), total > 0 {
                Text("\(games.count) selected \u{00B7} \(SteamGameTile.size(total)) to download \u{00B7} \(SteamGameTile.size(UInt64(max(free, 0)))) free")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Int64(Double(total) * 1.15) + 500_000_000 > free ? Theme.warn : Theme.textDim)
            }
            HStack(spacing: 10) {
                PillButton(id: "sel-all", title: "Select all", symbol: "checkmark.circle") { selected = Set(shown.filter(needsDownload).map(\.id)) }
                PillButton(id: "sel-clear", title: "Clear", symbol: "circle", enabled: !selected.isEmpty) { selected = [] }
                PillButton(id: "sel-go", title: games.isEmpty ? "Download" : "Download \(games.count)", symbol: "arrow.down.circle.fill", style: .primary, enabled: !games.isEmpty) { downloadSelected() }
                PillButton(id: "sel-done", title: "Done", symbol: "xmark") { selecting = false; selected = [] }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.panel.opacity(0.95))
    }

    private var list: some View {
        VStack(spacing: 0) {
            listScroll
            if selecting { selectionBar }
        }
    }

    private var listScroll: some View {
        let shown = self.shown          // once per redraw
        return FocusScroll {
            VStack(alignment: .leading, spacing: 18) {
                if !clientInstalled {
                    ActionRow(id: "so-client", symbol: "shield.lefthalf.filled", tint: Theme.warn, title: "Steam client", subtitle: clientBusy ? (clientStatus ?? "Working\u{2026}") : "Needed to start Steam games",
                              detail: clientBusy ? nil : "Download", info: "Valve's own client files start your Steam games and check your licence. About 73 MB from Valve; nothing else is installed.", chevron: false) {
                        if !clientBusy { downloadClient() }
                    }
                } else if SteamSDL3.steamPresent {
                    ActionRow(id: "so-controller", symbol: "gamecontroller.fill", tint: controllerLayer ? Theme.good : Theme.warn, title: "Steam controller support",
                              subtitle: controllerBusy ? (controllerStatus ?? "Working\u{2026}") : (controllerStatus ?? (controllerLayer ? "Installed" : "Needed by games that take their controller from Steam, like Portal")),
                              detail: controllerBusy ? nil : (controllerLayer ? "Remove" : "Download"),
                              info: "Steam's own controller layer (Steam Input) needs a 64-bit library the Steam client files do not include. This downloads that one file, about 1.3 MB, from Valve's server and checks it against its known fingerprint before using it; nothing else is installed. Games such as Portal and Portal 2 read their controller through Steam Input. Remove puts the original file back.",
                              chevron: false) {
                        if !controllerBusy { toggleControllerLayer() }
                    }
                }
                FlowLayout(spacing: 10) {
                    StoreSwitcher()
                    if !network.isOnline { OfflineChip() }
                    if store.refreshing { ProgressView().tint(Theme.accent).frame(width: 44, height: 44) }
                    else { IconPillButton(id: "so-refresh", symbol: "arrow.clockwise", label: "Refresh the list") { Task { await store.refresh() } } }
                    searchField
                    SegmentedPills(options: [.init(id: "all", title: "All"), .init(id: "installed", title: "Installed"), .init(id: "controller", title: "Controller")], selection: filter) { filter = $0 }
                    IconPillButton(id: "so-friends", symbol: "person.2.fill", label: "Friends") { showFriends = true }
                    IconPillButton(id: "so-sort", symbol: "arrow.up.arrow.down", label: "Sort: \(sort.title)") { showSort = true }
                    IconPillButton(id: "so-f-select", symbol: "checkmark.circle", label: selecting ? "Stop selecting" : "Select several to download", on: selecting) { selecting.toggle(); if !selecting { selected = [] } }
                }
                if let error = store.error, network.isOnline { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
                if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.warn) }
                if shown.isEmpty && !store.refreshing {
                    Text(store.owned.isEmpty ? "No installable Windows games found on this account yet."
                         : filter == "controller" && !store.owned.allSatisfy({ controllers.isKnown($0.id) }) ? "Asking Steam which games work with a controller\u{2026}" : "No games match.").foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
                }
                // Lazy: only the tiles on (and just off) the screen exist, so a library of hundreds scrolls and updates without the rest being redrawn.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                    ForEach(shown) { game in SteamGameTile(store: store, game: game, notice: $notice, selecting: selecting, selected: selected.contains(game.id), selectable: needsDownload(game),
                                                  open: { if selecting { toggle(game) } else { open = game } }) { removing = game } }
                }
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 18)
            .frame(maxWidth: 1400).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showFriends) {
            GameSubSheet(title: "Friends", scope: friendsScope, close: { showFriends = false }) { SteamFriendsList() }.preferredColorScheme(Theme.scheme)
        }
        .sheet(isPresented: $showSort) {
            ChoiceSheet(title: "Sort by", options: StoreSort.options(includingSize: true), selected: sort, scope: sortScope) { value in
                if let value { sortRaw = value.rawValue }
                showSort = false
            }
        }
        .task { if store.owned.isEmpty { await store.refresh(interactive: false) } }
        // Whenever the list of games arrives or changes (not only when this screen first appears), ask for their badges.
        .task(id: store.owned.map(\.id)) { await compat.refreshSteamBadges(ids: store.owned.map(\.id)) }
        .task(id: store.owned.map(\.id)) { await controllers.refresh(ids: store.owned.map(\.id)) }
        .confirm("Remove \(removing?.name ?? "")?", message: "This deletes the game's files from the device. You can download it again.", confirmTitle: "Delete files", destructive: true,
                 isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let game = removing { store.uninstall(game); for g in model.games where g.steamAppID == game.id { model.remove(g) } }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
            TextField("Search \(store.owned.count) games", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14).frame(minWidth: 200, minHeight: 40)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .focusTarget("so-search", radius: 20, scale: 1.02, action: {})
    }

    private func toggleControllerLayer() {
        controllerBusy = true; controllerStatus = "Starting\u{2026}"
        Task {
            do {
                if controllerLayer { try SteamSDL3.remove() } else { try await SteamSDL3.install { text in await MainActor.run { controllerStatus = text } } }
                controllerLayer = SteamSDL3.installed
                controllerStatus = nil
            } catch { controllerStatus = error.localizedDescription }
            controllerBusy = false
        }
    }

    private func downloadClient() {
        clientBusy = true; clientStatus = "Starting\u{2026}"
        Task {
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: AppModel.prefix) { text in await MainActor.run { clientStatus = text } }
                clientInstalled = MadeiraDock.clientInstalled
                clientStatus = clientInstalled ? nil : "The download finished but the client files are not in place."
            } catch { clientStatus = error.localizedDescription }
            clientBusy = false
        }
    }
}

/// One Steam game: the picture takes the glow; A opens its page; X installs / pauses / resumes without opening it.
struct SteamGameTile: View {
    @ObservedObject var store: SteamStore
    let game: SteamStore.Owned
    @Binding var notice: String?
    var selecting = false
    var selected = false
    var selectable = true
    /// The badge of the store on the picture (the all-games page, where several stores share a grid).
    var showStore = false
    let open: () -> Void
    let remove: () -> Void
    @ObservedObject private var compat = CompatStore.shared
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var controllers = SteamControllers.shared

    private var download: SteamStore.Download? { store.downloads[game.id] }
    private var installed: Bool { store.isInstalled(game.id) }
    private var inLibrary: Bool { model.games.contains { $0.steamAppID == game.id || $0.dockAppID == game.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                    .overlay { SteamHeaderImage(appID: game.id) }
                    .overlay { if selecting && !selectable { Color.black.opacity(0.55) } }
                    .overlay(alignment: .topTrailing) {
                        if selecting && selectable {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 26, weight: .bold))
                                .foregroundStyle(selected ? Theme.accent : .white).shadow(color: .black.opacity(0.6), radius: 3).padding(8)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let badge { BadgePill(badge: badge) }
                            if compat.showBadges { CompatTileBadge(badge: compat.steamBadges[game.id], untested: compat.steamUntested.contains(game.id)) }
                        }
                        .padding(8)
                    }
                    .overlay(alignment: .bottomLeading) { if let level = controllers.level(for: game.id) { ControllerPill(level: level, compact: true).padding(8) } }
                    .overlay(alignment: .bottomTrailing) { if showStore { StoreCorner(store: .steam, size: 26).padding(8) } }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .focusTarget("sg-\(game.id)", radius: 18, scale: 1.1, secondary: selecting ? nil : primary, action: open)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                detail
            }
            .padding(.horizontal, 4)
        }
    }

    /// One badge on the picture, only when there is something to say: a download in progress, an update, or that it is installed.
    private var badge: BadgeData? {
        if let d = download {
            switch d.state {
            case .active: return BadgeData(symbol: "arrow.down.circle.fill", text: "\(Int(d.progress.fraction * 100))%", tint: Theme.accent)
            case .queued: return BadgeData(symbol: "hourglass", text: "Waiting", tint: Theme.textDim)
            case .paused: return BadgeData(symbol: "pause.circle.fill", text: "Paused", tint: Theme.warn)
            case .failed: return BadgeData(symbol: "exclamationmark.triangle.fill", text: "Failed", tint: Theme.bad)
            }
        }
        if installed {
            if store.updateAvailable(game) { return BadgeData(symbol: "arrow.triangle.2.circlepath.circle.fill", text: "Update", tint: Theme.accent) }
            return inLibrary ? BadgeData(symbol: "checkmark.circle.fill", text: "In library", tint: Theme.good) : BadgeData(symbol: "plus.circle.fill", text: "Add to library", tint: Theme.accent)
        }
        return nil
    }

    @ViewBuilder private var detail: some View {
        if let d = download {
            switch d.state {
            case .active: ProgressView(value: d.progress.fraction).tint(Theme.accent); Text(progressText(d.progress)).font(.caption2).foregroundStyle(Theme.textDim)
            case .queued: Text("Waiting\u{2026}").font(.caption).foregroundStyle(Theme.textDim)
            case .paused: ProgressView(value: d.progress.fraction).tint(Theme.textDim); Text("Paused").font(.caption).foregroundStyle(Theme.textDim)
            case .failed(let why): Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
            }
        } else if installed {
            EmptyView()          // the badge on the picture already says Installed or Update
        } else {
            Text(game.sizeBytes > 0 ? "\(Self.size(game.sizeBytes)) download" : "Size unknown").font(.caption).foregroundStyle(Theme.textDim)
        }
    }

    private func primary() {
        if let d = download {
            switch d.state {
            case .active, .queued: store.pause(game.id)
            case .paused, .failed: start()
            }
        } else if installed {
            if store.updateAvailable(game) { start() } else if !inLibrary { store.addToLibrary(game) } else { open() }
        } else { start() }
    }

    private func start() {
        notice = nil
        if game.sizeBytes > 0, let free = Self.freeSpace(), free < Int64(Double(game.sizeBytes) * 1.15) + 500_000_000 {
            notice = "Not enough free space for \(game.name): it needs about \(Self.size(game.sizeBytes)) and the device has \(Self.size(UInt64(free)))."
            return
        }
        store.install(game.id)
    }

    private func progressText(_ p: SteamDownloadProgress) -> String {
        switch p.phase {
        case .preparing: return "Preparing\u{2026}"
        case .finishing: return "Finishing\u{2026}"
        case .downloading: return "\(Self.size(p.doneBytes)) of \(Self.size(p.totalBytes))" + (p.bytesPerSecond > 0 ? " \u{00B7} \(Self.size(UInt64(p.bytesPerSecond)))/s" : "")
        }
    }

    static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    static func freeSpace() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

/// A tile's picture: from the on-disk cache after the first time, and only fetched once the tile is near the screen, so a long list fills in around where you are.
struct SteamHeaderImage: View {
    let appID: Int
    @State private var image: UIImage?
    @State private var shownID: Int?
    @State private var near = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Theme.panelHigh }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            let f = proxy.frame(in: .global)
            return f.maxY > -700 && f.minY < UIScreen.main.bounds.height + 700
        } action: { if $0 { near = true } }
        .task(id: "\(appID)-\(near)") {
            // The same tile can be reused for another game (the card at the top of Downloads): show the new game's picture, not the old one.
            if shownID != appID { image = nil; shownID = nil }
            guard near, image == nil else { return }
            image = await SteamArt.shared.header(appID: appID); shownID = appID
        }
    }
}
