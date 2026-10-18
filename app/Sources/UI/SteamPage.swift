// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import AVKit

/// Porthole's own store page for a Steam game, installed or not: pictures and trailers, the description, ratings, how it runs on this app, versions and requirements.
/// Steam's public store supplies the text and media; the compatibility section comes from other players' reports.
struct SteamGamePage: View {
    let game: SteamStore.Owned
    @ObservedObject var store: SteamStore
    var backTitle = "Steam"
    let back: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionController
    @Environment(AppRouter.self) private var router
    @ObservedObject private var compat = CompatStore.shared

    @State private var page: SteamStorePage?
    @State private var loading = true
    @State private var notice: String?
    @State private var fullAbout = false
    @State private var viewing: Int?
    @State private var reading: Reading?
    @State private var showReports = false
    @State private var door: Door?
    @ObservedObject private var infoStore = SteamInfoStore.shared
    @ObservedObject private var progress = SteamAchievementProgress.shared
    @State private var doorScope = FocusScope()
    @State private var writing: Game?
    @State private var confirmRemove = false
    @State private var viewerScope = FocusScope()
    @State private var readerScope = FocusScope()
    @State private var reportsScope = FocusScope()

    struct Reading: Identifiable { let id = UUID(); let title: String; let text: String }

    /// The pages behind the rows at the bottom of the page, so this page stays short.
    enum Door: String, Identifiable {
        case compat, reviews, details, versions, achievements, workshop, news
        var id: String { rawValue }
        var title: String { switch self { case .compat: "How it runs on Porthole"; case .reviews: "Steam reviews"; case .news: "News and patch notes"; case .details: "Details and files"; case .versions: "Version and DLC"; case .achievements: "Achievements"; case .workshop: "Workshop" } }
    }

    private var download: SteamStore.Download? { store.downloads[game.id] }
    private var installed: Bool { store.isInstalled(game.id) }
    private var libraryGame: Game? { model.games.first { $0.steamAppID == game.id } }
    private var badge: CompatBadge? { compat.steamBadges[game.id] }

    var body: some View {
        ZStack(alignment: .top) {
            hero
            VStack(alignment: .leading, spacing: 0) {
                HStack { PillButton(id: "sp-back", title: backTitle, symbol: "chevron.left", action: back); Spacer() }.padding(.horizontal, 24).padding(.top, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 22) {
                        titleBlock.padding(.top, 70)
                        actions
                        if let page, !page.media.isEmpty { mediaStrip(page.media) }
                        about
                        doors
                        if loading && page == nil { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding() }
                        else if page == nil { Text("The Steam page couldn't be loaded. Check the connection and open this again.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 30)
                    .frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
            }
        }
        .onNavBack { back(); return true }
        .task(id: game.id) {
            await SteamControllers.shared.refresh(ids: [game.id])
            page = await SteamStorePages.shared.page(appID: game.id); loading = false
            await compat.refreshSteamBadges(ids: [game.id])
        }
        .task(id: game.id) { await infoStore.refresh(appID: game.id) }
        .task(id: game.id) { await progress.refresh(appID: game.id, store: store) }
        .fullScreenCover(item: Binding(get: { viewing.map(ViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            MediaViewer(items: page?.media ?? [], start: start.index, scope: viewerScope) { viewing = nil }
        }
        .sheet(item: $door) { d in
            GameSubSheet(title: d.title, scope: doorScope, close: { door = nil }) {
                switch d {
                case .compat: compatibility
                case .reviews: reviews
                case .details: details; requirements; files
                case .versions: SteamVersionsContent(game: game, store: store, installed: installed, apply: { door = nil; start() })
                case .achievements: SteamAchievementsContent(appID: game.id, store: store)
                case .workshop: SteamWorkshopContent(appID: game.id, name: game.name, store: store)
                case .news: SteamNewsList(appID: game.id)
                }
            }
            .environmentObject(model)
        }
        .sheet(item: $reading) { r in TextReaderSheet(title: r.title, text: r.text, scope: readerScope) { reading = nil } }
        .sheet(isPresented: $showReports) {
            CompatGameSheet(gameID: "steam:\(game.id)", title: game.name, game: libraryGame, scope: reportsScope) { showReports = false }.environmentObject(model)
        }
        .sheet(item: $writing) { ReportSheet(game: $0).environmentObject(model).preferredColorScheme(Theme.scheme) }
        .confirm("Remove \(game.name)?", message: "This deletes the game's files from the device. You can download it again.", confirmTitle: "Delete files", destructive: true, isPresented: $confirmRemove) {
            store.uninstall(game); for g in model.games where g.steamAppID == game.id { model.remove(g) }
        }
    }

    private struct ViewerIndex: Identifiable { let index: Int; var id: Int { index } }

    // MARK: Pieces

    private var hero: some View {
        Color.clear.frame(height: 320)
            .overlay { AsyncImage(url: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.id)/library_hero.jpg")) { $0.resizable().scaledToFill() } placeholder: {
                AsyncImage(url: page?.headerURL) { $0.resizable().scaledToFill().blur(radius: 6) } placeholder: { Theme.panelHigh }
            } }
            .clipped()
            .overlay { LinearGradient(colors: [Theme.backgroundTop.opacity(0.1), Theme.backgroundTop.opacity(0.75), Theme.backgroundTop], startPoint: .top, endPoint: .bottom) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .background(Theme.background.ignoresSafeArea())
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(game.name).font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(Theme.text).shadow(color: .black.opacity(0.5), radius: 8)
            if let page, !(page.developers + page.publishers).isEmpty {
                Text(([page.developers.first, page.released].compactMap { $0 }).joined(separator: " \u{00B7} ")).font(.subheadline).foregroundStyle(Theme.text.opacity(0.8))
            }
            FlowLayout(spacing: 8) {
                compatPill
                if let level = SteamControllers.shared.level(for: game.id) { ControllerPillButton(level: level) }
                if let r = page?.reviewSummary { chip("hand.thumbsup.fill", "\(r.label) \u{00B7} \(r.percent)%", r.percent >= 70 ? Theme.good : r.percent >= 40 ? Theme.warn : Theme.bad) }
                if installed { chip(store.updateAvailable(game) ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill", store.updateAvailable(game) ? "Update available" : "Installed", store.updateAvailable(game) ? Theme.accent : Theme.good) }
                if let deck = infoStore.info(for: game.id)?.deck, deck != .unknown { chip("gamecontroller", deck.title, deck == .verified ? Theme.good : (deck == .playable ? Theme.warn : Theme.textDim)) }
                if let m = page?.metacritic { chip("star.fill", "Metacritic \(m)", Theme.textDim) }
            }
        }
    }

    @ViewBuilder private var compatPill: some View {
        if let verdict = badge?.verdict { CompatBadgePill(verdict: verdict) }
        else if let past = badge?.past { CompatPastPill(past: past) }
        else if compat.steamUntested.contains(game.id) || badge?.needsReview == true { CompatUntestedPill() }
    }

    private func chip(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 12, weight: .bold)); Text(text).font(.system(size: 13, weight: .semibold)) }
            .foregroundStyle(tint).padding(.horizontal, 12).padding(.vertical, 7).background(tint.opacity(0.15), in: Capsule())
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 10) {
                if let d = download {
                    switch d.state {
                    case .active, .queued: PillButton(id: "sp-main", title: "Pause", symbol: "pause.fill", style: .primary) { store.pause(game.id) }
                    case .paused, .failed: PillButton(id: "sp-main", title: "Resume", symbol: "play.fill", style: .primary) { start() }
                    }
                    PillButton(id: "sp-cancel", title: "Cancel", symbol: "xmark") { store.cancel(game.id) }
                } else if installed {
                    if store.updateAvailable(game) {
                        PillButton(id: "sp-main", title: "Update", symbol: "arrow.triangle.2.circlepath", style: .primary) { start() }
                    }
                    if let libraryGame {
                        PillButton(id: "sp-play", title: session.isActive ? "Busy" : "Play", symbol: "play.fill", style: store.updateAvailable(game) ? .glass : .primary, enabled: !session.isActive) { session.start(libraryGame) }
                        PillButton(id: "sp-open", title: "Game settings", symbol: "slider.horizontal.3") { router.tab = .library; router.homePath.append(libraryGame.id) }
                    } else {
                        PillButton(id: "sp-add", title: "Add to library", symbol: "plus", style: store.updateAvailable(game) ? .glass : .primary) {
                            if store.addToLibrary(game) { notice = nil } else { notice = store.error }
                        }
                    }
                } else {
                    PillButton(id: "sp-main", title: game.sizeBytes > 0 ? "Install \u{00B7} \(SteamGameTile.size(game.sizeBytes))" : "Install", symbol: "arrow.down.circle.fill", style: .primary) { start() }
                }
            }
            if let d = download {
                switch d.state {
                case .active: ProgressView(value: d.progress.fraction).tint(Theme.accent); Text(progressText(d.progress)).font(.caption).foregroundStyle(Theme.textDim)
                case .queued: Text("Waiting\u{2026}").font(.caption).foregroundStyle(Theme.textDim)
                case .paused: ProgressView(value: d.progress.fraction).tint(Theme.textDim); Text("Paused").font(.caption).foregroundStyle(Theme.textDim)
                case .failed(let why): Text(why).font(.caption).foregroundStyle(Theme.bad)
                }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.warn) }
        }
    }

    private func mediaStrip(_ media: [SteamStorePage.Media]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.label("Videos and screenshots").padding(.horizontal, 6)
            FocusScroll(axes: .horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(media.enumerated()), id: \.element.id) { i, item in
                        Button { viewing = i } label: {
                            Color.clear.frame(width: 260, height: 146)
                                .overlay { AsyncImage(url: item.thumb) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh } }
                                .overlay { if item.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white).shadow(radius: 6) } }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .focusTarget("sp-media-\(item.id)", radius: 14, scale: 1.06) { viewing = i }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder private var about: some View {
        if let page, !page.shortDescription.isEmpty || !page.about.isEmpty {
            SettingsGroup(title: "About this game") {
                Text(page.shortDescription.isEmpty ? String(page.about.prefix(400)) : page.shortDescription)
                    .font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .focusTarget("sp-about", radius: 16, scale: 1.01, action: { fullAbout.toggle() })
                if !page.genres.isEmpty { ValueRow(id: "sp-genres", symbol: "tag.fill", title: "Genres", value: page.genres.prefix(4).joined(separator: ", ")) }
                if page.about.count > page.shortDescription.count + 40 {
                    ActionRow(id: "sp-more", symbol: "text.alignleft", title: "Read the full description", chevron: true) { reading = Reading(title: game.name, text: page.about) }
                }
            }
        }
    }

    private var doors: some View {
        SettingsGroup {
            ActionRow(id: "sp-door-compat", symbol: "checkmark.seal.fill", title: "How it runs on Porthole", subtitle: compatSummary) { door = .compat }
            if let r = page?.reviewSummary {
                ActionRow(id: "sp-door-reviews", symbol: "hand.thumbsup.fill", title: "Steam reviews", subtitle: "\(r.label) \u{00B7} \(r.percent)%") { door = .reviews }
            }
            ActionRow(id: "sp-door-news", symbol: "newspaper.fill", title: "News and patch notes", subtitle: "From Steam") { door = .news }
            if store.signedIn {
                ActionRow(id: "sp-door-versions", symbol: "square.stack.3d.up.fill", title: "Version and DLC", subtitle: versionsSummary) { door = .versions }
            }
            if store.signedIn {
                ActionRow(id: "sp-door-achievements", symbol: "trophy.fill", title: "Achievements", subtitle: progress.summary(for: game.id) ?? "Your progress on Steam") { door = .achievements }
                ActionRow(id: "sp-door-workshop", symbol: "puzzlepiece.extension.fill", title: "Workshop", subtitle: "Mods and community items", badge: "Beta") { door = .workshop }
            }
            ActionRow(id: "sp-door-details", symbol: "info.circle.fill", title: "Details and files", subtitle: installed ? "Version, requirements, delete files" : "Version, requirements") { door = .details }
        }
    }

    private var versionsSummary: String {
        let choice = store.choice(game.id)
        var parts = [choice.branch == SteamBranch.publicName ? "Normal version" : choice.branch]
        if !choice.disabledDLC.isEmpty { parts.append("\(choice.disabledDLC.count) DLC off") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var compatSummary: String {
        if let v = badge?.verdict { return v.title }
        if let p = badge?.past { return p.text }
        return "Not yet tested"
    }

    /// Delete and open-on-Steam: out of the way, at the end of the details page.
    private var files: some View {
        SettingsGroup(title: "Files and links") {
            ActionRow(id: "sp-web", symbol: "safari", title: "Open on Steam", chevron: false) { UIApplication.shared.open(page?.storeURL ?? URL(string: "https://store.steampowered.com/app/\(game.id)")!) }
            if installed {
                ActionRow(id: "sp-remove", symbol: "trash", title: "Delete downloaded files", destructive: true, chevron: false) { door = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { confirmRemove = true } }
            }
        }
    }

    private var compatibility: some View {
        SettingsGroup(title: "On Porthole") {
            if let overall = badge?.overall {
                ValueRow(id: "sp-c-verdict", symbol: overall.verdict.symbol, title: overall.verdict.title, value: "\(overall.reports) report\(overall.reports == 1 ? "" : "s")", statusColor: overall.verdict.color)
            } else if let past = badge?.past {
                ValueRow(id: "sp-c-verdict", symbol: past.symbol, title: past.text, value: "\(badge?.earlier?.reports ?? 0) earlier report\((badge?.earlier?.reports ?? 0) == 1 ? "" : "s")", statusColor: past.color)
                Text(past.explanation).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            } else if badge?.needsReview == true {
                ValueRow(id: "sp-c-verdict", symbol: "questionmark.circle.fill", title: "Not yet tested", value: "Engine changed")
            } else {
                ValueRow(id: "sp-c-verdict", symbol: "questionmark.circle.fill", title: "Not yet tested", value: "No reports")
            }
            ActionRow(id: "sp-c-reports", symbol: "list.bullet.rectangle.fill", title: "See reports", info: "What other players say about running this game here, by device, with the settings that worked.") { door = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showReports = true } }
            if let libraryGame { ActionRow(id: "sp-c-write", symbol: "square.and.pencil", title: "Write a report", chevron: false) { door = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { writing = libraryGame } } }
        }
    }

    private var details: some View {
        SettingsGroup(title: "Details") {
            if let page {
                if !page.developers.isEmpty { ValueRow(id: "sp-d-dev", symbol: "hammer.fill", title: "Developer", value: page.developers.joined(separator: ", ")) }
                if !page.publishers.isEmpty, page.publishers != page.developers { ValueRow(id: "sp-d-pub", symbol: "building.2.fill", title: "Publisher", value: page.publishers.joined(separator: ", ")) }
                if let r = page.released { ValueRow(id: "sp-d-rel", symbol: "calendar", title: "Released", value: r) }
            }
            if game.sizeBytes > 0 { ValueRow(id: "sp-d-size", symbol: "externaldrive.fill", title: "Download size", value: SteamGameTile.size(game.sizeBytes)) }
            ValueRow(id: "sp-d-ver", symbol: "number", title: "Latest version", value: "Build \(game.buildID)")
            if let have = store.installedBuild(game.id) {
                ValueRow(id: "sp-d-have", symbol: "checkmark.circle.fill", title: "Installed version", value: "Build \(have)", statusColor: have < game.buildID ? Theme.warn : Theme.good)
            }
        }
    }

    @ViewBuilder private var reviews: some View {
        if let page, let summary = page.reviewSummary {
            SettingsGroup(title: "Steam reviews") {
                ValueRow(id: "sp-r-sum", symbol: "hand.thumbsup.fill", title: summary.label, value: "\(summary.percent)% of \(summary.total.formatted())",
                         statusColor: summary.percent >= 70 ? Theme.good : summary.percent >= 40 ? Theme.warn : Theme.bad)
                ForEach(page.reviews.prefix(6)) { r in
                    RowBase(id: "sp-r-\(r.id)", symbol: r.positive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill", tint: r.positive ? Theme.good : Theme.bad,
                            title: r.text.replacingOccurrences(of: "\n", with: " "), subtitle: "\(r.hours) h played \u{00B7} \(r.helpful) found it helpful",
                            action: { reading = Reading(title: r.positive ? "Recommended" : "Not recommended", text: r.text) }) { EmptyView() }
                }
            }
        }
    }

    @ViewBuilder private var requirements: some View {
        if let page, page.minimumRequirements != nil || page.recommendedRequirements != nil {
            SettingsGroup(title: "System requirements") {
                if let m = page.minimumRequirements { ActionRow(id: "sp-q-min", symbol: "cpu", title: "Minimum", chevron: true) { reading = Reading(title: "Minimum requirements", text: m) } }
                if let r = page.recommendedRequirements { ActionRow(id: "sp-q-rec", symbol: "cpu.fill", title: "Recommended", chevron: true) { reading = Reading(title: "Recommended requirements", text: r) } }
            }
        }
    }

    // MARK: Actions

    private func start() {
        notice = nil
        if game.sizeBytes > 0, let free = SteamGameTile.freeSpace(), free < Int64(Double(game.sizeBytes) * 1.15) + 500_000_000 {
            notice = "Not enough free space: it needs about \(SteamGameTile.size(game.sizeBytes)) and the device has \(SteamGameTile.size(UInt64(free)))."
            return
        }
        store.install(game.id)
    }

    private func progressText(_ p: SteamDownloadProgress) -> String {
        switch p.phase {
        case .preparing: return "Preparing\u{2026}"
        case .finishing: return "Finishing\u{2026}"
        case .downloading: return "\(SteamGameTile.size(p.doneBytes)) of \(SteamGameTile.size(p.totalBytes))" + (p.bytesPerSecond > 0 ? " \u{00B7} \(SteamGameTile.size(UInt64(p.bytesPerSecond)))/s" : "")
        }
    }
}

/// Full-screen picture or trailer. Left / Right (or the arrows) step through the others, A plays or pauses a video, B closes.
struct MediaViewer: View {
    let items: [SteamStorePage.Media]
    @State var index: Int
    let scope: FocusScope
    let close: () -> Void
    @State private var player: AVPlayer?
    @State private var playing = false

    init(items: [SteamStorePage.Media], start: Int, scope: FocusScope, close: @escaping () -> Void) {
        self.items = items; _index = State(initialValue: start); self.scope = scope; self.close = close
    }

    private var item: SteamStorePage.Media? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                if item.isVideo, let player {
                    VideoPlayer(player: player).ignoresSafeArea().allowsHitTesting(false)
                } else {
                    AsyncImage(url: item.full ?? item.thumb) { $0.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
                }
            }
            Color.clear.contentShape(Rectangle()).focusTarget("mv-stage", radius: 0, scale: 1, glow: false, adjust: { step($0) }, action: toggle).onTapGesture(perform: toggle)
            VStack {
                HStack {
                    Text("\(index + 1) of \(items.count)").font(.footnote.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
                    Spacer()
                    PillButton(id: "mv-close", title: "Close", symbol: "xmark", action: close)
                }
                Spacer()
                HStack(spacing: 12) {
                    PillButton(id: "mv-prev", title: "Previous", symbol: "chevron.left", enabled: index > 0) { step(-1) }
                    if item?.isVideo == true { PillButton(id: "mv-play", title: playing ? "Pause" : "Play", symbol: playing ? "pause.fill" : "play.fill", style: .primary, action: toggle) }
                    PillButton(id: "mv-next", title: "Next", symbol: "chevron.right", enabled: index < items.count - 1) { step(1) }
                }
            }
            .padding(20)
        }
        .navScope(scope)
        .onAppear { scope.onBack = close; scope.defaultFocus = "mv-stage"; scope.focused = "mv-stage"; load() }
        .onDisappear { player?.pause(); player = nil }
        .preferredColorScheme(.dark)
    }

    private func step(_ d: Int) {
        let next = min(max(index + d, 0), items.count - 1)
        guard next != index else { return }
        index = next; load()
    }

    private func toggle() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    private func load() {
        player?.pause(); playing = false
        guard let item, item.isVideo, let url = item.full else { player = nil; return }
        let p = AVPlayer(url: url)
        player = p; p.play(); playing = true
    }
}
