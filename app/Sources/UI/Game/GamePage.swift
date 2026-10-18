// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// One game: its art, Play, the three settings most people touch, and four doors to the rest. Each door opens a page of its own, so this page stays short.
struct GamePage: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: SessionController
    @Environment(AppRouter.self) private var router
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var friendsStore = SteamFriendsStore.shared
    @ObservedObject private var workshopStore = SteamWorkshopStore.shared
    @ObservedObject private var infoStore = SteamInfoStore.shared
    @ObservedObject private var progress = SteamAchievementProgress.shared
    @ObservedObject private var compat = CompatStore.shared
    @Environment(\.focusScope) private var scope
    @Environment(\.verticalSizeClass) private var vSize
    @State private var sub: Sub?
    @State private var subScope = FocusScope()
    @State private var sizeText = "Calculating\u{2026}"
    @State private var bits: Int?
    @State private var confirmDelete = false
    @State private var confirmRemove = false
    @State private var writing = false
    @State private var browseScope = FocusScope()
    @State private var installTick = 0
    @State private var reinstallNote: String?
    @State private var browsing = false
    @State private var argsText = ""
    @State private var changingProgram = false
    @State private var programScope = FocusScope()

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        Group {
            if let game {
                ZStack(alignment: .top) {
                    backdrop(game)
                    VStack(alignment: .leading, spacing: 0) {
                        header(game)
                        FocusScroll {
                            VStack(alignment: .leading, spacing: vSize == .compact ? 12 : 18) { content(game) }
                                .padding(.horizontal, 24).padding(.vertical, vSize == .compact ? 8 : 14)
                                .frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                        }
                    }
                }
                .task(id: game.exe) {
                    sizeText = await GameInfo.folderSize(for: game)
                    bits = await Task.detached { AppModel.peBits(windowsPath: game.exe) }.value
                    argsText = game.args
                }
                .task { await compat.ensureFingerprint(for: game) }
                .task(id: steam.signedIn) { if steam.signedIn { await friendsStore.refresh() } }
                .task(id: steam.signedIn) { if steam.signedIn, let id = game.steamAppID ?? game.dockAppID { await progress.refresh(appID: id, store: steam) } }
                .task(id: game.steamAppID ?? game.dockAppID) { if let id = game.steamAppID ?? game.dockAppID { await infoStore.refresh(appID: id) } }
                .task(id: steam.signedIn) {
                    if steam.signedIn, let id = game.steamAppID ?? game.dockAppID { await SteamWorkshopStore.shared.checkForUpdates(appID: id, gameName: game.name, download: SteamWorkshopStore.autoUpdate) }
                }
                .sheet(item: $sub) { s in
                    GameSubSheet(title: s.title, scope: subScope, close: { sub = nil }) { subContent(s, game) }
                        .environmentObject(model).environmentObject(session).environment(router)
                }
                .sheet(isPresented: $changingProgram) {
                    ChangeProgramSheet(game: game, scope: programScope, close: { changingProgram = false }).environmentObject(model).preferredColorScheme(Theme.scheme)
                }
                .sheet(isPresented: $writing) { ReportSheet(game: game).environmentObject(model).preferredColorScheme(Theme.scheme) }
                .sheet(isPresented: $browsing) {
                    CompatGameSheet(gameID: compat.candidateIDs(for: game).first ?? "none", title: game.name, game: game, scope: browseScope) { browsing = false }.environmentObject(model)
                }
                .confirm("Delete \(game.name)'s files?", message: "This frees the space on the device. You can download it again from the Steam tab.", confirmTitle: "Delete files", destructive: true, isPresented: $confirmDelete) {
                    if let id = game.dockAppID, let owned = steam.owned.first(where: { $0.id == id }) { steam.uninstall(owned) }
                    model.remove(game); leave()
                }
                .confirm("Remove \(game.name) from the library?", message: "The files stay on the device.", confirmTitle: "Remove", destructive: true, isPresented: $confirmRemove) {
                    model.remove(game); leave()
                }
            } else {
                VStack(spacing: 14) {
                    Text("This game was removed").foregroundStyle(Theme.textDim)
                    PillButton(id: "gp-gone", title: "Back", symbol: "chevron.left") { leave() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(for: .navigation) { Color.clear }
        .onNavBack { leave(); return true }
        .onAppear { scope?.defaultFocus = "gp-play"; scope?.focused = "gp-play" }
    }

    private func leave() {
        if !router.homePath.isEmpty { router.homePath.removeLast() }
        scope?.focused = gameID          // the tile you came from lights up again
    }

    // MARK: Top

    /// The game's art fills the whole page, softened and darkened so the rows on top stay readable.
    private func backdrop(_ g: Game) -> some View {
        ZStack {
            AmbientBackdrop(animated: false)
            Color.clear
                .overlay { GameArtView(id: g.id, name: g.name, kind: .hero).blur(radius: 7).scaleEffect(1.08) }
                .clipped()
                .overlay { Color.black.opacity(0.38) }
                .overlay { LinearGradient(colors: [.clear, Theme.backgroundBottom.opacity(0.55), Theme.backgroundBottom.opacity(0.9)], startPoint: .top, endPoint: .bottom) }
        }
        .ignoresSafeArea()
    }

    private func header(_ g: Game) -> some View {
        let busy = session.isActive
        let preparing = busy && session.game == g
        let steamLaunch = g.dockAppID != nil && g.launchDirect != true
        let play = PillButton(id: "gp-play", title: preparing ? "Preparing" : "Play", symbol: "play.fill", style: .primary, enabled: !busy) { session.start(g) }
        if vSize == .compact {
            // Sideways on a phone the height is what is scarce: back, the name and Play share one row, the chips sit in a short row of their own under it
            // (they wrap rather than scroll, so every one of them is always in view), and the settings get the rest.
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        PillButton(id: "gp-back", title: "Home", symbol: "chevron.left") { leave() }
                        Text(g.name).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).shadow(radius: 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        play
                    }
                    FlowLayout(spacing: 8) { chips(g, steamLaunch: steamLaunch) }
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 8)
            )
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                PillButton(id: "gp-back", title: "Home", symbol: "chevron.left") { leave() }
                Text(g.name).font(.system(size: 32, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6).shadow(radius: 6)
                // The chips wrap onto another line when the screen is narrow; they are never squeezed into a column.
                FlowLayout(spacing: 8) { chips(g, steamLaunch: steamLaunch) }
                play.padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
        )
    }

    @ViewBuilder private func chips(_ g: Game, steamLaunch: Bool) -> some View {
        if let store = g.store { StoreChip(store: store) }
        // The store chip says where the game came from; "Direct" is for a game run without its launcher.
        if g.store == nil || (g.store == .steam && !steamLaunch) { GlowChip(text: "Direct", symbol: "play.fill", tint: .white) }
        if let bits { GlowChip(text: "\(bits)-bit", tint: .white) }
        if let level = SteamControllers.shared.level(for: g.steamAppID ?? g.dockAppID) { ControllerPillButton(level: level) }
        if let info = infoStore.info(for: g.steamAppID ?? g.dockAppID) {
            if let r = info.reviews {
                GlowChip(text: "\(r.text) \u{00B7} \(r.percent)%", symbol: r.score >= 7 ? "hand.thumbsup.fill" : (r.score >= 5 ? "hand.thumbsup" : "hand.thumbsdown.fill"),
                         tint: r.score >= 7 ? Theme.good : (r.score >= 5 ? Theme.warn : Theme.bad))
            }
            if info.deck != .unknown { GlowChip(text: info.deck.title, symbol: "gamecontroller", tint: info.deck == .verified ? Theme.good : (info.deck == .playable ? Theme.warn : Theme.textDim)) }
        }
        if compat.showBadges, let verdict = compat.badges[g.id]?.verdict { BadgePill(badge: BadgeData(symbol: verdict.symbol, text: verdict.title, tint: verdict.color)) }
        else if compat.showBadges, let past = compat.badges[g.id]?.past { BadgePill(badge: BadgeData(symbol: past.symbol, text: past.text, tint: past.color)) }
        else if compat.showBadges, compat.isUntested(g) { BadgePill(badge: BadgeData(symbol: "questionmark.circle.fill", text: "Not yet tested", tint: Theme.textDim)) }
    }

    // MARK: Sections

    /// The pages behind the doors on this page.
    enum Sub: String, Identifiable {
        case controls, compat, more, about, achievements, workshop, friends, news
        var id: String { rawValue }
        var title: String { switch self { case .controls: "Controls"; case .compat: "How it runs"; case .more: "More options"; case .about: "About and files"; case .achievements: "Achievements"; case .friends: "Friends playing"; case .news: "News and patch notes"; case .workshop: "Workshop" } }
    }

    @ViewBuilder private func content(_ g: Game) -> some View {
        playSection(g)
        SettingsGroup {
            ActionRow(id: "gp-door-controls", symbol: "gamecontroller.fill", title: "Controls and key binds", subtitle: (g.controls ?? .standard) == .firstPerson ? "First person" : "Mouse and keys") { open(.controls) }
            ActionRow(id: "gp-door-compat", symbol: "checkmark.seal.fill", title: "How it runs for others", subtitle: compatSummary(g)) { open(.compat) }
            if g.steamAppID ?? g.dockAppID != nil {
                ActionRow(id: "gp-door-news", symbol: "newspaper.fill", title: "News and patch notes", subtitle: "From Steam") { open(.news) }
            }
            if steam.signedIn, g.steamAppID ?? g.dockAppID != nil {
                ActionRow(id: "gp-door-achievements", symbol: "trophy.fill", title: "Achievements", subtitle: progress.summary(for: g.steamAppID ?? g.dockAppID) ?? "Your progress on Steam") { open(.achievements) }
                ActionRow(id: "gp-door-friends", symbol: "person.2.fill", title: "Friends playing", subtitle: friendsSubtitle(g.steamAppID ?? g.dockAppID ?? 0)) { open(.friends) }
                ActionRow(id: "gp-door-workshop", symbol: "puzzlepiece.extension.fill", title: "Workshop", subtitle: workshopSubtitle(g.steamAppID ?? g.dockAppID ?? 0), badge: "Beta") { open(.workshop) }
            }
            ActionRow(id: "gp-door-more", symbol: "slider.horizontal.3", title: "More options", subtitle: "Speed, memory, engine and launch options") { open(.more) }
            ActionRow(id: "gp-door-about", symbol: "info.circle.fill", title: "About and files", subtitle: sizeText) { open(.about) }
        }
    }

    private func workshopSubtitle(_ appID: Int) -> String {
        let n = workshopStore.updates[appID] ?? 0
        return n > 0 ? "\(n) update\(n == 1 ? "" : "s") available" : "Mods and community items"
    }

    /// "2 playing now" / "Nobody right now", from the friends list (loaded when the page opens, at most every 30 seconds).
    private func friendsSubtitle(_ appID: Int) -> String {
        guard friendsStore.loaded, friendsStore.error == nil || !friendsStore.friends.isEmpty else { return "Who of your Steam friends is in this game" }
        let names = friendsStore.playing(game: appID).map(\.name)
        switch names.count {
        case 0: return "Nobody right now"
        case 1: return "\(names[0]) is playing now"
        default: return "\(names.count) playing now"
        }
    }

    private func open(_ s: Sub) { subScope.focused = nil; sub = s }

    private func compatSummary(_ g: Game) -> String {
        if let v = compat.badges[g.id]?.verdict { return v.title }
        if let p = compat.badges[g.id]?.past { return p.text }
        return "Not yet tested"
    }

    @ViewBuilder private func subContent(_ s: Sub, _ g: Game) -> some View {
        switch s {
        case .controls:
            controlsSection(g)
            GameBindsSection(gameID: g.id)
        case .compat: compatSection(g)
        case .more:
            RecommendedSettingsGroup(gameID: g.id)
            performanceSection(g)
            GameEngineSection(gameID: g.id)
            launchOptionsGroups(g)
        case .about: detailsSection(g)
        case .achievements: if let id = g.steamAppID ?? g.dockAppID { SteamAchievementsContent(appID: id, store: steam) }
        case .friends: if let id = g.steamAppID ?? g.dockAppID { SteamFriendsList(onlyIn: id) }
        case .news: if let id = g.steamAppID ?? g.dockAppID { SteamNewsList(appID: id) }
        case .workshop: if let id = g.steamAppID ?? g.dockAppID { SteamWorkshopContent(appID: id, name: g.name, store: steam) }
        }
    }

    /// Asks a question that belongs to this page while a sub page is open: close the sub page first, so the question is not hidden behind it.
    private func ask(_ question: @escaping () -> Void) {
        sub = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { question() }
    }

    private func playSection(_ g: Game) -> some View {
        let s = g.settings ?? GameSettings()
        let aspect = LaunchSettings.screenAspect
        let globalRes = DisplayResolution.resolve(id: LaunchSettings.globalResolution, screenAspect: aspect).text
        return VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Play") {
                if g.dockAppID != nil {
                    ChoiceRow(id: "gp-mode", symbol: "shield.checkered", title: "Start",
                              info: "Through Steam: Valve's own client checks your licence first. Most Steam games need this. Run directly: starts the game without Steam. Only use it for games that don't check Steam when they start; a game that does will freeze on its first screen.",
                              options: [(false, "Through Steam"), (true, "Run directly")], selection: Binding(get: { g.launchDirect == true }, set: { model.setLaunchDirect($0, for: g) }))
                }
                OverrideRow(id: "gp-res", symbol: "display", title: "Resolution", info: "The size of the screen this game sees. Default follows Settings > Display. Applies the next time the game starts.",
                            value: DisplayResolution.offered(s.resolution), globalText: globalRes,
                            options: DisplayResolution.allIDs.map { ($0, DisplayResolution.title(id: $0, screenAspect: aspect)) }) { v in setting(g) { $0.resolution = v } }
                OverrideRow(id: "gp-power", symbol: "bolt.fill", title: "Power mode", info: "Default follows Settings > Performance. Max runs up to the screen\u{2019}s maximum (120 FPS on a ProMotion screen, otherwise 60), Saver is 30 FPS and cooler.",
                            value: s.powerMode, globalText: PowerManager.shared.chosen.title,
                            options: PowerMode.allCases.map { ($0.rawValue, $0.title) }) { v in setting(g) { $0.powerMode = v } }
            }
            if !s.isEmpty {
                ActionRow(id: "gp-reset", symbol: "arrow.counterclockwise", title: "Reset this game to the app-wide settings", chevron: false) { model.update(g) { $0.settings = nil } }
            }
        }
    }

    /// Windows installers a Steam game brings with it: only for Steam games, and rarely needed.
    @ViewBuilder private func installsGroup(_ g: Game) -> some View {
        if let appID = g.dockAppID {
            SettingsGroup(title: "One-time installs") {
                        ChoiceRow(id: "gp-installs", symbol: "shippingbox.fill", title: "One-time installs",
                                  info: "Some Steam games bring installers for things they need (Rockstar's launcher, DirectX, Visual C++). Run at next start runs the ones that have not run yet before the game starts, with Windows' service manager available to them; after that the choice goes back to Skip, so they do not run every time. Skip starts the game without them. Use Run at next start again to retry an installer that failed.",
                                  options: [(true, "Run at next start"), (false, "Skip")],
                                  selection: Binding(get: { _ = installTick; return DockInstallers.runsNext(appID, prefix: AppModel.prefix) },
                                                     set: { DockInstallers.setRunsNext(appID, $0, prefix: AppModel.prefix); installTick += 1 }))
                        ActionRow(id: "gp-reinstall", symbol: "arrow.triangle.2.circlepath", title: "Run them all again",
                                  subtitle: reinstallNote,
                                  info: "Forgets that this game's one-time installs ever ran, so the next start runs every one of them again (Rockstar's launcher, Social Club, DirectX, Visual C++). Use it after you deleted what they installed, or when an install stopped half way. It does not delete anything itself.",
                                  chevron: false) {
                            if let dock = MadeiraDock.games(drive: AppModel.driveC).first(where: { $0.id == appID }) ?? ExternalLibrary.shared.dockGame(appID: appID) {
                                let n = DockInstallers.forget(dock, drive: AppModel.driveC, prefix: AppModel.prefix)
                                reinstallNote = n > 0 ? "Done: the next start runs them again." : "Nothing was recorded; the next start runs what is missing."
                                installTick += 1
                            } else { reinstallNote = "This game is not installed in Steam yet." }
                        }
            }
        }
    }

    private func performanceSection(_ g: Game) -> some View {
        let s = g.settings ?? GameSettings()
        return VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Memory") {
                OverrideRow(id: "gp-swap", symbol: "internaldrive.fill", title: "Swap", value: s.swapMB, globalText: LaunchSettings.globalSwapMB == 0 ? "Off" : "\(LaunchSettings.globalSwapMB / 1024) GB",
                            options: [(0, "Off"), (1024, "1 GB"), (2048, "2 GB"), (3072, "3 GB"), (4096, "4 GB")]) { v in setting(g) { $0.swapMB = v } }
                OverrideRow(id: "gp-cover", symbol: "square.stack.3d.up.fill", title: "Swap covers", value: s.swapCoverage, globalText: GameInfo.coverageName(LaunchSettings.globalSwapCoverage),
                            options: [("", "Large (8 MB+)"), ("blocks", "All 1 MB+"), ("wide", "1 MB+ and overflow"), ("broad", "Broad")]) { v in setting(g) { $0.swapCoverage = v } }
                OverrideRow(id: "gp-vram", symbol: "memorychip.fill", title: "Video memory", value: s.vramMB, globalText: LaunchSettings.globalVramMB == 0 ? "Automatic" : "\(LaunchSettings.globalVramMB) MB",
                            options: [(0, "Automatic"), (512, "512 MB"), (1024, "1 GB"), (1536, "1.5 GB"), (2048, "2 GB"), (3072, "3 GB"), (4096, "4 GB")]) { v in setting(g) { $0.vramMB = v } }
            }
            SettingsGroup(title: "Speed") {
                OverrideRow(id: "gp-hot", symbol: "thermometer.high", title: "Keep mode when hot", value: s.keepModeWhenHot, globalText: PowerManager.shared.ignoreHeat ? "On" : "Off",
                            options: [(true, "On"), (false, "Off")]) { v in setting(g) { $0.keepModeWhenHot = v } }
                OverrideRow(id: "gp-audio", symbol: "waveform", title: "Audio buffer", value: s.audioCushionMs, globalText: "\(SessionController.audioCushionMs) ms",
                            options: [(0, "Off"), (40, "40 ms"), (80, "80 ms"), (160, "160 ms"), (300, "300 ms")]) { v in setting(g) { $0.audioCushionMs = v } }
                OverrideRow(id: "gp-math", symbol: "function", title: "Precise shader math", value: s.preciseMath, globalText: SessionController.preciseMath ? "On" : "Off",
                            options: [(true, "On"), (false, "Off")]) { v in setting(g) { $0.preciseMath = v } }
                if g.dockAppID != nil {
                    OverrideRow(id: "gp-desk", symbol: "macwindow", title: "Wine desktop display", value: s.dockDesktop, globalText: SessionController.dockDesktop ? "On" : "Off",
                                options: [(true, "On"), (false, "Off")]) { v in setting(g) { $0.dockDesktop = v } }
                }
            }
        }
    }

    private func controlsSection(_ g: Game) -> some View {
        let first = g.controls == .firstPerson
        return VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "On-screen controls") {
                ChoiceRow(id: "gp-layout", symbol: "gamecontroller.fill", title: "Layout",
                          info: first ? "Left stick walks (W A S D). Drag on the right half of the screen to look. Buttons: jump, crouch, use, reload, sprint, fire and aim."
                                      : "Tap to click, drag to hold the button, press and hold for right click, pinch to zoom, with E / F / Tab / Esc always on screen.",
                          options: [(ControlLayout.standard, "Mouse and keys"), (ControlLayout.firstPerson, "First person")],
                          selection: Binding(get: { g.controls ?? .standard }, set: { v in model.update(g) { $0.controls = v == .standard ? nil : v } }))
                if first {
                    let current = g.settings?.lookSensitivity ?? LaunchSettings.globalLookSensitivity
                    SliderRow(id: "gp-look", symbol: "scope", title: "Look sensitivity" + (g.settings?.lookSensitivity == nil ? " (default)" : ""),
                              value: Binding(get: { current }, set: { v in setting(g) { $0.lookSensitivity = v } }), range: LaunchSettings.lookRange, step: 0.1, format: { String(format: "%.1f\u{00D7}", $0) })
                    if g.settings?.lookSensitivity != nil { ActionRow(id: "gp-look-reset", symbol: "arrow.counterclockwise", title: "Use the app-wide look sensitivity", chevron: false) { setting(g) { $0.lookSensitivity = nil } } }
                }
            }
        }
    }

    private func compatSection(_ g: Game) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "How it runs") {
                if let badge = compat.badges[g.id], let overall = badge.overall {
                    ValueRow(id: "gp-cv", symbol: overall.verdict.symbol, title: overall.verdict.title, value: "\(overall.reports) report\(overall.reports == 1 ? "" : "s")", statusColor: overall.verdict.color)
                    Text("Based on reports from other people on this version of the game engine.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                } else if let badge = compat.badges[g.id], let past = badge.past {
                    ValueRow(id: "gp-cv", symbol: past.symbol, title: past.text, value: "\(badge.earlier?.reports ?? 0) earlier report\((badge.earlier?.reports ?? 0) == 1 ? "" : "s")", statusColor: past.color)
                    Text(past.explanation).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                } else if let badge = compat.badges[g.id], badge.needsReview {
                    ValueRow(id: "gp-cv", symbol: "questionmark.circle.fill", title: "Not yet tested", value: "Engine changed")
                    Text("The game engine changed since the \(badge.earlier?.reports ?? 0) earlier report\((badge.earlier?.reports ?? 0) == 1 ? "" : "s"), so there is no verdict on this version yet.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                } else if compat.isUntested(g) {
                    ValueRow(id: "gp-cv", symbol: "questionmark.circle.fill", title: "Not yet tested", value: "No reports")
                    Text("Nobody has reported this game yet. Play it for a few minutes and send the first report.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                } else {
                    ValueRow(id: "gp-cv", symbol: "questionmark.circle", title: "No reports for this game yet", value: "")
                }
            }
            SettingsGroup {
                ActionRow(id: "gp-reports", symbol: "list.bullet.rectangle", title: "See reports") { ask { browsing = true } }
                ActionRow(id: "gp-write", symbol: "square.and.pencil", title: "Write a report") { ask { writing = true } }
            }
        }
    }

    @ViewBuilder private func launchOptionsGroups(_ g: Game) -> some View {
        installsGroup(g)
        SettingsGroup(title: "Launch") {
                TextFieldRow(id: "gp-args", symbol: "chevron.left.forwardslash.chevron.right", title: "Launch options", placeholder: "none",
                             info: "Extra command-line options for the program, separated by spaces.", monospaced: true,
                             text: Binding(get: { argsText }, set: { argsText = $0; let t = $0.trimmingCharacters(in: .whitespaces); if t != g.args { model.update(g) { $0.args = t } } }))
                ToggleRow(id: "gp-windows", symbol: "macwindow", title: "Show Windows windows",
                          info: "Draws ordinary Windows windows, like launchers and installers. Games that draw their own picture don't need it.",
                          isOn: Binding(get: { g.inDesktop == true }, set: { v in model.update(g) { $0.inDesktop = v ? true : nil } }))
            }
    }

    private func detailsSection(_ g: Game) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "About this game") {
                ValueRow(id: "gp-last", symbol: "clock.fill", title: "Last played", value: g.lastPlayed.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "Never")
                ValueRow(id: "gp-time", symbol: "hourglass", title: "Time played", value: GameInfo.duration(g.playSeconds ?? 0))
                ValueRow(id: "gp-size", symbol: "internaldrive.fill", title: "Size on disk", value: sizeText)
                ActionRow(id: "gp-exe", symbol: "terminal.fill", title: "Program", subtitle: g.exe, detail: "Change",
                          info: "Pick another program from this game's folder to start. The game stays in your library with its Steam link, settings and play time.") { changingProgram = true }
            }
            SettingsGroup(title: "Files") {
                if let id = g.dockAppID, let owned = steam.owned.first(where: { $0.id == id }) {
                    ActionRow(id: "gp-verify", symbol: "arrow.triangle.2.circlepath", title: "Verify and update files",
                              subtitle: steam.updateAvailable(owned) ? "Steam has a newer build. Only the changed parts are downloaded." : "Checks every file against Steam (a few minutes) and downloads only what is missing or damaged.", chevron: false) { steam.verify(id) }
                    ActionRow(id: "gp-delete", symbol: "trash", title: "Delete downloaded files", destructive: true, chevron: false) { ask { confirmDelete = true } }
                }
                ActionRow(id: "gp-remove", symbol: "minus.circle", title: "Remove from library", destructive: true, chevron: false) { ask { confirmRemove = true } }
            }
        }
    }

    // MARK: Helpers

    private func setting(_ g: Game, _ change: (inout GameSettings) -> Void) {
        model.update(g) { var s = $0.settings ?? GameSettings(); change(&s); $0.settings = s.isEmpty ? nil : s }
    }
}

/// A setting that follows the app-wide value until this game picks its own: the first choice is "Default (…)".
struct OverrideRow<T: Hashable>: View {
    let id: AnyHashable
    var symbol: String?
    let title: String
    var info: String?
    let value: T?
    let globalText: String
    let options: [(T, String)]
    let set: (T?) -> Void

    var body: some View {
        ChoiceRow(id: id, symbol: symbol, title: title, info: info,
                  options: [(nil as T?, "Default (\(globalText))")] + options.map { (Optional($0.0), $0.1) },
                  selection: Binding(get: { value }, set: { set($0) }))
    }
}


/// A page opened from a game's page: its own title, a Back button, and one scroll of settings.
struct GameSubSheet<Content: View>: View {
    let title: String
    let scope: FocusScope
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    PillButton(id: "sub-back", title: "Back", symbol: "chevron.left", action: close)
                    Text(title).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = close; scope.defaultFocus = "sub-back"; scope.focused = "sub-back" }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}
