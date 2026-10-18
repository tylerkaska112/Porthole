// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The home screen: turns the app's real state (games, JIT, downloads, updates) into the plain values the kit's HomeView draws.
struct HomeScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: SessionController
    @Environment(UpdateService.self) private var updates
    @Environment(AppRouter.self) private var router
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epicInstaller = EpicInstaller.shared
    @ObservedObject private var gogInstaller = GogInstaller.shared
    @ObservedObject private var itchInstaller = ItchInstaller.shared
    @ObservedObject private var amazonInstaller = AmazonInstaller.shared
    @ObservedObject private var problemTracker = ProblemTracker.shared
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @ObservedObject private var compat = CompatStore.shared
    @ObservedObject private var controllers = SteamControllers.shared
    @AppStorage("f4.setupDone") private var setupDone = false
    @State private var installerRan = UserDefaults.standard.string(forKey: "f4.installerRan")
    /// Chips the person hid with the x (kept across launches). The key of a kind of chip changes when there is something new to say (a newer update).
    @State private var dismissed = Set(UserDefaults.standard.stringArray(forKey: "f4.dismissedNotices") ?? [])
    @State private var reportGame: Game?
    @State private var pickSteam: Game?
    @ObservedObject private var friends = SteamFriendsStore.shared
    @ObservedObject private var restarting = RestartCoordinator.shared
    @State private var showFriends = false
    @State private var friendsScope = FocusScope()

    /// Most recently played first.
    private var sortedGames: [Game] {
        model.games.enumerated().sorted {
            let a = $0.element.lastPlayed ?? .distantPast, b = $1.element.lastPlayed ?? .distantPast
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.homePath) {
            HomeView(notices: notices, games: sortedGames.map(card), featuredPlaying: preparingFeatured,
                     act: act, dismiss: dismissNotice, open: { router.homePath.append($0.id) }, play: { card in
                         if let game = model.games.first(where: { $0.id == card.id }) { session.start(game) }
                     }, add: { router.showAdd = true },
                     menu: { card in AnyView(menu(for: card)) })
                .safeAreaInset(edge: .top, spacing: 0) { friendsBar }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: UUID.self) { GamePage(gameID: $0).onAppear { GuideCenter.shared.autoShow("gamepage") } }
                .containerBackground(for: .navigation) { Color.clear }
        }
        .background(.clear)
        .environment(\.artLoader, AppArt.loader)
        .onAppear { session.refreshJIT() }
        .task(id: model.games.map(\.id)) { await controllers.refresh(ids: model.games.compactMap { $0.steamAppID ?? $0.dockAppID }) }
        .task(id: steam.signedIn) { if steam.signedIn { await friends.refresh() } }
        .task { await RestartCoordinator.shared.resumeIfPending(model: model) }
        .sheet(isPresented: $showFriends) {
            GameSubSheet(title: "Friends", scope: friendsScope, close: { showFriends = false }) {
                if steam.signedIn { SteamFriendsList() } else { signInHint }
            }
            .preferredColorScheme(Theme.scheme)
        }
        .sheet(item: $reportGame) { ReportSheet(game: $0, crashed: compat.prompt?.crashed ?? false).environmentObject(model).preferredColorScheme(Theme.scheme) }
        .sheet(item: $pickSteam) { game in
            SteamPickerView(initialTerm: SteamArt.searchTerms(name: game.name, exe: game.exe).first ?? game.name) { match in
                model.setSteamAppID(match?.id ?? 0, for: game)
            }
            .preferredColorScheme(Theme.scheme)
        }
    }

    /// The Friends button: on the Home Screen only (a game's page is a different screen on the stack), always there, above everything else.
    private var friendsBar: some View {
        HStack {
            Spacer(minLength: 0)
            PillButton(id: "home-friends", title: friendsTitle, symbol: "person.2.fill", style: .glass) { showFriends = true }
        }
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 4)
    }

    /// "Friends", with how many are on Steam right now once the list has loaded.
    private var friendsTitle: String {
        let now = friends.friends.filter(\.isOnline).count
        return steam.signedIn && friends.loaded && now > 0 ? "Friends \u{00B7} \(now) online" : "Friends"
    }

    private var signInHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.slash").font(.system(size: 40)).foregroundStyle(Theme.textDim)
            Text("Sign in to Steam to see your friends.").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            PillButton(id: "home-friends-signin", title: "Open Steam", symbol: "arrow.right", style: .primary) { showFriends = false; router.openSteam() }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var preparingFeatured: Bool { session.isActive && sortedGames.first.map { $0 == session.game } == true }

    // MARK: Data for the kit

    private func card(_ game: Game) -> GameCardData {
        var parts = [game.lastPlayed.map { "Played " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "Not played yet"]
        if let t = game.playSeconds, t >= 60 { parts.append(GameInfo.duration(t)) }
        var badge: BadgeData?
        if compat.showBadges {
            if let verdict = compat.badges[game.id]?.verdict { badge = BadgeData(symbol: verdict.symbol, text: verdict.title, tint: verdict.color) }
            else if let past = compat.badges[game.id]?.past { badge = BadgeData(symbol: past.symbol, text: past.text, tint: past.color) }
            else if compat.isUntested(game) { badge = BadgeData(symbol: "questionmark.circle.fill", text: "Not yet tested", tint: Theme.textDim) }
        }
        let chip: String? = game.dockAppID == nil ? nil : (game.launchDirect == true ? "Direct" : "Steam")
        return GameCardData(id: game.id, name: game.name, subtitle: parts.joined(separator: " \u{00B7} "), launchChip: chip, store: game.store, badge: badge,
                            controller: controllers.level(for: game.steamAppID ?? game.dockAppID))
    }

    private var notices: [NoticeData] {
        var list: [NoticeData] = []
        if let wait = session.jitWaitMessage, !session.launchOverlayActive {
            list.append(NoticeData(id: "jit", symbol: "hourglass", title: "Waiting for JIT", detail: wait, actionTitle: "Cancel", spinner: true))
        }
        if case .failed(let message) = session.state, !session.launchOverlayActive {
            list.append(NoticeData(id: "failed", symbol: "exclamationmark.triangle.fill", title: "Couldn't start the game", detail: message, tint: Theme.bad, actionTitle: session.restartAdvised ? "Close Porthole" : "Dismiss"))
        }
        if session.restartNeeded, !session.isActive, session.state != .running {
            list.append(NoticeData(id: "restart", symbol: "arrow.clockwise.circle.fill", title: "Restart to play another game",
                                   detail: "Porthole has to close and open again before the next game. Your games, saves and settings are kept.", tint: Theme.warn, actionTitle: "Close Porthole"))
        }
        if let name = restarting.starting {
            list.append(NoticeData(id: "restart-pending", symbol: "arrow.clockwise.circle.fill", title: "Starting \(name) again", detail: "Finishing any Workshop downloads first.", actionTitle: "Cancel", spinner: true))
        }
        if !setupDone {
            list.append(NoticeData(id: "setup", symbol: "checklist", title: "Finish setting up", detail: "A few quick steps before games can run.", actionTitle: "Continue", dismissKey: "setup"))
        }
        let runtime = VCRuntimeInstaller.shared
        if setupDone, !runtime.available {
            var detail = "Many games need Microsoft's C++ runtime. About 25 MB, from Microsoft, checked before use."
            if case .downloading(let fraction) = runtime.state { detail = "\(Int(fraction * 100))% downloaded." }
            if case .failed(let message) = runtime.state { detail = message }
            list.append(NoticeData(id: "runtime", symbol: "shippingbox.fill", title: runtime.busy ? "Downloading components" : "Windows components", detail: detail, tint: Theme.warn,
                                   actionTitle: runtime.busy ? nil : "Download", spinner: runtime.busy, dismissKey: runtime.busy ? nil : "runtime"))
        }
        let attention = InstallCheck.attention
        if setupDone, !attention.isEmpty {
            let worst = attention.first!
            let more = attention.count > 1 ? " (and \(attention.count - 1) more)" : ""
            list.append(NoticeData(id: "install", symbol: "checkmark.shield.fill", title: worst.title + more, detail: worst.detail,
                                   tint: worst.level == .problem ? Theme.bad : Theme.warn, actionTitle: "Details", dismissKey: InstallCheck.noticeKey(attention)))
        }
        if VPNGuard.shared.paused, !session.isActive {
            let shortcut = VPNGuard.shared.hasShortcut
            list.append(NoticeData(id: "vpn", symbol: "lock.open.fill", title: "Your VPN is paused", detail: "Porthole switched it off to turn on JIT or install an update. Turn it back on in Settings \u{203A} VPN, or make a shortcut that does it for you (Settings \u{203A} JIT and tunnel). This goes away by itself once a VPN is on.",
                                   tint: Theme.warn, actionTitle: shortcut ? "Turn on" : "Got it"))
        }
        if CellularGuard.shared.paused, !session.isActive, !CellularGuard.shared.busy {
            list.append(NoticeData(id: "cellular", symbol: "antenna.radiowaves.left.and.right.slash", title: "Cellular data is off", detail: "Porthole switched it off to turn on JIT or install an update and could not switch it back on. Tap Turn on to run the shortcut, or turn it on in Settings.",
                                   tint: Theme.warn, actionTitle: "Turn on"))
        }
        if let release = updates.available {
            list.append(NoticeData(id: "update", symbol: "arrow.down.circle.fill", title: "Update \(release.title) ready", detail: "Download and install it from Settings > Updates.", actionTitle: "Open", dismissKey: "update:\(release.build)"))
        }
        if let name = installerRan {
            list.append(NoticeData(id: "installer", symbol: "shippingbox.fill", title: "\(name) finished", detail: "Add what it installed to your library.", tint: .orange, actionTitle: "Add", dismissKey: "installer:\(name)"))
        }
        // Steam games on the device with a newer build on Steam. The notice comes back when another game, or a newer build of the same one, appears.
        let updates = steam.gamesWithUpdates
        if let first = updates.first {
            let title = updates.count == 1 ? "\(first.name) has an update" : "\(updates.count) Steam games have updates"
            let detail = updates.count == 1 ? "A newer build is on Steam. Open the library to update it." : "\(updates.prefix(3).map(\.name).joined(separator: ", "))\(updates.count > 3 ? " and more" : ""). Open the library to update them."
            list.append(NoticeData(id: "steam-update", symbol: "arrow.triangle.2.circlepath.circle.fill", title: title, detail: detail, tint: Theme.accent, actionTitle: "Open",
                                   dismissKey: "steam-update:" + updates.map { "\($0.id)@\($0.buildID)" }.sorted().joined(separator: ",")))
        }
        if let (id, d) = steam.downloads.first(where: { $0.value.state == .active }), let game = steam.owned.first(where: { $0.id == id }) {
            list.append(NoticeData(id: "download", symbol: "arrow.down.to.line", title: "\(game.name) \(Int(d.progress.fraction * 100))%", detail: "Downloading from Steam. Tap to see all downloads.", actionTitle: "Open"))
        }
        if let (name, install) = epicInstaller.installs.first(where: { $0.value.state == .active }), let game = epicLibrary.games.first(where: { $0.appName == name }) ?? epicInstaller.game(for: name) {
            list.append(NoticeData(id: "download-epic", symbol: "arrow.down.to.line", title: "\(game.title) \(Int(install.progress.fraction * 100))%", detail: "Downloading from Epic Games. Tap to see all downloads.", actionTitle: "Open"))
        }
        if let (id, install) = gogInstaller.installs.first(where: { $0.value.state == .active }), let game = gogInstaller.game(for: id) {
            list.append(NoticeData(id: "download-gog", symbol: "arrow.down.to.line", title: "\(game.title) \(Int(install.progress.fraction * 100))%", detail: "Downloading from GOG. Tap to see all downloads.", actionTitle: "Open"))
        }
        if let (id, install) = itchInstaller.installs.first(where: { $0.value.state == .active }), let game = itchInstaller.game(for: id) {
            list.append(NoticeData(id: "download-itch", symbol: "arrow.down.to.line", title: "\(game.title) \(Int(install.progress.fraction * 100))%", detail: "Downloading from itch.io. Tap to see all downloads.", actionTitle: "Open"))
        }
        if let (id, install) = amazonInstaller.installs.first(where: { $0.value.state == .active }), let game = amazonInstaller.game(for: id) {
            list.append(NoticeData(id: "download-amazon", symbol: "arrow.down.to.line", title: "\(game.title) \(Int(install.progress.fraction * 100))%", detail: "Downloading from Amazon Games. Tap to see all downloads.", actionTitle: "Open"))
        }
        // The maintainer answered a problem report: the status changed, or a note was added.
        let answered = problemTracker.answered
        if let first = answered.first {
            let what: String
            switch first.status {
            case "fixed": what = first.fixedIn.isEmpty ? "was fixed" : "was fixed in \(first.fixedIn)"
            default: what = "was reviewed"
            }
            let title = answered.count > 1 ? "\(answered.count) of your reports have an update" : "Your report \(what)"
            let detail = answered.count > 1 ? "Open Report a problem to read what was said." :
                (first.note.isEmpty ? "\u{201C}\(first.description.prefix(60))\u{201D}. Open it to read the answer." : first.note)
            list.append(NoticeData(id: "problem", symbol: first.status == "fixed" ? "checkmark.seal.fill" : "text.bubble.fill", title: title, detail: detail,
                                   tint: first.status == "fixed" ? Theme.good : .blue, actionTitle: "Open", dismissKey: "problem:\(first.id):\(Int(first.updatedAt))"))
        }
        if let prompt = compat.prompt {
            list.append(NoticeData(id: "compat", symbol: prompt.crashed ? "exclamationmark.bubble.fill" : "chart.bar.doc.horizontal.fill",
                                   title: prompt.crashed ? "\(prompt.gameName) closed unexpectedly" : "How did \(prompt.gameName) run?",
                                   detail: "A short report helps other people with your device.", actionTitle: "Report", dismissKey: "compat:\(prompt.gameID)"))
        }
        return list.filter { $0.dismissKey.map { !dismissed.contains($0) } ?? true }
    }

    private func dismissNotice(_ notice: NoticeData) {
        guard let key = notice.dismissKey else { return }
        if key.hasPrefix("compat:") { compat.dismissPrompt(); return }       // the report question itself goes away
        if key.hasPrefix("installer:") { UserDefaults.standard.removeObject(forKey: "f4.installerRan"); installerRan = nil }
        dismissed.insert(key)
        UserDefaults.standard.set(Array(dismissed), forKey: "f4.dismissedNotices")
    }

    private func act(_ notice: NoticeData) {
        switch notice.id {
        case "jit": session.cancelJITWait()
        case "failed": if session.restartAdvised { session.closeApp() } else { session.dismiss() }
        case "restart": session.closeApp()
        case "restart-pending": RestartCoordinator.shared.cancel()
        case "setup": router.showSetup = true
        case "runtime": Task { await VCRuntimeInstaller.shared.install() }
        case "cellular": Task { await CellularGuard.shared.restoreNow() }
        case "vpn": if VPNGuard.shared.hasShortcut { VPNGuard.shared.runShortcut() } else { VPNGuard.shared.forget() }
        case "update": router.openSettings(.updates)
        case "install": router.openSettings(.accounts)
        case "installer": UserDefaults.standard.removeObject(forKey: "f4.installerRan"); installerRan = nil; router.showAdd = true
        case "steam-update": router.openSteam()
        case "download", "download-epic", "download-gog", "download-itch", "download-amazon": router.openDownloads()
        case "problem": router.openSettings(.report)
        case "compat": if let prompt = compat.prompt { reportGame = model.games.first { $0.id == prompt.gameID } }
        default: break
        }
    }

    @ViewBuilder private func menu(for card: GameCardData) -> some View {
        if let game = model.games.first(where: { $0.id == card.id }) {
            Button { session.start(game) } label: { Label("Play", systemImage: "play.fill") }.disabled(session.isActive)
            if game.dockAppID != nil {
                let direct = game.launchDirect == true
                Button { model.setLaunchDirect(!direct, for: game) } label: {
                    Label(direct ? "Start through Steam" : "Run directly (skip Steam)", systemImage: direct ? "checkmark.shield" : "play.rectangle")
                }
            }
            Button { pickSteam = game } label: { Label("Choose Steam artwork\u{2026}", systemImage: "photo") }
            Button("Remove from library", role: .destructive) { model.remove(game) }
        }
    }
}
