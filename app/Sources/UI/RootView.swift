// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The app's frame: Home, Stores (Steam, Epic Games and later launchers), Reports and Settings as tabs on iPhone and a sidebar on iPad, with the running game full screen on top.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: SessionController
    @Environment(UpdateService.self) private var updates
    @State private var router = AppRouter()
    @State private var installerError: String?
    @State private var scope = FocusScope()
    @Environment(\.scenePhase) private var scenePhase
    @State private var guides = GuideCenter.shared

    private static let tabs = [ShellTab(id: "home", title: "Home", symbol: "house.fill"), ShellTab(id: "stores", title: "Stores", symbol: "square.grid.2x2.fill"),
                               ShellTab(id: "reports", title: "Reports", symbol: "checkmark.seal.fill"), ShellTab(id: "settings", title: "Settings", symbol: "gearshape.fill")]
    private static let tabOrder: [AppTab] = [.library, .stores, .compatibility, .settings]
    private static let tabIDs: [AppTab: String] = [.library: "home", .stores: "stores", .compatibility: "reports", .settings: "settings"]

    /// The guide for the section that is open.
    private var tabGuide: String {
        switch router.tab { case .library: "home"; case .stores: "stores"; case .compatibility: "reports"; case .settings: "settings" }
    }
    /// Something else covers the screen, so a guide waits.
    private var coverUp: Bool { router.showSetup || router.showAdd || router.pickInstaller || session.tourGame != nil || (session.state != .idle && session.state != .enablingJIT && !isFailed) }

    var body: some View {
        @Bindable var router = router
        @Bindable var guides = guides
        AppShell(tabs: Self.tabs,
                 selection: Binding(get: { Self.tabIDs[router.tab] ?? "home" }, set: { id in router.tab = Self.tabIDs.first { $0.value == id }?.key ?? .library }),
                 showHints: ControllerInput.shared.connected,
                 onHelp: { guides.show(tabGuide) }) {
            Group {
                switch router.tab {
                case .library: HomeScreen()
                case .stores: StoresScreen()
                case .compatibility: ReportsScreen()
                case .settings: SettingsScreen()
                }
            }
            .id(ThemeStore.shared.revision)
            .tint(Theme.accent)
        }
        .navScope(scope)
        .edgeSwipeBack()
        .sheet(item: $guides.current) { guide in GuideSheet(guide: guide) { runGuideAction($0) } }
        .onChange(of: router.tab) { _, _ in guides.autoShow(tabGuide) }
        .onChange(of: coverUp) { _, up in
            guides.blocked = up
            if !up { guides.autoShow(tabGuide) }       // the setup guide or a game has closed: this screen's guide can show now
        }
        .onAppear {
            guides.blocked = coverUp
            guides.autoShow(tabGuide)
            scope.defaultFocus = "hero-play"
            scope.onSection = { step in
                let i = Self.tabOrder.firstIndex(of: router.tab) ?? 0
                router.tab = Self.tabOrder[(i + step + Self.tabOrder.count) % Self.tabOrder.count]
                scope.focused = nil
            }
            scope.onBack = { if !router.homePath.isEmpty { router.homePath.removeLast() } }
        }
        .onReceive(session.objectWillChange) { _ in DispatchQueue.main.async { LaunchOverlay.shared.update(session: session) } }
        .environment(router)
        .environment(\.artLoader, AppArt.loader)
        .preferredColorScheme(Theme.scheme)
        // While the app updates itself nothing else can be used, and the person is told to stay.
        .overlay { UpdateProgressOverlay() }
        .sheet(isPresented: $router.showAdd) {
            AddGameFlow(onSteam: { router.openSteam() }, onEpic: { router.openStore(.epic) }, onGog: { router.openStore(.gog) }, onItch: { router.openStore(.itch) }, onAmazon: { router.openStore(.amazon) }, onInstaller: { router.pickInstaller = true })
                .environmentObject(model).environment(router).preferredColorScheme(Theme.scheme)
        }
        // The setup guide covers the whole screen, on iPhone and iPad.
        .fullScreenCover(isPresented: $router.showSetup) { setupGuide }
        .sheet(isPresented: $router.pickInstaller) {
            FilePickerSheet(onPick: { urls in
                router.pickInstaller = false
                do { session.start(try model.installerGame(from: urls[0])) } catch { installerError = error.localizedDescription }
            }, onCancel: { router.pickInstaller = false })
        }
        .confirm("Cannot run that", message: installerError, confirmTitle: "OK", isPresented: Binding(get: { installerError != nil }, set: { if !$0 { installerError = nil } })) {}
        .onChange(of: session.isActive) { _, running in
            SteamStore.shared.gameRunning(running)
            if !running { GogInstaller.shared.sessionEnded(); ItchInstaller.shared.sessionEnded() }          // a GOG setup that was running has finished: look for what it installed
            if !running { VPNGuard.shared.restoreIfPaused(); CellularGuard.shared.restoreIfPaused() }       // the game ended or never started: bring the person's own VPN and cellular data back
        }
        // Compatibility badges: when the app opens, when the game list changes, and when the app comes back to the front. (The Library used to do this itself.)
        .task { await Task.detached(priority: .utility) { SteamClientTraces.scrub(); SecretFiles.sweep() }.value; StoreNetwork.purgeOldCache() }
        .task(id: model.games.map(\.id)) {
            await CompatStore.shared.flushQueue()
            await CompatStore.shared.refreshBadges(for: model.games)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { VPNGuard.shared.recheck(); CellularGuard.shared.recheck() }
            if phase == .active { SteamStore.shared.refreshIfStale() }
            if phase == .active, UserDefaults.standard.bool(forKey: "f4.problemsSent") { Task { await ProblemTracker.shared.refresh() } }
            if phase == .active { Task { await CompatStore.shared.flushQueue(); await CompatStore.shared.refreshBadges(for: model.games) } }
        }
        .task {
            // Before anything else starts a game: if the last run ended while a game was running, its logs are put aside for a problem report.
            CrashEvidence.captureIfNeeded()
            _ = NetworkStatus.shared          // start watching the network, so screens know early whether it is there
            CellularGuard.warmUp()
            ControllerInput.shared.start()
            SteamStore.shared.onInstalled = { [weak model] game, exe in
                guard let model else { return }
                if let exe { model.add(exe: exe, name: game.name, steamAppID: game.id, dockAppID: game.id) }
                else { SteamStore.shared.error = "\(game.name) downloaded, but no program to run was found. Use Add a game to pick it." }
            }
            SteamStore.shared.start()
            let info = Bundle.main.infoDictionary
            LogStore.shared.log("[app] Porthole \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), engine \(CompatEngine.id), \(Bundle.main.bundleIdentifier ?? "?")")
            InstallCheck.logReport()
            // Reports this install sent earlier: look for answers (nothing is asked of the server before a first report).
            if UserDefaults.standard.bool(forKey: "f4.problemsSent") { await ProblemTracker.shared.refresh() }
            // First launch (or still missing the pairing file): show the guide once.
            // People who already had everything set up (a pairing file and games) are not walked through it.
            if !UserDefaults.standard.bool(forKey: "f4.setupDone"), BuiltinJIT.hasPairing, !model.games.isEmpty { UserDefaults.standard.set(true, forKey: "f4.setupDone") }
            if !UserDefaults.standard.bool(forKey: "f4.setupSeen"), !UserDefaults.standard.bool(forKey: "f4.setupDone") { router.showSetup = true }
            // Our JIT tunnel is only on while a game is being started; clear one a closed or crashed run left behind.
            if !session.isActive { await TunnelManager.shared.stopLeftoverTunnel() }
            VPNGuard.shared.restoreIfPaused()           // after an update the app restarts with the person's VPN still paused
            CellularGuard.shared.restoreIfPaused()      // and with cellular data still off, if that is what the update switched off
        }
        // The first game ever started shows how to play first; the game starts when the tour ends.
        .fullScreenCover(item: Binding(get: { session.tourGame }, set: { if $0 == nil { session.finishTour() } })) { game in
            GameTourView(gameName: game.name) { session.finishTour() }
        }
        // The same tour on request (Settings, Tips and guides), with no game waiting behind it.
        .fullScreenCover(isPresented: $guides.tourReplay) { GameTourView(gameName: nil) { guides.tourReplay = false } }
        .fullScreenCover(isPresented: Binding(get: { session.state != .idle && session.state != .enablingJIT && !isFailed },
                                              set: { if !$0 { session.dismiss() } })) {
            SessionView().environmentObject(session)
        }
    }

    private var setupGuide: some View {
        SetupGuideView(openAdd: { router.showAdd = true }, openSteam: { router.openSteam() }, openEpic: { router.openStore(.epic) }, openGog: { router.openStore(.gog) }, openItch: { router.openStore(.itch) }, openAmazon: { router.openStore(.amazon) }).environmentObject(model).environment(updates)
    }

    /// A guide step's button: close the guide, then go where it says.
    private func runGuideAction(_ action: GuideAction) {
        guides.current = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))      // the sheet has to finish closing first
            switch action {
            case .addGame: router.showAdd = true
            case .openStore(let store): router.openStore(store)
            case .openSettings(let page): router.openSettings(page)
            }
        }
    }

    private var isFailed: Bool { if case .failed = session.state { return true }; return false }
}
