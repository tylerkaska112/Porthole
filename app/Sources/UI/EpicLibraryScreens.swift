// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import CryptoKit

// Epic Games in the Stores tab, laid out like Steam's: a grid of pictures with a badge for what each is doing, a Downloads page with the queue, and a page for each game.

// MARK: Pictures

/// Epic's pictures, kept on disk after the first time so a grid fills in at once the next time.
actor EpicArt {
    static let shared = EpicArt()
    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20; c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("epic-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func image(_ url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = Self.cacheDir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { memory.setObject(image, forKey: url as NSURL); return image }
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        memory.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A picture that is only fetched once it is near the screen (a long grid fills in around where you are).
struct EpicArtView: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var shown: URL?
    @State private var near = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Theme.panelHigh }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            let f = proxy.frame(in: .global)
            return f.maxY > -700 && f.minY < UIScreen.main.bounds.height + 700
        } action: { if $0 { near = true } }
        .task(id: "\(url?.absoluteString ?? "")-\(near)") {
            if shown != url { image = nil; shown = nil }
            guard near, image == nil, let url else { return }
            image = await EpicArt.shared.image(url); shown = url
        }
    }
}

// MARK: Shared text

enum EpicText {
    static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    static func progress(_ p: SteamDownloadProgress) -> String {
        switch p.phase {
        case .preparing: return "Preparing\u{2026}"
        case .finishing: return "Finishing\u{2026}"
        case .downloading:
            guard p.totalBytes > 0 else { return "Preparing\u{2026}" }
            return "\(size(p.doneBytes)) of \(size(p.totalBytes))" + (p.bytesPerSecond > 0 ? " \u{00B7} \(size(UInt64(p.bytesPerSecond)))/s" : "")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "under a minute" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

// MARK: The grid

/// One Epic game: the picture takes the glow; A opens its page; X installs / pauses / resumes without opening it.
struct EpicGameTile: View {
    let game: EpicGame
    /// The badge of the store on the picture (the all-games page, where several stores share a grid).
    var showStore = false
    let open: () -> Void
    @ObservedObject private var installer = EpicInstaller.shared
    @ObservedObject private var compat = CompatStore.shared

    private var install: EpicInstaller.Install? { installer.installs[game.appName] }
    /// The game as the app knows it once installed: reports are about that program.
    private var entry: Game? { installer.entry(game.appName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                    .overlay { EpicArtView(url: game.heroURL ?? game.artworkURL) }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let badge { TileStatus(badge: badge) }
                            if let entry, compat.showBadges { CompatTileBadge(badge: compat.badges[entry.id], untested: compat.isUntested(entry)) }
                        }
                        .padding(8)
                    }
                    .overlay(alignment: .bottomTrailing) { if showStore { StoreCorner(store: .epic, size: 26).padding(8) } }
                    .storeTileStyle()
            }
            .buttonStyle(TilePress())
            .focusTarget("eg-\(game.appName)", radius: 18, scale: 1.1, secondary: primary, label: "Details", secondaryLabel: primaryLabel, action: open)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                detail
            }
            .padding(.horizontal, 4)
        }
    }

    private var badge: BadgeData? {
        switch install?.state {
        case .active?: return BadgeData(symbol: "arrow.down.circle.fill", text: "\(Int((install?.progress.fraction ?? 0) * 100))%", tint: Theme.accent)
        case .queued?: return BadgeData(symbol: "hourglass", text: "Waiting", tint: Theme.textDim)
        case .paused?: return BadgeData(symbol: "pause.circle.fill", text: "Paused", tint: Theme.warn)
        case .failed?: return BadgeData(symbol: "exclamationmark.triangle.fill", text: "Failed", tint: Theme.bad)
        case .installed?:
            if installer.updateAvailable(game.appName) { return BadgeData(symbol: "arrow.triangle.2.circlepath.circle.fill", text: "Update", tint: Theme.accent) }
            return BadgeData(symbol: "checkmark.circle.fill", text: "Installed", tint: Theme.good)
        case nil: return nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch install?.state {
        case .active?:
            TileProgress(value: install?.progress.fraction ?? 0)
            Text(EpicText.progress(install?.progress ?? SteamDownloadProgress())).font(.caption2).foregroundStyle(Theme.textDim)
        case .queued?: Text("Waiting\u{2026}").font(.caption).foregroundStyle(Theme.textDim)
        case .paused?:
            TileProgress(value: install?.progress.fraction ?? 0, paused: true)
            Text("Paused").font(.caption).foregroundStyle(Theme.textDim)
        case .failed(let why)?: Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
        case .installed?: EmptyView()
        case nil: Text(game.developer ?? "Not installed").font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
        }
    }

    /// What X does on this tile, for the hints bar (the same cases as `primary`).
    private var primaryLabel: String {
        switch install?.state {
        case .active?, .queued?: return "Pause"
        case .paused?, .failed?: return "Resume"
        case nil: return "Install"
        case .installed?: return installer.updateAvailable(game.appName) ? "Update" : "Open"
        }
    }

    private func primary() {
        switch install?.state {
        case .active?, .queued?: installer.pause(game.appName)
        case .paused?, .failed?, nil: installer.install(game)
        case .installed?: if installer.updateAvailable(game.appName) { installer.update(game) } else { open() }
        }
    }
}

/// Epic's library once signed in: search, a filter, the Downloads page, and a grid of games; each game opens its own page.
struct EpicOwnedList: View {
    @ObservedObject private var library = EpicLibrary.shared
    @ObservedObject private var installer = EpicInstaller.shared
    @State private var search = ""
    @State private var filter = "all"
    @State private var open: EpicGame?
    @ObservedObject private var network = NetworkStatus.shared
    @Environment(\.focusScope) private var scope
    @EnvironmentObject private var model: AppModel
    @AppStorage(StoreSort.key) private var sortRaw = StoreSort.name.rawValue
    @State private var showSort = false
    @State private var sortScope = FocusScope()
    private var sort: StoreSort { StoreSort(rawValue: sortRaw) == .size ? .name : (StoreSort(rawValue: sortRaw) ?? .name) }

    private var shown: [EpicGame] {
        let list = library.games.filter { g in
            (filter != "installed" || installer.installs[g.appName]?.state == .installed || installer.isDownloading(g.appName)) &&
            (search.isEmpty || g.title.localizedCaseInsensitiveContains(search))
        }          // the library arrives sorted by title already
        switch sort {
        case .name, .size: return list
        case .recent:
            let played = Dictionary(model.games.compactMap { g -> (String, Date)? in
                guard let name = g.epicAppName, let at = g.lastPlayed else { return nil }
                return (name, at)
            }, uniquingKeysWith: max)
            return list.enumerated().sorted { a, b in
                let x = played[a.element.appName], y = played[b.element.appName]
                if x != y { return (x ?? .distantPast) > (y ?? .distantPast) }
                return a.offset < b.offset
            }.map(\.element)
        case .installed:
            return list.enumerated().sorted { a, b in
                let x = installer.installs[a.element.appName]?.state == .installed, y = installer.installs[b.element.appName]?.state == .installed
                if x != y { return x }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    var body: some View {
        // The grid stays alive under the page, so coming back keeps the scroll position and the pictures.
        ZStack {
            grid
                .opacity(open == nil ? 1 : 0)
                .allowsHitTesting(open == nil)
                .accessibilityHidden(open != nil)
                .focusSuspended(open != nil)
            if let game = open {
                EpicGamePage(game: library.games.first { $0.appName == game.appName } ?? game) {
                    open = nil
                    scope?.focused = "eg-\(game.appName)"
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSort) {
            ChoiceSheet(title: "Sort by", options: StoreSort.options(includingSize: false), selected: sort, scope: sortScope) { value in
                if let value { sortRaw = value.rawValue }
                showSort = false
            }
        }
        .task { library.refreshIfStale() }
    }

    private var grid: some View {
        let games = shown
        return StorePage {
            StoreSwitcher()
            if !network.isOnline { OfflineChip() }
            if library.isLoading { ProgressView().tint(Theme.accent).frame(width: 44, height: 44) }
            else { IconPillButton(id: "eo-refresh", symbol: "arrow.clockwise", label: "Refresh the list") { library.refresh() } }
            searchField
            SegmentedPills(options: [.init(id: "all", title: "All"), .init(id: "installed", title: "Installed")], selection: filter) { filter = $0 }
            IconPillButton(id: "eo-sort", symbol: "arrow.up.arrow.down", label: "Sort: \(sort.title)") { showSort = true }
        } content: {
            if let error = installer.error ?? (network.isOnline ? library.error : nil) { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            if games.isEmpty && !library.isLoading {
                Text(library.games.isEmpty ? "No games with a Windows version found on this account yet." : "No games match.")
                    .foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(games) { game in EpicGameTile(game: game) { open = game } }
            }
            Text("Epic's overlay, anti-cheat and third-party launchers are not supported, so some games will not run.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.top, 4)
        }
    }

    private var searchField: some View { SearchField(id: "eo-search", prompt: "Search \(library.games.count) games", text: $search) }
}

// MARK: A game's page

/// Porthole's own page for an Epic game, installed or not: its picture and screenshots, what Epic says about it, how it runs here, and the buttons.
struct EpicGamePage: View {
    let game: EpicGame
    var backTitle = "Epic Games"
    let back: () -> Void
    @ObservedObject private var installer = EpicInstaller.shared
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionController
    @Environment(AppRouter.self) private var router
    @Environment(\.verticalSizeClass) private var vSize
    @ObservedObject private var compat = CompatStore.shared

    @State private var viewing: Int?
    @State private var reading: SteamGamePage.Reading?
    @State private var showReports = false
    @State private var door: Door?
    @State private var doorScope = FocusScope()
    @State private var writing: Game?
    @State private var confirmRemove = false
    @State private var viewerScope = FocusScope()
    @State private var readerScope = FocusScope()
    @State private var reportsScope = FocusScope()

    enum Door: String, Identifiable {
        case details
        var id: String { rawValue }
        var title: String { "Details and files" }
    }

    private var install: EpicInstaller.Install? { installer.installs[game.appName] }
    private var isInstalled: Bool { install?.state == .installed }
    private var libraryGame: Game? { installer.entry(game.appName) }
    private var media: [SteamStorePage.Media] {
        (game.screenshots ?? []).map { SteamStorePage.Media(id: $0.absoluteString, title: nil, thumb: $0, full: $0, isVideo: false) }
    }
    private struct ViewerIndex: Identifiable { let index: Int; var id: Int { index } }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height * 1.05
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        FocusScroll { hero(back: true).padding(.horizontal, 20).padding(.vertical, vSize == .compact ? 8 : 14) }
                            .frame(width: min(vSize == .compact ? 340 : 420, geo.size.width * 0.42))
                        FocusScroll {
                            VStack(alignment: .leading, spacing: 20) { pageContent }
                                .padding(.horizontal, 20).padding(.vertical, vSize == .compact ? 8 : 14)
                                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { PillButton(id: "ep-back", title: backTitle, symbol: "chevron.left", action: back); Spacer() }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 6)
                        FocusScroll {
                            VStack(alignment: .leading, spacing: 20) {
                                hero(back: false)
                                pageContent
                            }
                            .padding(.horizontal, 24).padding(.bottom, 30)
                            .frame(maxWidth: 900).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .onNavBack { back(); return true }
        .task { if let entry = libraryGame { await compat.ensureFingerprint(for: entry) } }
        .fullScreenCover(item: Binding(get: { viewing.map(ViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            MediaViewer(items: media, start: start.index, scope: viewerScope) { viewing = nil }
        }
        .sheet(item: $door) { d in
            GameSubSheet(title: d.title, scope: doorScope, close: { door = nil }) { details; files }
                .environmentObject(model)
        }
        .sheet(item: $reading) { r in TextReaderSheet(title: r.title, text: r.text, scope: readerScope) { reading = nil } }
        .sheet(isPresented: $showReports) {
            if let entry = libraryGame {
                CompatGameSheet(gameID: compat.candidateIDs(for: entry).first ?? "none", title: game.title, game: entry, scope: reportsScope) { showReports = false }.environmentObject(model)
            }
        }
        .sheet(item: $writing) { ReportSheet(game: $0).environmentObject(model).preferredColorScheme(Theme.scheme) }
        .confirm("Delete \(game.title)'s files?", message: "This frees the space on the device, including saves kept in the game's folder. You can download it again.", confirmTitle: "Delete files",
                 destructive: true, isPresented: $confirmRemove) { installer.uninstall(game.appName) }
    }

    // MARK: Pieces

    /// The game's picture softened and darkened behind the whole page. A picture only: it reaches up under the top bar, so it must not take the taps meant for the sections there.
    private var backdrop: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            Color.clear
                .overlay { EpicArtView(url: game.heroURL ?? game.artworkURL) }
                .blur(radius: 8).scaleEffect(1.08).clipped()
                .overlay { Color.black.opacity(0.4) }
                .overlay { LinearGradient(colors: [.clear, Theme.backgroundBottom.opacity(0.55), Theme.backgroundBottom.opacity(0.92)], startPoint: .top, endPoint: .bottom) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func hero(back showBack: Bool) -> some View {
        StoreHero(name: game.title, subtitle: game.developer, stats: statTiles, back: showBack ? back : nil, backTitle: backTitle, compact: vSize == .compact) {
            EpicArtView(url: game.heroURL ?? game.artworkURL)
        } chips: { chipsContent } actions: { actions }
    }

    /// What Epic says about the game: the screenshots, the description and the rows that open the rest.
    @ViewBuilder private var pageContent: some View {
        if !media.isEmpty { mediaStrip }
        about
        doors
    }

    /// What Epic tells us before Install: where the game stands on this device, who made it, and which build is current.
    private var statTiles: [GameHeroStat] {
        var out: [GameHeroStat] = []
        let status = !isInstalled ? "Not installed" : (installer.updateAvailable(game.appName) ? "Update ready" : "Installed")
        out.append(GameHeroStat(symbol: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle", title: "On this device", value: status))
        if let developer = game.developer, !developer.isEmpty { out.append(GameHeroStat(symbol: "person.fill", title: "Developer", value: developer)) }
        if let build = game.latestBuild, !build.isEmpty, build.count <= 14 { out.append(GameHeroStat(symbol: "number", title: "Build", value: build)) }
        return out
    }

    @ViewBuilder private var chipsContent: some View {
                StoreChip(store: .epic)
                compatPill
                if isInstalled {
                    if installer.updateAvailable(game.appName) { chip("arrow.triangle.2.circlepath.circle.fill", "Update available", Theme.accent) }
                    else { chip("checkmark.circle.fill", "Installed", Theme.good) }
                }
    }

    @ViewBuilder private var compatPill: some View {
        if let entry = libraryGame {
            if compat.showBadges, let verdict = compat.badges[entry.id]?.verdict { BadgePill(badge: BadgeData(symbol: verdict.symbol, text: verdict.title, tint: verdict.color)) }
            else if compat.showBadges, let past = compat.badges[entry.id]?.past { BadgePill(badge: BadgeData(symbol: past.symbol, text: past.text, tint: past.color)) }
            else if compat.showBadges, compat.isUntested(entry) { BadgePill(badge: BadgeData(symbol: "questionmark.circle.fill", text: "Not yet tested", tint: Theme.textDim)) }
        }
    }

    private func chip(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 12, weight: .bold)); Text(text).font(.system(size: 13, weight: .semibold)) }
            .foregroundStyle(tint).padding(.horizontal, 12).padding(.vertical, 7).background(tint.opacity(0.15), in: Capsule())
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 10) {
                switch install?.state {
                case .active?, .queued?:
                    PillButton(id: "ep-main", title: "Pause", symbol: "pause.fill", style: .primary) { installer.pause(game.appName) }
                    PillButton(id: "ep-cancel", title: "Cancel", symbol: "xmark") { installer.cancel(game.appName) }
                case .paused?, .failed?:
                    PillButton(id: "ep-main", title: install?.state == .paused ? "Resume" : "Try again", symbol: "play.fill", style: .primary) { installer.install(game) }
                    PillButton(id: "ep-cancel", title: "Cancel", symbol: "xmark") { installer.cancel(game.appName) }
                case .installed?:
                    if installer.updateAvailable(game.appName) {
                        PillButton(id: "ep-update", title: "Update", symbol: "arrow.triangle.2.circlepath", style: .primary) { installer.update(game) }
                    }
                    if let libraryGame {
                        PillButton(id: "ep-play", title: session.isActive ? "Busy" : "Play", symbol: "play.fill", style: installer.updateAvailable(game.appName) ? .glass : .primary, enabled: !session.isActive) { session.start(libraryGame) }
                        PillButton(id: "ep-open", title: "Game settings", symbol: "slider.horizontal.3") { router.tab = .library; router.homePath.append(libraryGame.id) }
                    }
                case nil:
                    PillButton(id: "ep-main", title: "Install", symbol: "arrow.down.circle.fill", style: .primary) { installer.install(game) }
                }
            }
            switch install?.state {
            case .active?:
                TileProgress(value: install?.progress.fraction ?? 0)
                Text(EpicText.progress(install?.progress ?? SteamDownloadProgress())).font(.caption).foregroundStyle(Theme.textDim)
            case .queued?: Text("Waiting\u{2026}").font(.caption).foregroundStyle(Theme.textDim)
            case .paused?:
                TileProgress(value: install?.progress.fraction ?? 0, paused: true)
                Text("Paused").font(.caption).foregroundStyle(Theme.textDim)
            case .failed(let why)?: Text(why).font(.caption).foregroundStyle(Theme.bad)
            default: EmptyView()
            }
            if let error = installer.error { Text(error).font(.footnote).foregroundStyle(Theme.warn) }
        }
    }

    private var mediaStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.label("Screenshots").padding(.horizontal, 6)
            FocusScroll(axes: .horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(media.enumerated()), id: \.element.id) { i, item in
                        Button { viewing = i } label: {
                            Color.clear.frame(width: 260, height: 146)
                                .overlay { EpicArtView(url: item.thumb) }
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        }
                        .buttonStyle(TilePress())
                        .focusTarget("ep-media-\(i)", radius: 14, scale: 1.06) { viewing = i }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder private var about: some View {
        if let summary = game.summary, !summary.isEmpty {
            SettingsGroup(title: "About this game") {
                Text(String(summary.prefix(400)) + (summary.count > 400 ? "\u{2026}" : ""))
                    .font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .focusTarget("ep-about", radius: 16, scale: 1.01, action: {})
                if summary.count > 400 {
                    ActionRow(id: "ep-more", symbol: "text.alignleft", title: "Read the full description", chevron: true) { reading = .init(title: game.title, text: summary) }
                }
            }
        }
    }

    private var doors: some View {
        SettingsGroup {
            if libraryGame != nil {
                ActionRow(id: "ep-door-compat", symbol: "checkmark.seal.fill", title: "How it runs on Porthole", subtitle: compatSummary) { showReports = true }
            }
            ActionRow(id: "ep-door-details", symbol: "info.circle.fill", title: "Details and files", subtitle: isInstalled ? "Version, delete files" : "About this game") { door = .details }
        }
    }

    private var compatSummary: String {
        guard let entry = libraryGame else { return "Not yet tested" }
        if let v = compat.badges[entry.id]?.verdict { return v.title }
        if let p = compat.badges[entry.id]?.past { return p.text }
        return "Not yet tested"
    }

    private var details: some View {
        SettingsGroup(title: "Details") {
            ValueRow(id: "ep-d-store", symbol: "bag.fill", title: "Store", value: "Epic Games")
            if let developer = game.developer { ValueRow(id: "ep-d-dev", symbol: "hammer.fill", title: "Developer", value: developer) }
            if let record = installer.record(game.appName) {
                ValueRow(id: "ep-d-ver", symbol: "number", title: "Installed version", value: record.buildVersion.isEmpty ? "Unknown" : record.buildVersion)
            }
            if let p = install?.progress, p.totalBytes > 0 { ValueRow(id: "ep-d-size", symbol: "externaldrive.fill", title: "Download size", value: EpicText.size(p.totalBytes)) }
        }
    }

    private var files: some View {
        SettingsGroup(title: "Files and links") {
            ActionRow(id: "ep-web", symbol: "safari", title: "Find on the Epic Games Store", chevron: false) {
                var components = URLComponents(string: "https://store.epicgames.com/browse")!
                components.queryItems = [URLQueryItem(name: "q", value: game.title)]
                if let url = components.url { UIApplication.shared.open(url) }
            }
            if let entry = libraryGame, !session.isActive || session.game != entry {
                ActionRow(id: "ep-c-write", symbol: "square.and.pencil", title: "Write a report", chevron: false) { door = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { writing = entry } }
            }
            if isInstalled {
                ActionRow(id: "ep-remove", symbol: "trash", title: "Delete downloaded files", destructive: true, chevron: false) { door = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { confirmRemove = true } }
            }
        }
    }
}
