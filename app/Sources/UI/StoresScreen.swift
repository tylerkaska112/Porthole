// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The Stores tab: one list of launchers (Steam, Epic Games, and whatever is added later), each opening its own library, and one page with every launcher's games
/// together, each marked with the badge of the store it comes from.
struct StoresScreen: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            switch router.storesSelection {
            case nil:
                StoresHome()
            case .all?:
                AllStoreGamesScreen()
            case .downloads?:
                AllDownloadsScreen()
            case .software?:
                SoftwareScreen()
            case .softwareItem(let id)?:
                if id == "lossless-scaling" { LosslessScalingPage() } else { SoftwareDetailScreen(id: id) }
            case .store(let store)?:
                switch store {
                case .steam: SteamScreen()
                case .epic: EpicStoreScreen()
                case .gog: GogStoreScreen()
                case .itch: ItchStoreScreen()
                case .amazon: AmazonStoreScreen()
                case .ea: EAStoreScreen()
                }
            }
        }
        // Over everything in the Stores tab (the libraries and the games' pages), except the Downloads page it opens.
        .overlay(alignment: .bottomTrailing) {
            if router.storesSelection != .downloads, router.storesSelection != .software, !router.onSoftwareItem, router.storesSelection != nil {   // not on the list of stores: its Downloads row is there, and the button sat on that row's arrow
                DownloadsButton().padding(.trailing, 20).padding(.bottom, 18).transition(.opacity)
            }
        }
        .onNavBack {
            if router.storesSelection == .downloads { router.closeDownloads(); return true }
            if router.onSoftwareItem { router.storesSelection = .software; return true }
            if router.storesSelection == .software { router.storesSelection = nil; return true }
            if router.storesSelection != nil { router.storesSelection = nil; return true }
            return false
        }
    }
}

/// The way across to another launcher or to all games, as a few round buttons. Each library puts it at the start of its own row of controls (search, filters),
/// so the space above the games is used by something instead of a bar of its own.
struct StoreSwitcher: View {
    @Environment(AppRouter.self) private var router
    @AppStorage(StoreVisibility.key) private var hiddenRaw = ""

    var body: some View {
        HStack(spacing: 6) {
            // A hidden store is not offered here, except the one this page is about.
            ForEach(GameStore.allCases.filter { store in router.storesSelection == .store(store) || !StoreVisibility.hiddenIDs(hiddenRaw).contains(store.rawValue) }) { store in
                switcher(id: "stores-go-\(store.rawValue)", selected: router.storesSelection == .store(store), label: store.title) {
                    StoreBadgeBacked(store: store, size: 24)
                } action: { router.storesSelection = .store(store) }
            }
            switcher(id: "stores-go-all", selected: router.storesSelection == .all, label: "All games") {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
            } action: { router.storesSelection = .all }
        }
    }

    private func switcher<Label: View>(id: String, selected: Bool, label: String, @ViewBuilder content: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().frame(width: 40, height: 40)
                .background(selected ? Theme.accent.opacity(0.22) : Theme.panel, in: Circle())
                .overlay(Circle().strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 20, scale: 1.1, action: action)
        .accessibilityLabel(label)
    }
}

// MARK: The list of launchers

struct StoresHome: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epicAuth = EpicAuth.shared
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @ObservedObject private var epicInstaller = EpicInstaller.shared
    @ObservedObject private var gogInstaller = GogInstaller.shared
    @ObservedObject private var itchInstaller = ItchInstaller.shared
    @ObservedObject private var amazonInstaller = AmazonInstaller.shared
    @ObservedObject private var eaInstaller = EAInstaller.shared
    @ObservedObject private var software = SoftwareStore.shared
    @Environment(\.focusScope) private var scope
    @AppStorage(StoreVisibility.key) private var hiddenRaw = ""

    /// One line for the Software card: what is installed, what has an update, or what is coming down.
    private var softwareSummary: String {
        let items = software.programs
        if items.isEmpty { return software.loading ? "Loading the list" : "Blender and other programs, downloaded when you want them" }
        let busy = items.filter { software.state($0).busy }
        if !busy.isEmpty { return "\(busy.count) downloading" }
        let installed = items.filter(software.isInstalled).count, updates = software.updates
        var parts = ["\(installed) of \(items.count) installed"]
        if updates > 0 { parts.append("\(updates) \(updates == 1 ? "update" : "updates")") }
        return parts.joined(separator: " \u{00B7} ")
    }
    private var softwareFraction: Double? {
        for item in software.items {
            switch software.state(item) {
            case .downloading(let f): return f
            case .unpacking(let f): return f
            case .verifying: return 1
            default: continue
            }
        }
        return nil
    }

    var body: some View {
        let shownStores = StoreVisibility.visible(GameStore.allCases, raw: hiddenRaw)
        let hiddenStores = StoreVisibility.hidden(GameStore.allCases, raw: hiddenRaw)
        let cards = shownStores.map { store -> StoreCardData in
            let list = StoreCatalog.entries(store)
            var fraction: Double?
            for entry in list { if case .downloading(let f) = entry.status { fraction = f; break } }
            return StoreCardData(store: store, signedIn: StoreCatalog.signedIn(store), account: StoreCatalog.account(store), games: list.count,
                                 installed: list.filter { $0.status == .installed }.count, downloading: fraction)
        }
        let signedIn = cards.filter(\.signedIn).map(\.store)
        let items = Downloads.items()
        return FocusScroll {
            StoresHubView(cards: cards, allBadges: signedIn.isEmpty ? shownStores : signedIn, totalGames: cards.reduce(0) { $0 + $1.games }, totalInstalled: cards.reduce(0) { $0 + $1.installed },
                          downloadsSummary: Downloads.summary(of: items), downloadsFraction: items.first { $0.kind == .running }.map { $0.progress.fraction },
                          softwareSummary: softwareSummary, softwareFraction: softwareFraction,
                          open: { router.storesSelection = .store($0) }, openAll: { router.storesSelection = .all }, openDownloads: { router.openDownloads() }, openSoftware: { router.storesSelection = .software },
                          hiddenStores: hiddenStores,
                          hide: { hiddenRaw = StoreVisibility.setting($0.rawValue, hidden: true, in: hiddenRaw, known: GameStore.allCases.map(\.rawValue)) },
                          showHidden: { router.openSettings(.stores) })
                .padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)      // a list that fits does not bounce: a half-dragged page left the "Stores" title cut off under the bar
        // Always starts on Steam, the first store in the list.
        .onAppear { scope?.start(at: "store-\((StoreVisibility.visible(GameStore.allCases, raw: hiddenRaw).first ?? .steam).rawValue)", force: true) }
        .task { await software.refresh() }
    }
}

// MARK: Epic Games

/// Epic's library as a page of its own: sign in, then the same grid, downloads page and game pages Steam has.
struct EpicStoreScreen: View {
    @ObservedObject private var auth = EpicAuth.shared
    @State private var signIn = false

    var body: some View {
        Group {
            if auth.signedIn { EpicOwnedList() }
            else {
                FocusScroll {
                    signedOut
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $signIn) { EpicSignInView() }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 14) {
            StoreSwitcher()
            StoreBadgeBacked(store: .epic, size: 56)
            Text("Sign in to Epic Games").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
            Text("You sign in on Epic's own page. The sign-in token stays in this device's Keychain; Porthole never sees your password. Your games that have a Windows version are listed here, and install straight from Epic's servers.")
                .font(.footnote).foregroundStyle(Theme.textDim)
            PillButton(id: "epic-signin", title: "Sign in", symbol: "person.badge.key.fill", style: .primary) { signIn = true }
        }
        .padding(.top, 12)
    }
}

// MARK: Every launcher's games

/// All stores in one grid: each game with the badge of its store, opening the same page it has in its own store.
struct AllStoreGamesScreen: View {
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @ObservedObject private var epicInstaller = EpicInstaller.shared
    @ObservedObject private var gogLibrary = GogLibrary.shared
    @State private var openGog: GogGame?
    @State private var openItch: ItchGame?
    @State private var openAmazon: AmazonGame?
    @State private var openEA: EAOwnedGame?
    @ObservedObject private var eaLibrary = EALibrary.shared
    @ObservedObject private var amazonLibrary = AmazonLibrary.shared
    @ObservedObject private var itchLibrary = ItchLibrary.shared
    @State private var search = ""
    @AppStorage("f4.filter.all") private var filter = "all"
    @AppStorage(StoreVisibility.key) private var hiddenRaw = ""
    @State private var openSteam: SteamStore.Owned?
    @State private var openEpic: EpicGame?
    @State private var notice: String?
    @ObservedObject private var compat = CompatStore.shared
    @ObservedObject private var network = NetworkStatus.shared
    @Environment(\.focusScope) private var scope
    @EnvironmentObject private var model: AppModel
    @AppStorage(StoreSort.key) private var sortRaw = StoreSort.name.rawValue
    @State private var showSort = false
    @State private var sortScope = FocusScope()
    private var sort: StoreSort { StoreSort(rawValue: sortRaw) ?? .name }

    private var entries: [StoreGameEntry] {
        let list = StoreVisibility.visible(GameStore.allCases, raw: hiddenRaw).flatMap { StoreCatalog.entries($0) }.filter { e in
            (filter == "all" || e.status == .installed || { if case .downloading = e.status { return true }; return false }()) &&
            (search.isEmpty || e.title.localizedCaseInsensitiveContains(search))
        }
        let byName: (StoreGameEntry, StoreGameEntry) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        switch sort {
        case .name: return list.sorted(by: byName)
        case .recent:
            // A game's play time is kept with the game in the library: Steam ones by app id, Epic ones by app name.
            var played: [String: Date] = [:]
            for g in model.games {
                guard let at = g.lastPlayed else { continue }
                if let id = g.steamAppID ?? g.dockAppID { played["steam:\(id)"] = max(played["steam:\(id)"] ?? .distantPast, at) }
                if let name = g.epicAppName { played["epic:\(name)"] = at }
                if let id = g.gogID { played["gog:\(id)"] = at }
                if let id = g.itchID { played["itch:\(id)"] = at }
                if let id = g.amazonID { played["amazon:\(id)"] = at }
                if let id = g.eaOfferID { played["ea:\(id)"] = at }
            }
            return list.sorted { a, b in
                let x = played["\(a.store.rawValue):\(a.key)"], y = played["\(b.store.rawValue):\(b.key)"]
                if x != y { return (x ?? .distantPast) > (y ?? .distantPast) }
                return byName(a, b)
            }
        case .installed, .size:
            return list.sorted { a, b in
                let x = a.status == .installed, y = b.status == .installed
                if x != y { return x }
                return byName(a, b)
            }
        }
    }

    private var isOpen: Bool { openSteam != nil || openEpic != nil }

    var body: some View {
        ZStack {
            grid
                .opacity(isOpen ? 0 : 1)
                .allowsHitTesting(!isOpen)
                .accessibilityHidden(isOpen)
                .focusSuspended(isOpen)
                .sheet(isPresented: $showSort) {
                    ChoiceSheet(title: "Sort by", options: StoreSort.options(includingSize: false), selected: sort == .size ? .installed : sort, scope: sortScope) { value in
                        if let value { sortRaw = value.rawValue }
                        showSort = false
                    }
                }
                // The badges of the Steam games, asked for here too (this page can be the first one opened).
                .task(id: steam.owned.map(\.id)) { await compat.refreshSteamBadges(ids: steam.owned.map(\.id)) }
                .sheet(item: $openGog) { GogGameSheet(game: $0) }
                .sheet(item: $openItch) { ItchGameSheet(game: $0) }
                .sheet(item: $openAmazon) { AmazonGameSheet(game: $0) }
                .sheet(item: $openEA) { EAGameSheet(game: $0) }
            if let game = openSteam {
                SteamGamePage(game: steam.owned.first { $0.id == game.id } ?? game, store: steam, backTitle: "All games") {
                    openSteam = nil
                    scope?.focused = "sg-\(game.id)"
                }
                .background { Theme.backgroundTop.ignoresSafeArea().allowsHitTesting(false) }
                .transition(.opacity)
            }
            if let game = openEpic {
                EpicGamePage(game: epicLibrary.games.first { $0.appName == game.appName } ?? game, backTitle: "All games") {
                    openEpic = nil
                    scope?.focused = "eg-\(game.appName)"
                }
                .background { Theme.backgroundTop.ignoresSafeArea().allowsHitTesting(false) }
                .transition(.opacity)
            }
        }
    }

    private var grid: some View {
        let list = entries            // once per redraw: building and sorting every store's list is not free
        return StorePage {
            if !network.isOnline { OfflineChip() }
            searchField
            SegmentedPills(options: [.init(id: "all", title: "All"), .init(id: "installed", title: "Installed")], selection: filter) { filter = $0 }
            IconPillButton(id: "all-sort", symbol: "arrow.up.arrow.down", label: "Sort: \(sort.title)") { showSort = true }
            Text("\(list.count) game\(list.count == 1 ? "" : "s")").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        } content: {
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.warn) }
            if StoreVisibility.visible(GameStore.allCases, raw: hiddenRaw).allSatisfy({ !StoreCatalog.signedIn($0) }) {
                Text("Sign in to a store to see its games here.").foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            } else if list.isEmpty {
                Text("No games match.").foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(list) { entry in tile(entry) }
            }
        }
    }

    @ViewBuilder private func tile(_ entry: StoreGameEntry) -> some View {
        switch entry.store {
        case .epic:
            if let game = epicLibrary.games.first(where: { $0.appName == entry.key }) {
                EpicGameTile(game: game, showStore: true) { openEpic = game }
            }
        case .itch:
            if let game = itchLibrary.games.first(where: { $0.key == entry.key }) {
                ItchGameTile(game: game, showStore: true) { openItch = game }
            }
        case .gog:
            if let game = gogLibrary.games.first(where: { $0.key == entry.key }) {
                GogGameTile(game: game, showStore: true) { openGog = game }
            }
        case .amazon:
            if let game = amazonLibrary.games.first(where: { $0.key == entry.key }) {
                AmazonGameTile(game: game, showStore: true) { openAmazon = game }
            }
        case .ea:
            if let game = eaLibrary.games.first(where: { $0.id == entry.key }) {
                EAGameTile(game: game, showStore: true) { openEA = game }
            }
        case .steam:
            if let owned = steam.owned.first(where: { String($0.id) == entry.key }) {
                SteamGameTile(store: steam, game: owned, notice: $notice, showStore: true, open: { openSteam = owned }, remove: {})
            }
        }
    }

    private var searchField: some View { SearchField(id: "all-search", prompt: "Search every store", text: $search) }
}
