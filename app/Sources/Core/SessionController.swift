// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import SwiftUI

/// Starts and watches one game. This is the seam between our UI and the runtime: everything below `launch` is the runtime's own sequence
/// (JIT pool -> detach -> wineserver -> wine process), distilled from Madeira's launch path; everything above it is ours.
@MainActor
final class SessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case enablingJIT
        case starting
        case running
        case ended
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { if case .failed = state { CellularGuard.shared.restoreIfPaused() } }          // cellular data switched off for the tunnel comes back on
    }
    @Published private(set) var game: Game?
    @Published private(set) var jitEnabled = jit_check_debugged()
    /// While a Steam (Dock) launch runs: what Valve's client is doing, from the host's report.
    @Published private(set) var dockStatus: String?
    /// A short note about the controller shown over the game for a few seconds (automatic keyboard-and-mouse mode switching on or off).
    @Published private(set) var padNotice: String?
    func showPadNotice(_ text: String) {
        padNotice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.padNotice == text { self?.padNotice = nil }
        }
    }
    /// The settings this launch uses (the game's own overrides over the global ones), and the controls it gets.
    private(set) var activeSettings = LaunchSettings.resolve(for: nil)
    @Published private(set) var activeLayout: ControlLayout = .standard
    /// The on-screen controls of the bind set in use, or nil to use the game's normal Controls choice (see BindSets.swift).
    @Published private(set) var activeTouchLayout: TouchLayout?
    /// First-person look speed for the running game; the in-game menu changes it live and saves it to the game's settings.
    @Published private(set) var lookSensitivity = LaunchSettings.defaultLookSensitivity
    private var runningSince: Date?
    /// Play time is saved while the game runs, not only when it ends: most games close the whole app when they quit, and then nothing after the
    /// game's last frame ever runs. `playCheckpoint` is the moment up to which the time has been saved.
    private var playCheckpoint: Date?
    private var playTimer: Timer?
    /// True once a game's program has been started in this process. The runtime cannot be started a second time, so another game needs the app to be
    /// opened again.
    @Published private(set) var restartNeeded = false
    /// The launch failed in a way a fresh start of the app fixes (the home screen's notice then offers Close Porthole).
    @Published private(set) var restartAdvised = false
    static let minimumSteamPool = 640 << 20
    private var dockPoll: Timer?
    private var dockGame: DockGame?

    // MARK: The launch screen's state

    /// Where the launch is, from pressing Play until the game's own window is up.
    enum LaunchStep: Int { case jit, prepare, steam, signIn, load }
    @Published private(set) var launchStep: LaunchStep = .jit
    /// True once a window of the game has put a picture on screen.
    @Published private(set) var launchGameUp = false
    /// The person asked to look at Steam's own window instead of the launch screen.
    @Published var launchPeeking = false
    private var launchCancelled = false
    private var wineStarted = false
    private var launchWatch: Timer?
    private var launchBegan = Date()
    private var launchPresentsAtStart: UInt64 = 0
    private var launchViaSteam = false

    /// Logical Wine desktop size (the runtime aspect-fits it into the view). Games choose their own mode inside it.
    static let desktopWidth = 1280
    static let desktopHeight = 720

    /// Audio jitter cushion in ms (patches/0006): extra buffered audio so a late emulated audio thread does not glitch the sound. 0 = off.
    static let audioCushionKey = "f4.audioCushionMs"
    static var audioCushionMs: Int {
        UserDefaults.standard.object(forKey: audioCushionKey) as? Int ?? 80
    }

    /// Steam games (Dock): true (default) = Madeira's own setup, on a Wine virtual desktop whose compositor view holds the game; our controls sit on top and
    /// touch is mapped through the same fitted rect. false = "single display" EXPERIMENT: no explorer, the game draws straight into our game view. In the
    /// first test of that mode the 32-bit game process crashed while starting (Wine ntdll, before any graphics), where the desktop mode always passed.
    static let dockDesktopKey = "f4.dockDesktop"
    static var dockDesktop: Bool { UserDefaults.standard.object(forKey: dockDesktopKey) as? Bool ?? true }

    /// Exact (non-"fast") shader math. Default off (it did not fix the dusk/dawn black world).
    static let preciseMathKey = "f4.preciseMath"
    static var preciseMath: Bool {
        UserDefaults.standard.object(forKey: preciseMathKey) as? Bool ?? false
    }

    var isActive: Bool {
        switch state { case .enablingJIT, .starting, .running: return true; default: return false }
    }

    /// Changes the touch layout while the game runs (the in-game menu) and remembers it for this game.
    func switchLayout(to layout: ControlLayout) {
        guard layout != activeLayout else { return }
        activeLayout = layout
        if let g = game { AppModel.shared.update(g) { $0.controls = layout == .standard ? nil : layout } }
        LogStore.shared.log("[controls] layout \(layout == .firstPerson ? "first person" : "mouse and keys")")
    }

    // MARK: The controller the game is shown, while it runs

    /// The in-game menu's choice of controller: nil = Automatic, "xbox", "hid" (a DualSense next to the Xbox pad) or "keys" (keyboard and mouse). Applied at once and remembered for this game.
    /// The DualSense exists only when the session started with it (a PlayStation controller connected, or the game's Controller choice); the menu says so otherwise.
    func setPadMode(_ mode: String?) {
        guard isActive, let g = game else { return }
        AppModel.shared.update(g) {
            var e = $0.engine ?? GameEngine()
            e.controllerMode = mode; e.padAuto = nil
            $0.engine = e.isEmpty ? nil : e
        }
        LogStore.shared.log("[pad] controller choice from the in-game menu: \(mode ?? "automatic")")
        if let fresh = AppModel.shared.games.first(where: { $0.id == g.id }) {
            game = fresh
            PadInput.shared.updateLive(for: fresh)
        }
    }

    // MARK: Bind sets while the game runs

    /// Reads the game's bind sets again after a change made in the game (the editor, the set picker): the touch layout and the controller binds apply at once.
    func bindSetsChanged() {
        guard isActive, let g = game, let fresh = AppModel.shared.games.first(where: { $0.id == g.id }), fresh != g else { return }
        game = fresh
        if activeTouchLayout != fresh.activeBindSet?.touch { activeTouchLayout = fresh.activeBindSet?.touch }
        PadInput.shared.updateLive(for: fresh)
    }

    /// The on-screen editor moved, added or removed a control: keep the layout in the set in use.
    func saveLiveTouchLayout(_ layout: TouchLayout) {
        guard let g = game else { return }
        AppModel.shared.update(g) { game in
            guard let active = game.activeBindSetID, var sets = game.bindSets, let i = sets.firstIndex(where: { $0.id == active }) else { return }
            sets[i].touch = layout; sets[i].updated = Date(); game.bindSets = sets
        }
    }

    /// The in-game editor was opened on a game with no custom layout: make a set for it (from `template`) and use it. Nothing existing is changed.
    func createLiveLayout(from template: TouchLayout) {
        guard let g = game else { return }
        var set = BindSet(name: "On-screen controls", touch: template)
        var n = 2; while (g.bindSets ?? []).contains(where: { $0.name == set.name }) { set.name = "On-screen controls \(n)"; n += 1 }
        AppModel.shared.update(g) { $0.bindSets = ($0.bindSets ?? []) + [set]; $0.activeBindSetID = set.id }
        LogStore.shared.log("[binds] new set \"\(set.name)\" made in the game")
        bindSetsChanged()
    }

    /// Multiplies the look speed (the in-game menu's Faster / Slower) and remembers it for this game.
    func adjustLook(by factor: Double) {
        let v = min(max(lookSensitivity * factor, LaunchSettings.lookRange.lowerBound), LaunchSettings.lookRange.upperBound)
        lookSensitivity = (v * 100).rounded() / 100
        if let g = game { AppModel.shared.update(g) { var st = $0.settings ?? GameSettings(); st.lookSensitivity = lookSensitivity; $0.settings = st } }
        LogStore.shared.log("[controls] look sensitivity \(lookSensitivity)")
    }

    /// Shown on the home screen while the app waits for JIT from another tool (JITMethod.other).
    @Published var jitWaitMessage: String?
    private var jitWaitTimer: Timer?

    func cancelJITWait() {
        jitWaitTimer?.invalidate(); jitWaitTimer = nil; jitWaitMessage = nil
        if state == .enablingJIT { state = .idle; game = nil }
    }

    func refreshJIT() { jitEnabled = jit_check_debugged() }

    /// Milestone 0: JIT comes from the external StikDebug app, exactly as today. Milestone 1 replaces this with our own helper extension.
    func enableJIT() {
        if JITMethod.current != .inApp { enableJITThen { [weak self] in self?.refreshJIT() }; return }
        if BuiltinJIT.hasPairing {
            withTunnel { [weak self] in
                let started = BuiltinJIT.shared.start(
                    stage: { text in LogStore.shared.log("[jit] \(text)") },
                    onAttached: { [weak self] in self?.refreshJIT() },
                    report: { [weak self] message in self?.state = .failed(message) })
                _ = started
            }
            return
        }
        guard StikJITHelper.isAvailable else {
            state = .failed("StikDebug is not installed. Install it and try again.")
            return
        }
        StikJITHelper.enableJIT { [weak self] result in
            let ok: Bool = { if case .success = result { return true } else { return false } }()   // the helper now reports a Result
            Task { @MainActor in
                self?.refreshJIT()
                if !ok { self?.state = .failed("Could not open StikDebug.") }
            }
        }
    }

    /// Games with a known problem get their small workaround (see GameFixes) right before they start.
    private static var gluedPoolsSet = false
    private func applyKnownFixes(for game: Game) {
        let known = GameFixes.fix(forSteamAppID: game.dockAppID ?? game.steamAppID)
        // The address-space layout is decided once, when the runtime starts (virtual_ios.c ios_pa32_soft_enabled).
        if known?.paPool32 == true {
            setenv("MADEIRA_PA_POOL32_SOFT", "1", 1)
            if known?.singleProcessWeb == true { setenv("MADEIRA_ROCKSTAR_SINGLE_PROCESS", "1", 1) } else { unsetenv("MADEIRA_ROCKSTAR_SINGLE_PROCESS") }
            LogStore.shared.log("[game-fix] \(known!.title): a 32 GB-aligned pool is kept free for Chromium's allocator\(known?.singleProcessWeb == true ? ", and its web host runs single-process" : "")")
        } else { unsetenv("MADEIRA_PA_POOL32_SOFT"); unsetenv("MADEIRA_ROCKSTAR_SINGLE_PROCESS") }
        // Patch 0152: read once, when the runtime starts. The layout variable is only taken back if this fix set it (a game's own config line may be using it).
        if known?.gluedPools == true {
            setenv("MADEIRA_SC_PA_POOLS", "2", 1); setenv("MADEIRA_GLUED_MAIN", "1", 1); Self.gluedPoolsSet = true
            LogStore.shared.log("[game-fix] \(known!.title): the game's own process gets Social Club's layout for Chromium's 32 GB pools (layout 2: the emulator's arena starts 4 GB higher)")
        } else {
            unsetenv("MADEIRA_GLUED_MAIN")
            if Self.gluedPoolsSet { unsetenv("MADEIRA_SC_PA_POOLS"); Self.gluedPoolsSet = false }
        }
        guard let fix = known, let exe = AppModel.unixURL(forWindows: game.exe) else { return }
        for line in GameFixes.restoreFormer(fix, in: exe.deletingLastPathComponent()) { LogStore.shared.log("[game-fix] \(fix.title): \(line)") }
        for line in GameFixes.hide(fix, in: exe.deletingLastPathComponent()) { LogStore.shared.log("[game-fix] \(fix.title): \(line)") }
        // Wine reads this once, when the first library is loaded in this run, so it has to be set before the game starts.
        if !fix.blockLoading.isEmpty {
            setenv("WINEDLLOVERRIDES", fix.overridesValue, 1)
            LogStore.shared.log("[game-fix] \(fix.title): WINEDLLOVERRIDES=\(fix.overridesValue)")
        }
    }

    /// The game to hand to Wine for a launch without Steam: the same entry, but with the fix's own program when it names one. Only this launch changes;
    /// the Library entry (and what compatibility reports are filed under) stays as it is.
    private func programForDirectLaunch(_ game: Game, _ fix: GameFixes.Fix?) -> Game {
        guard let name = fix?.directProgram, let exe = AppModel.unixURL(forWindows: game.exe),
              let other = GameFixes.sibling(named: name, of: exe) else { return game }
        var target = game
        target.exe = GameFixes.windowsPath(replacingLastComponentOf: game.exe, with: other.lastPathComponent)
        LogStore.shared.log("[game-fix] \(fix!.title): running \(target.exe) instead of \(game.exe)")
        return target
    }

    /// The tour is over (or skipped): close it and start the game it was holding back.
    func finishTour() {
        guard let game = tourGame else { return }
        tourGame = nil
        // The tour's full-screen cover has to finish closing before the game's own cover can open.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.start(game)
        }
    }

    /// Set while the first-game tour is on screen (the game starts when it ends; see GameTourView). Nothing starts underneath it.
    @Published var tourGame: Game?

    func start(_ game: Game) {
        guard !isActive else { return }
        // The very first game: show how to play before the game takes over the screen, then start it (finishTour).
        if tourGame == nil, GuideCenter.shared.wantsFirstGameTour {
            GuideCenter.shared.markSeen(GuideCatalog.inGame.id)
            LogStore.shared.log("[guide] first-game tour before \(game.name)")
            tourGame = game
            return
        }
        guard !restartNeeded else {
            self.game = game
            state = .failed("Porthole has to close and open again before the next game starts. Use Close Porthole on the Home screen, then open it again.")
            return
        }
        launchCancelled = false; wineStarted = false; launchGameUp = false; launchPeeking = false; launchHold = false; restartAdvised = false; launchStep = .jit; launchBegan = Date()
        launchViaSteam = game.dockAppID != nil && game.launchDirect != true && GameFixes.fix(forSteamAppID: game.dockAppID ?? game.steamAppID)?.alwaysDirect != true
        self.game = game
        activeSettings = LaunchSettings.resolve(for: game)
        activeSettings.apply()
        activeLayout = game.controls ?? .standard
        activeTouchLayout = game.activeBindSet?.touch
        lookSensitivity = activeSettings.lookSensitivity
        // Fail early and clearly instead of starting Wine on a path that is not there.
        let isSystemPath = game.exe.lowercased().hasPrefix("c:\\windows\\")     // msiexec etc.: the prefix is created at the first launch
        guard isSystemPath || (AppModel.unixURL(forWindows: game.exe).map { FileManager.default.fileExists(atPath: $0.path) } ?? false) else {
            state = .failed("File not found: \(game.exe). Remove this entry and add the game again with +.")
            return
        }
        applyKnownFixes(for: game)
        let fix = GameFixes.fix(forSteamAppID: game.dockAppID ?? game.steamAppID)
        if let appID = game.dockAppID, game.launchDirect != true, fix?.alwaysDirect != true {
            startViaSteam(game, appID: appID)
            return
        }
        if fix?.alwaysDirect == true, game.dockAppID != nil, game.launchDirect != true {
            LogStore.shared.log("[game-fix] \(fix!.title): starting without Steam's launcher (\(fix!.why))")
        }
        let target = programForDirectLaunch(game, fix)
        if fix?.ownSteamIdentity == true, let id = game.dockAppID ?? game.steamAppID {
            // The runtime reads these once, for this launch only, and clears them (WineProcessBridge).
            let folder = GameFixes.windowsPath(replacingLastComponentOf: game.exe, with: "").dropLast()    // "C:\\...\\assettocorsa"
            setenv("MADEIRA_STEAM_APPID", String(id), 1)
            setenv("MADEIRA_STEAM_APPPATH", String(folder), 1)
            LogStore.shared.log("[game-fix] \(fix!.title): Steam identity app \(id), folder \(folder)")
        }
        if jit_check_debugged() {
            launchResolved(target)
        } else {
            state = .enablingJIT
            enableJITThen { [weak self] in guard let self, !self.launchCancelled else { return }; self.launchResolved(target) }
        }
    }

    /// An Epic game gets its short-lived exchange code only now, after JIT is on, so it is fresh when Wine starts (the code stays out of the saved game and the log).
    /// With no connection (airplane mode, or Epic's servers out of reach) the game starts without Epic's sign-in, like Epic's own launcher's offline mode: a single-player
    /// game just runs, and one that needs Epic's online services will say it cannot reach them.
    private func launchResolved(_ target: Game) {
        guard let appName = target.epicAppName else { launch(target); return }
        state = .starting
        Task { await EpicAuth.shared.probeCloudSaves(appName: appName) }      // read-only: only counts reach the log
        Task { @MainActor in
            var auth = ""
            do {
                auth = try await Self.withTimeout(seconds: 10) { try await EpicAuth.shared.gameArguments(appName: appName) }
            } catch {
                if Self.looksOffline(error) {
                    LogStore.shared.log("[epic] no connection to Epic (\(error.localizedDescription)): starting \(target.name) without Epic's sign-in")
                } else {
                    guard !launchCancelled else { return }
                    state = .failed((error as? EpicAuthError)?.message ?? error.localizedDescription)
                    return
                }
            }
            guard !launchCancelled else { return }
            var run = target
            run.args = [target.epicLaunchCommand ?? "", target.args, auth].filter { !$0.isEmpty }.joined(separator: " ")
            launch(run)
        }
    }

    private struct LaunchTimeout: Error {}

    /// The sign-in code could not be fetched because the network is not there (or too slow to be of use), as opposed to Epic refusing.
    private static func looksOffline(_ error: Error) -> Bool {
        if error is LaunchTimeout || error is URLError { return true }
        if let auth = error as? EpicAuthError, case .network = auth { return true }
        return false
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw LaunchTimeout() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Steam (Madeira Dock)

    /// Starts a Steam game through Valve's own client, which checks the licence. Nothing here bypasses it: without Valve's yes the game does not start.
    private func startViaSteam(_ game: Game, appID: Int) {
        func fail(_ text: String) { state = .failed(text); LogStore.shared.log("[dock] \(text)", level: .error) }
        guard MadeiraDock.enabled else { return fail("Steam launching is not built into this app. Turn on \"Run directly\" for this game.") }
        guard SteamSignIn.isSignedIn else { return fail("Sign in to Steam first (Steam panel on the home screen).") }
        guard MadeiraDock.clientInstalled else { return fail("Steam's client files are not installed yet. Open the Steam screen and download them, or run this game directly.") }
        // A game on the SSD is known from the catalog (it is checked after the drive is mapped, in prepareAndLaunchDock).
        guard let dockGame = MadeiraDock.games(drive: AppModel.driveC).first(where: { $0.id == appID }) ?? ExternalLibrary.shared.dockGame(appID: appID) else {
            return fail("Steam does not list \(game.name) as installed. Download it again from the Steam screen.")
        }
        if dockGame.storageID == SteamStorageLibrary.internalID {
            do { try MadeiraDock.validate(dockGame, drive: AppModel.driveC) } catch { return fail(error.localizedDescription) }
        }
        self.dockGame = dockGame
        let go: () -> Void = { [weak self] in guard let self, !self.launchCancelled else { return }; self.prepareAndLaunchDock(game, dockGame) }
        if jit_check_debugged() { state = .starting; go() }
        else { state = .enablingJIT; enableJITThen(go) }
    }

    static let cloudDownloadKey = "f4.cloudDownload"
    /// On unless the person turned it off (Settings), because Steam keeps these files for them anyway.
    static var cloudDownloadEnabled: Bool { UserDefaults.standard.object(forKey: cloudDownloadKey) as? Bool ?? true }

    /// Gives up after three minutes; whatever finished is kept (each file is written only when complete and checked).
    private func downloadCloudFiles(for dockGame: DockGame, installFolder: URL? = nil) async {
        dockStatus = "Checking your Steam Cloud files…"
        defer { dockStatus = nil }
        let appID = dockGame.id
        let report: SteamCloudReport? = await withTaskGroup(of: SteamCloudReport?.self) { group in
            group.addTask { @MainActor [weak self] in
                do {
                    return try await SteamService.shared.cloudDownload(appID: appID, driveC: AppModel.driveC, installFolder: installFolder) { done, total, name in
                        Task { @MainActor in self?.dockStatus = "Steam Cloud: \(name) (\(done) of \(total))" }
                    }
                } catch {
                    let why = (error as? SteamContentError)?.message ?? error.localizedDescription
                    LogStore.shared.log("[cloud] skipped: \(why)")
                    if why.contains("could be reached") || why.contains("TLS") || why.contains("No internet") { self?.steamUnreachable = true }
                    return nil
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(180)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let report { LogStore.shared.log("[cloud] \(report.summary)") } else { LogStore.shared.log("[cloud] nothing downloaded (see the lines above)") }
    }

    /// Remembered when Valve's client reports that it is waiting for content the game needs (launch error 17), so the next start installs the shared apps first even if the
    /// game's depots did not name them.
    static let needsSharedAppsKey = "f4.needsSharedApps"

    /// Installs the shared Steam apps this game needs (see SteamSharedApps) with Porthole's own downloader, while its Steam connection is still open. Valve's client
    /// never starts that download itself. A failure never stops the game from starting; it only means Steam will refuse it as before.
    private func installSharedApps(for dockGame: DockGame, steamApps: URL) async {
        var wanted = Set<Int>()
        if let info = await withTaskGroup(of: SteamAppInfo?.self, body: { group -> SteamAppInfo? in
            group.addTask { try? await SteamService.shared.appInfo(dockGame.id) }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }) { wanted.formUnion(SteamSharedApps.needed(by: info.depots, gameID: dockGame.id)) }
        if UserDefaults.standard.bool(forKey: Self.needsSharedAppsKey) { wanted.insert(SteamSharedApps.commonRedistributables) }
        for id in wanted.sorted() {
            guard let name = SteamSharedApps.known[id], !SteamSharedApps.isInstalled(appID: id, steamApps: steamApps) else { continue }
            LogStore.shared.log("[shared-apps] \(dockGame.id) needs \(name) (app \(id)); installing it")
            dockStatus = "Installing Steam's shared files (\(name))…"
            defer { dockStatus = nil }
            do {
                try FileManager.default.createDirectory(at: steamApps.appendingPathComponent("common", isDirectory: true), withIntermediateDirectories: true)
                _ = try await SteamService.shared.install(appID: id, name: name, steamApps: steamApps) { [weak self] progress in
                    let percent = Int(progress.fraction * 100)
                    self?.dockStatus = progress.totalBytes == 0 ? "Installing Steam's shared files (\(name))…" : "Installing Steam's shared files (\(name)): \(percent)%"
                }
                LogStore.shared.log("[shared-apps] \(name) is installed")
                UserDefaults.standard.set(false, forKey: Self.needsSharedAppsKey)
            } catch {
                LogStore.shared.log("[shared-apps] could not install \(name): \((error as? SteamContentError)?.message ?? error.localizedDescription)", level: .error)
            }
        }
    }

    /// This game's launch list straight from Steam, or nil if it does not arrive within 20 seconds.
    private func freshLaunchList(appID: Int) async -> [SteamLaunchOption]? {
        await withTaskGroup(of: [SteamLaunchOption]?.self) { group in
            group.addTask { try? await SteamService.shared.appInfo(appID).launches }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func prepareAndLaunchDock(_ game: Game, _ dockGame: DockGame) {
        state = .starting
        launchStep = .prepare
        prepareTask = Task { @MainActor in
            // A game on the SSD: the drive is mapped (E: and C:\MadeiraExternalLibrary, registered with Steam's client) and kept in scope until the session ends.
            var storageRoot: URL?
            var steamApps = SteamInstallPaths.steamApps(drive: AppModel.driveC)
            if dockGame.storageID != SteamStorageLibrary.internalID {
                dockStatus = "Connecting your SSD\u{2026}"
                do {
                    try await ExternalLibrary.shared.prepareSession(libraryID: dockGame.storageID)
                    guard let root = ExternalLibrary.shared.sessionAccess?.root else { throw SteamStorageError.unavailable(.disconnected) }
                    storageRoot = root
                    steamApps = try SteamStoragePath.native("steamapps", root: root)
                    try MadeiraDock.validate(dockGame, drive: AppModel.driveC, libraryRoot: root)
                } catch {
                    ExternalLibrary.shared.releaseSession(force: true)
                    dockStatus = nil
                    MadeiraDock.cleanup(); SteamStore.shared.dockEnded()
                    state = .failed(error.localizedDescription); LogStore.shared.log("[storage] \(error.localizedDescription)", level: .error)
                    return
                }
                dockStatus = nil
            }
            // Which of the game's numbered launch options Valve's client is asked for. The saved library list is used when it knows the numbers; a list saved by an
            // older build does not, so then this game's list is fetched fresh while our own Steam connection is still open (it closes just below).
            var resolvedOption = SteamLaunchOption.dockDefaultKey(in: SteamStore.shared.owned.first(where: { $0.id == dockGame.id })?.launches ?? [])
            var launchOptionSource = "from the saved library"
            if resolvedOption == nil {
                if let fresh = await freshLaunchList(appID: dockGame.id), let key = SteamLaunchOption.dockDefaultKey(in: fresh) {
                    resolvedOption = key; launchOptionSource = "fresh from Steam"
                } else { launchOptionSource = "this game's launch list was not available; using the default" }
            }
            // Valve's client looks the number up in its OWN cached copy of the app's information, which can be older than ours (PEAK: ours said 0, its cache had no
            // entry 0, "Failed running app (entry for launch option 0 not found)"). If its list is readable and does not have our number, use one it has.
            let valveEntries = ValveAppInfoCache.launches(appID: dockGame.id, steamFolder: AppModel.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true))
            if let valveEntries {
                LogStore.shared.log("[dock] Valve's cached launch entries for this game: " + (valveEntries.isEmpty ? "none" : valveEntries.map { "\($0.key)=\($0.executable)[\($0.type)/\($0.oslist)/\($0.osarch)]" }.joined(separator: ", ")))
            } else { LogStore.shared.log("[dock] Valve's client has no cached information for this game yet") }
            if let valveEntries, !valveEntries.isEmpty, !valveEntries.contains(where: { $0.key == (resolvedOption ?? 0) }), let key = ValveAppInfoCache.defaultKey(in: valveEntries) {
                resolvedOption = key; launchOptionSource = "from Valve's own cached list (ours had no entry it knows)"
            }
            let launchOption = resolvedOption ?? 0
            // Steam Cloud, download only: the person's own cloud files for this game come first, while our Steam connection is still open (Valve's client, started below,
            // does not do this step when the Dock launches a game). A failure or a slow answer never stops the game from starting.
            let gameFolder = storageRoot.flatMap { try? SteamStoragePath.native(dockGame.library + "/common/" + dockGame.installDir, root: $0) }
            // A game started through Steam has no program path in the Library, so its known fix (files set aside) is applied to the install folder here.
            if let fix = GameFixes.fix(forSteamAppID: dockGame.id), !fix.hide.isEmpty || !fix.formerlyHidden.isEmpty {
                let folder = gameFolder ?? SteamInstallPaths.common(drive: AppModel.driveC).appendingPathComponent(dockGame.installDir, isDirectory: true)
                for line in GameFixes.restoreFormer(fix, in: folder) { LogStore.shared.log("[game-fix] \(fix.title): \(line)") }
                let done = fix.hide.isEmpty ? ["unused"] : GameFixes.hide(fix, in: folder)
                for line in done where line != "unused" { LogStore.shared.log("[game-fix] \(fix.title): \(line)") }
                // A fix that quietly does nothing is hard to find: say where it looked.
                if done.isEmpty && !fix.hide.isEmpty { LogStore.shared.log("[game-fix] \(fix.title): nothing to set aside in \(folder.path) (\(fix.hide.joined(separator: ", ")))") }
            }
            steamUnreachable = false
            if Self.cloudDownloadEnabled {
                await downloadCloudFiles(for: dockGame, installFolder: gameFolder)
            }
            if launchCancelled { ExternalLibrary.shared.releaseSession(force: true); return }
            await installSharedApps(for: dockGame, steamApps: steamApps)
            if launchCancelled { ExternalLibrary.shared.releaseSession(force: true); return }
            // One sign-in at a time: this app's own Steam connection closes before Valve's client signs in.
            await SteamStore.shared.prepareForDock()
            if launchCancelled { MadeiraDock.cleanup(); SteamStore.shared.dockEnded(); ExternalLibrary.shared.releaseSession(force: true); return }
            do {
                guard let credentials = SteamSignIn.credentialsForDock() else { throw DockError.message("Sign in to Steam again.") }
                try MadeiraDock.writeHandoff(account: credentials.accountName, token: credentials.refreshToken, appID: dockGame.id)
            } catch {
                MadeiraDock.cleanup(); SteamStore.shared.dockEnded(); ExternalLibrary.shared.releaseSession(force: true)
                state = .failed(error.localizedDescription); return
            }
            // The game's install record needs its language (Valve's client answers a game's "what language am I in?" from it); installs made by older builds lack it.
            if SteamManifestLanguage.ensure(appID: dockGame.id, steamApps: steamApps) { LogStore.shared.log("[dock] added the language to \(dockGame.id)'s Steam install record") }
            if SteamClientLanguage.ensure(prefix: AppModel.prefix) { LogStore.shared.log("[dock] set Steam's language in the prefix registry") }
            // Valve's client is asked for one of the game's numbered launch options. Madeira's host reads it from MADEIRA_STEAM_HOST_LAUNCH_OPTION, which configure() always sets
            // (0 unless it is given one: Factorio's options are 1, 2, 3 and 5, so 0 made Steam refuse and the host retry forever). Our own variable below is only the fallback.
            MadeiraDock.configure(dockGame, launchOption: UInt32(clamping: launchOption))
            if launchOption != 0 { setenv("MADEIRA_DOCK_LAUNCH_OPTION", String(launchOption), 1) } else { unsetenv("MADEIRA_DOCK_LAUNCH_OPTION") }
            // A game whose listed program cannot run here (Rust: Easy Anti-Cheat's launcher) gets its own program started next to Valve's client instead of
            // Valve's LaunchApp (patch 0075). The host refuses anything outside the app's verified install folder.
            unsetenv("MADEIRA_DOCK_PROGRAM"); unsetenv("MADEIRA_DOCK_PROGRAM_ARGS")
            if let name = GameFixes.fix(forSteamAppID: dockGame.id)?.steamProgram, let listed = AppModel.unixURL(forWindows: game.exe),
               let own = GameFixes.sibling(named: name, of: listed) {
                let windows = GameFixes.windowsPath(replacingLastComponentOf: game.exe, with: own.lastPathComponent)
                setenv("MADEIRA_DOCK_PROGRAM", windows, 1)
                setenv("MADEIRA_DOCK_PROGRAM_ARGS", game.args, 1)
                LogStore.shared.log("[game-fix] \(GameFixes.fix(forSteamAppID: dockGame.id)!.title): starting \(windows) next to Steam's client instead of asking Steam to launch the game")
            }
            LogStore.shared.log("[dock] launch option \(launchOption) (\(launchOptionSource))")
            // The game's one-time installs (its Steam install script) run first, in the same session.
            DockInstallers.prepare(dockGame, drive: AppModel.driveC, prefix: AppModel.prefix, externalRoot: storageRoot)
            EngineLaunch.launcherNeedsRoom = DockInstallers.serverSync   // Porthole 0089: more room for the launcher's own libraries (RDR2 filled 896 MB)
            // Porthole 0102: and keep plain x64 programs out of the code pool (patch 0029, opt-in until now). Rockstar's launcher is a Chromium program:
            // libcef.dll is 250 MB and the launcher and its Social Club helper each load it, which no pool has room for; nothing runs from those copies.
            // An `env.MADEIRA_X64_IMAGE_DATA` line of the game (Engine options) still wins, as every env.* line does.
            if DockInstallers.serverSync {
                setenv("MADEIRA_X64_IMAGE_DATA", "1", 1)
                LogStore.shared.log("[engine] plain x64 programs stay out of the code pool (a launcher with its own service is running)")
            } else if (MadeiraConfig.get("env.MADEIRA_X64_IMAGE_DATA") ?? "").isEmpty { unsetenv("MADEIRA_X64_IMAGE_DATA") }
            if DockInstallers.serverSync { setenv("MADEIRA_MADSYNC_SESSION", "0", 1) } else { unsetenv("MADEIRA_MADSYNC_SESSION") }
            // The programs Valve's client starts are often 32-bit: they need the shared GDI handle table (Madeira's Dock setup).
            setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)
            launch(game, dock: dockGame)
        }
    }

    private var prepareTask: Task<Void, Never>?
    /// Porthole's own connection to Steam failed before the launch (the network blocks Steam, or there is none): Valve's client in the game is likely to fail the same way.
    private var steamUnreachable = false
    /// Valve's client refuses to start the game until its content is current (the launch screen then says why instead of "Signing in").
    @Published private(set) var launchHold = false
    private var dockPollStarted = Date()
    private var warnedSlowSteam = false

    private func beginDockPolling() {
        dockPoll?.invalidate()
        dockPollStarted = Date(); warnedSlowSteam = false
        dockStatus = "Waiting for Steam\u{2026}"
        dockPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dockGame != nil else { return }
                let report = MadeiraDock.pollReport()
                if let failure = report.failure {
                    self.endDockPolling()
                    LogStore.shared.log("[dock] \(failure)", level: .error)
                    self.dockStatus = failure
                    self.state = .failed(failure)
                } else if report.result == 0 {
                    self.endDockPolling(); self.dockStatus = nil
                } else if report.fields["launch-update-wait"] != nil {
                    // Valve's client says the game needs content it will not fetch on its own (its shared files). Porthole installs them at the next start.
                    UserDefaults.standard.set(true, forKey: Self.needsSharedAppsKey)
                    self.launchHold = true
                    // Valve's client will not start the game until its content is current, and it cannot download here. Say what to do: an update (a newer build is on Steam), or a repair.
                    if let id = self.dockGame?.id, let owned = SteamStore.shared.owned.first(where: { $0.id == id }), SteamStore.shared.updateAvailable(owned) {
                        self.dockStatus = "Steam says \(owned.name) needs an update. Close the game, open it under Stores > Steam and tap Update, then start it again."
                    } else {
                        self.dockStatus = "Steam is waiting for content this game needs, which it cannot download here. Close the game and start it again: Porthole will install shared files first. If it stays like this, open the game under Stores > Steam > Details and files and use Verify files (it fixes files Steam marked as damaged)."
                    }
                } else if report.fields["launch-client-error"] == "0" {
                    // Valve's client accepted the licence and started the game; what is left is the game loading (a first start can take minutes).
                    self.dockStatus = "Steam started the game. Loading\u{2026} the screen stays black until the game opens its window (first start can take a few minutes)."
                    self.launchStep = .load
                } else if report.fields["session-requested-app-entitled"] == "1" {
                    self.dockStatus = "Licence confirmed by Steam. Starting the game\u{2026}"
                    self.launchStep = .signIn
                } else if report.fields["session-authenticated-online"] == "1" {
                    self.dockStatus = "Steam is checking your licence\u{2026}"
                    self.launchStep = .signIn
                } else if report.fields["load-client-begin"] != nil {
                    self.dockStatus = "Starting Steam\u{2026}"
                    self.launchStep = .steam
                }
                // Steam's client has not signed in after a while: usually the network is blocking Steam. Say so, instead of waiting in silence.
                let waited = Date().timeIntervalSince(self.dockPollStarted)
                if waited > (self.steamUnreachable ? 12 : 40), report.fields["session-authenticated-online"] != "1", report.fields["launch-client-error"] == nil, report.failure == nil {
                    if !self.warnedSlowSteam {
                        self.warnedSlowSteam = true
                        LogStore.shared.log("[dock] Steam has not signed in after \(Int(waited)) s" + (self.steamUnreachable ? " (Porthole's own connection to Steam failed too)" : ""), level: .error)
                    }
                    self.dockStatus = "Steam hasn't signed in yet. Check your internet connection, then start the game again. Porthole keeps trying meanwhile."
                }
            }
        }
    }

    private func endDockPolling() { dockPoll?.invalidate(); dockPoll = nil }

    /// Switches JIT on with the method the person chose (Settings > Setup guide). The app's own tunnel is brought up first for every method:
    /// it stands in for LocalDevVPN, so StikDebug and other tools can reach the device's debug service without another VPN app.
    private func enableJITThen(_ proceed: @escaping () -> Void) {
        switch JITMethod.current {
        case .inApp:
            guard BuiltinJIT.hasPairing else {
                state = .failed("In-app JIT needs a pairing file. Open Settings \u{203A} Setup guide to import one, or choose a different JIT method there.")
                return
            }
            withTunnel { [weak self] in
                let started = BuiltinJIT.shared.start(
                    stage: { text in LogStore.shared.log("[jit] \(text)") },
                    onAttached: { [weak self] in self?.refreshJIT(); proceed() },
                    report: { [weak self] message in self?.state = .failed(message) })
                _ = started   // on failure `report` has already put the reason on screen; there is deliberately no silent fallback to a different mechanism
            }
        case .stikDebug:
            guard StikJITHelper.isAvailable else {
                state = .failed("StikDebug is not installed. Install it, or choose a different JIT method in Settings \u{203A} Setup guide.")
                return
            }
            withTunnel {
                StikJITHelper.enableJIT { [weak self] result in
                    let ok: Bool = { if case .success = result { return true } else { return false } }()   // the helper now reports a Result
                    Task { @MainActor in
                        guard let self else { return }
                        self.refreshJIT()
                        if ok { proceed() } else { self.state = .failed("Could not open StikDebug.") }
                    }
                }
            }
        case .other:
            withTunnel { [weak self] in self?.waitForOtherTool(proceed) }
        }
    }

    /// JITMethod.other: nothing to start; just wait for the person's own tool to switch JIT on (up to five minutes).
    private func waitForOtherTool(_ proceed: @escaping () -> Void) {
        if jit_check_debugged() { refreshJIT(); proceed(); return }
        jitWaitMessage = "Waiting for JIT. Turn it on for Porthole with your tool now, then come back to this app."
        LogStore.shared.log("[jit] waiting for another tool to enable JIT")
        let started = Date()
        jitWaitTimer?.invalidate()
        jitWaitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if jit_check_debugged() {
                    timer.invalidate(); self.jitWaitTimer = nil; self.jitWaitMessage = nil
                    self.refreshJIT(); LogStore.shared.log("[jit] JIT is on (set by another tool)", level: .success)
                    proceed()
                } else if Date().timeIntervalSince(started) > 300 {
                    timer.invalidate(); self.jitWaitTimer = nil; self.jitWaitMessage = nil
                    self.state = .failed("JIT was not turned on within five minutes. Try again, or pick a different JIT method in Settings \u{203A} Setup guide.")
                }
            }
        }
    }

    /// Brings our own tunnel up first. If it cannot come up we carry on anyway, in case another VPN (LocalDevVPN) is already providing the tunnel.
    private func withTunnel(_ then: @escaping () -> Void) {
        Task { @MainActor in
            // Cellular data would stop the tunnel from working: ask first, and switch it off once the tunnel is up (CellularGuard).
            guard await CellularGuard.shared.confirm(for: "turn on JIT") else {
                if self.state == .enablingJIT { self.state = .idle; self.game = nil }
                return
            }
            // A VPN of the person's own would be switched off by ours: ask first, and remember to bring it back.
            guard await VPNGuard.shared.confirmPause(for: "turn on JIT", until: state == .enablingJIT ? "the game closes" : "JIT is on") else {
                CellularGuard.shared.disarm()
                if self.state == .enablingJIT { self.state = .idle; self.game = nil }
                return
            }
            do {
                LogStore.shared.log("[tunnel] starting")
                try await TunnelManager.shared.connect()
                LogStore.shared.log("[tunnel] connected", level: .success)
            } catch {
                LogStore.shared.log("[tunnel] \(error.localizedDescription) Trying anyway in case LocalDevVPN is on.", level: .error)
                // With the in-app method our own tunnel is the only way to reach the debug service, so carrying on would only fail later with a vaguer
                // message. Say what to do instead (restarting the device clears this after an update).
                if JITMethod.current == .inApp, case TunnelManager.TunnelError.refusedAtStart = error {
                    CellularGuard.shared.disarm()
                    self.state = .failed(error.localizedDescription)
                    return
                }
            }
            // The tunnel is up while cellular data still works; only now does cellular data go off, so the tunnel is already connected when there is no network.
            if CellularGuard.shared.armed {
                guard await CellularGuard.shared.switchOff() else {
                    self.state = .failed(CellularGuard.shared.lastProblem ?? "Cellular data could not be switched off, so the private connection cannot work.")
                    return
                }
            }
            then()
        }
    }

    func dismiss() {
        if !isActive { state = .idle; game = nil }
    }

    /// Saves "last played" at the start and the play time once a minute, so a game that closes the whole app still counts.
    private func beginPlayCheckpoints() {
        playTimer?.invalidate()
        playCheckpoint = Date()
        if let g = game { AppModel.shared.recordPlay(g, seconds: 0) }
        playTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCheckpoint() }
        }
    }

    private func saveCheckpoint() {
        guard let g = game, let last = playCheckpoint else { return }
        let now = Date()
        AppModel.shared.recordPlay(g, seconds: now.timeIntervalSince(last))
        playCheckpoint = now
    }

    private func endPlayCheckpoints() {
        playTimer?.invalidate(); playTimer = nil
        saveCheckpoint()
        playCheckpoint = nil
    }

    /// Closes the app on purpose (after a game, so the next one starts in a fresh process).
    func closeApp() {
        LogStore.shared.log("[session] closing the app so the next game starts fresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    private func launch(_ game: Game, dock: DockGame? = nil) {
        state = .starting
        wineStarted = true                       // from here the runtime is committed: the launch can no longer be taken back
        restartNeeded = true
        launchStep = dock != nil ? .steam : .load
        startLaunchWatch(for: game, steam: dock != nil)
        let prefix = AppModel.prefix.path
        // The screen size the game sees: the game's own resolution setting, else the app-wide one (Settings > Display).
        let screen = activeSettings.displaySize
        setenv("MADEIRA_SCREEN_W", String(screen.width), 1)
        setenv("MADEIRA_SCREEN_H", String(screen.height), 1)
        LogStore.shared.log("[display] screen size \(screen.text) (\(activeSettings.resolution))")
        if dock != nil {
            if activeSettings.dockDesktop {
                // Wine's explorer opens a virtual desktop and starts the Dock host in it; the host asks Valve's client to launch the game.
                setenv("MADEIRA_EXE", "explorer.exe", 1)
                setenv("MADEIRA_ARGS", MadeiraDock.launchArguments(width: screen.width, height: screen.height, installers: DockInstallers.script), 1)
                setenv("MADEIRA_DESKTOP", "1", 1)
                winios_display_mode_changed(Int32(screen.width), Int32(screen.height))
                LogStore.shared.log("[dock] display: Wine desktop (separate compositor layer)")
            } else {
                // One display: the host (or the game's one-time installers, then the host) runs directly; every game window presents into our game view.
                if let installers = DockInstallers.script {
                    setenv("MADEIRA_EXE", "C:\\windows\\system32\\cmd.exe", 1)
                    setenv("MADEIRA_ARGS", "/c call \(installers) & \(MadeiraDock.executable)", 1)
                } else {
                    setenv("MADEIRA_EXE", MadeiraDock.executable, 1)
                    setenv("MADEIRA_ARGS", "", 1)
                }
                unsetenv("MADEIRA_DESKTOP")
                LogStore.shared.log("[dock] display: single (game view)")
            }
            // The game's "Launch options": Valve's client reads them from localconfig.vdf, so they go there before it starts (nothing runs yet).
            DockLaunchOptions.apply(game.args, appID: dock!.id, drive: AppModel.prefix.appendingPathComponent("drive_c")) { LogStore.shared.log($0) }
            // Steam's per-controller-type switches (Steam Input): shown in the log, and the PlayStation one turned on when Steam's controller support is downloaded.
            SteamInputConfig.apply(drive: AppModel.prefix.appendingPathComponent("drive_c"), playStation: ControllerInput.shared.kind.isPlayStation) { LogStore.shared.log($0) }
            MadeiraDock.requestLaunch(compactPool: false)
            LogStore.shared.log("[dock] starting the host for app \(dock!.id)")
            beginDockPolling()
        } else {
            setenv("MADEIRA_EXE", game.exe, 1)
            setenv("MADEIRA_ARGS", game.args, 1)
            // A program started without Steam gets its own log file too (Documents/logs/<program>-<time>.txt). The Steam ones are named by the engine;
            // nothing called this for direct starts, so a direct run left only madeira-log.txt.
            if game.installer != true { LogStore.shared.startSessionLog(program: String(game.exe.split(separator: "\\").last ?? Substring(game.exe))) }
            if let batch = EngineLaunch.batchCommand(for: game) {
                setenv("MADEIRA_EXE", batch.exe, 1); setenv("MADEIRA_ARGS", batch.args, 1)
                LogStore.shared.log("[run] batch file through cmd.exe: \(batch.args)")
            }
            if let folder = EngineLaunch.workDir(for: game) { setenv("MADEIRA_WORKDIR", folder, 1); LogStore.shared.log("[run] working folder \(folder)") } else { unsetenv("MADEIRA_WORKDIR") }
            if game.inDesktop == true, game.installer != true, let script = AppModel.steamClientScript(exe: game.exe, extraArgs: game.args) {
                // The real Steam client is started the way Madeira's own Steam test does it: Wine's service manager first, then steam.exe with
                // the options that make it work in Wine (no sandbox, software rendering, no crash monitor).
                setenv("MADEIRA_EXE", "C:\\windows\\syswow64\\cmd.exe", 1)   // the 32-bit cmd: its session is the aarch64 + 32-bit one steam.exe needs
                setenv("MADEIRA_ARGS", "/c \(script)", 1)
                LogStore.shared.log("[steam] started through \(script) (services.exe + Steam options)")
            }
            if game.inDesktop == true {
                // Wine's desktop display: the compositor draws ordinary Windows windows (installers, launchers, tools). The program starts directly, so
                // a path with spaces is fine (only arguments are split at spaces). 32-bit programs need the shared GDI handle table.
                setenv("MADEIRA_DESKTOP", "1", 1)
                setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)
                winios_display_mode_changed(Int32(screen.width), Int32(screen.height))
                LogStore.shared.log("[run] \(game.exe) \(game.epicAppName == nil ? game.args : "<Epic launch arguments>") on the Wine desktop")
                if game.installer != true {
                    let moved = AppModel.sidelineBundledUCRT(forExe: game.exe)
                    if !moved.isEmpty { LogStore.shared.log("[fix] built-in ucrtbase used instead of the program's own copy: \(moved.count) file(s), e.g. \(moved[0])") }
                }
                if game.installer == true { UserDefaults.standard.set(game.name, forKey: "f4.installerRan") }
            } else {
                unsetenv("MADEIRA_DESKTOP")
            }
        }
        EngineLaunch.apply(for: game)   // this game's engine settings (AVX, frame generation, its own config lines ...)
        ProMotionHold.shared.frameGeneration = game.engine?.frameGeneration == true
        ProMotionHold.shared.begin()
        SchedHints.begin()
        GameLogTail.begin()
        SteamOverlayBlock.apply(drive: AppModel.prefix.appendingPathComponent("drive_c")) { LogStore.shared.log($0) }
        PadInput.shared.beginSession(for: game, viaSteam: launchViaSteam)   // physical controllers for this game (before the wineserver reads MADEIRA_HIDPAD)
        // Exact shader math (patches/0004). Read once by the shader translator, so it only applies to the next launch.
        let precise = activeSettings.preciseMath
        setenv("MADEIRA_PRECISE_MATH", precise ? "1" : "0", 1)
        LogStore.shared.log("[shaders] precise math \(precise ? "ON" : "off")")
        // The graphics layer's memory census prints ~14 lines per frame batch (hundreds of thousands per session); the same report once per 10 s says
        // the same thing and costs far less CPU, log writing and parsing. (Madeira turns this on by default only for 32-bit.)
        setenv("DXMT_CENSUS_THROTTLE", "1", 1)
        // Debug: save a picture of every Windows window's contents (Files > Porthole > surfdump) to see what the program really drew.
        // Debug: Wine debug channels (e.g. +msg for window messages). Empty = Wine's default (quiet). Output goes into the log.
        if let ch = UserDefaults.standard.string(forKey: "f4.wineDebug")?.trimmingCharacters(in: .whitespaces), !ch.isEmpty {
            setenv("WINEDEBUG", ch, 1); LogStore.shared.log("[debug] WINEDEBUG=\(ch)")
            // +msg also switches on our own message trace ([f4-msg] / [f4-mouse] lines: what reaches each window procedure).
            if ch.contains("+msg") { setenv("MADEIRA_MSGTRACE", "1", 1) } else { unsetenv("MADEIRA_MSGTRACE") }
            // +sock records the first bytes of every external TCP socket's traffic (TLS record types) — the Steam connection hunt.
            if ch.contains("+sock") { setenv("MADEIRA_SOCK_WIRE", "1", 1) } else { unsetenv("MADEIRA_SOCK_WIRE") }
        } else { unsetenv("WINEDEBUG"); unsetenv("MADEIRA_MSGTRACE") }
        if UserDefaults.standard.bool(forKey: "f4.dumpSurfaces") { setenv("MADEIRA_DUMP_SURFACES", "1", 1) } else { unsetenv("MADEIRA_DUMP_SURFACES") }
        // The engine's audio keeps this much sound queued ahead (10...500 ms; 0 = no queue, the plain 10 ms beat). Older engines read MADEIRA_AUDIO_CUSHION_MS, which nothing reads now.
        unsetenv("MADEIRA_AUDIO_CUSHION_MS")
        setenv("MADEIRA_AUDIO_LEAD_MS", String(max(0, min(500, activeSettings.audioCushionMs))), 1)
        LogStore.shared.log("[audio] lead \(activeSettings.audioCushionMs) ms")
        LogStore.shared.uiPaused = true
        ws_log_quiet = 1
        PowerManager.shared.start()   // frame cap + eco, before the game draws anything

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let log = LogStore.shared
            // Give back the reserved 0x140000000 window when none of the game's programs needs it: the pool then fits in one piece (see ExecutableWindow.swift).
            // Windows system programs (installers run from C:\windows) and anything unreadable keep it, as before.
            if let exe = AppModel.unixURL(forWindows: game.exe), !game.exe.lowercased().hasPrefix("c:\\windows\\") {
                let verdict = ExecutableWindow.releaseReason(forProgram: exe)
                log.log("[exe-window] \(verdict.release ? "can be given back" : "kept"): \(verdict.text)")
                StikJITHelper.releaseExeWindowReason = verdict.release ? verdict.text : nil
            } else {
                StikJITHelper.releaseExeWindowReason = nil
                log.log("[exe-window] kept: a Windows system program")
            }
            let poolBytes = EngineLaunch.poolBytes()
            log.log("Allocating \(poolBytes >> 20)MB JIT pool (the debugger services a BRK)...")
            guard let pool = StikJITHelper.allocatePool(poolSize: poolBytes) else {
                log.log("JIT pool allocation failed. Force-quit and relaunch.", level: .error)
                DispatchQueue.main.async {
                    ws_log_quiet = 0
                    LogStore.shared.uiPaused = false
                    self?.state = .failed("JIT pool allocation failed. Force-quit the app and try again.")
                }
                return
            }
            // A Dock session publishes no fixed Steam identity to its guests: Valve's client gives each game its own.
            let dockLaunch = MadeiraDock.takeLaunchRequest()
            // Valve's client and the game together need about 600 MB of the JIT pool and more as the game loads. When iOS has put something in the spot the pool normally takes (it is a
            // matter of where the system placed memory in this one start of the app), the pool shrinks, and a Steam game runs out of memory a minute later. Say so now, before it starts.
            if dockLaunch.dock, pool.size < Self.minimumSteamPool {
                log.log("[launch] the JIT pool is only \(pool.size >> 20) MB on this start of the app (a Steam game needs about \(EngineLaunch.poolBytes() >> 20)); not starting the game", level: .error)
                StikJITHelper.detachDebugger()
                CellularGuard.restoreBlocking()
                VPNGuard.restoreBlocking()
                DispatchQueue.main.async {
                    ws_log_quiet = 0
                    LogStore.shared.uiPaused = false
                    PowerManager.shared.stop()
                    self?.restartAdvised = true
                    self?.state = .failed("iOS left too little room for this game on this start of Porthole (\(pool.size >> 20) MB of the \(poolBytes >> 20) MB it needs). Close Porthole and open it again, then start the game: it is different each time.")
                }
                return
            }
            if dockLaunch.dock { setenv("MADEIRA_DOCK_SESSION", "1", 1) } else { unsetenv("MADEIRA_DOCK_SESSION") }
            // A Dock session runs Valve's client headless, with no Chromium, so nothing claims the 8 GB address-space holdback reserved for Chromium's V8 cage.
            // The engine hands it to the allocator when the guest band runs out (virtual_ios.c ios_cage_release_on_exhaustion; off unless this is 1). Madeira's own
            // app sets it for every Dock session; Porthole did not, and Rust's band filled up (16.3 of 16.4 GB) while the holdback sat idle.
            if dockLaunch.dock { setenv("MADEIRA_CAGE_RELEASE", "1", 1) } else { unsetenv("MADEIRA_CAGE_RELEASE") }
            setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
            setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
            setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            StikJITHelper.detachDebugger()
            // JIT is set up and the debugger has gone: if cellular data was switched off for the tunnel, switch it back on now, before the game starts
            // (leaves the app for a moment; does nothing otherwise).
            CellularGuard.restoreBlocking()
            // The person's own VPN, paused for the tunnel, comes back now too: some networks block Steam without it, and the game's Steam client signs in as the game starts.
            VPNGuard.restoreBlocking()

            log.log("Starting wineserver...")
            guard wineserver_start(prefix) == 0 else {
                DispatchQueue.main.async { self?.state = .failed("wineserver failed to start") }
                return
            }
            EngineLaunch.waitForWineserver()   // the server's own "ready" signal, at most the old 2 s pause
            log.log("Starting Wine process: \(game.exe)")
            wine_exit_status_reset()
            guard wine_process_start(prefix) == 0 else {
                DispatchQueue.main.async { self?.state = .failed("Wine process failed to start") }
                return
            }
            DispatchQueue.main.async {
                self?.runningSince = Date(); self?.state = .running
                if let dockGame = self?.dockGame {   // achievement pop-ups: Steam's client in the game writes each unlock into its stats file
                    SteamOverlayWatcher.shared.start(steamFolder: AppModel.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true),
                                                     isRunning: { [weak self] in self?.state == .running }) {
                        guard AchievementToastCenter.overlayOpensMenu else { return }
                        NotificationCenter.default.post(name: .steamOverlayRequested, object: nil)
                    }
                    AchievementToastCenter.shared.clear()
                    SteamAchievementWatcher.shared.start(steamFolder: AppModel.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true),
                                                         account: SteamService.shared.accountNumber, appID: dockGame.id, isRunning: { [weak self] in self?.state == .running }) { achievement in
                        AchievementToastCenter.shared.post(achievement, appID: dockGame.id)
                    }
                }
                self?.beginPlayCheckpoints()
                if let g = self?.game {
                    CompatStore.shared.sessionBegan(g)
                    Telemetry.shared.onCheckpoint = { stats in Task { @MainActor in CompatStore.shared.checkpoint(stats) } }
                }
                // JIT finished long ago and the debugger has detached; the tunnel has nothing left to do, so turn it off (a few seconds after the
                // game process starts, never while JIT is still being set up).
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { TunnelManager.shared.disconnect() }
            }
            // A game that crashes on a worker thread (an access violation on a Unity or Mono thread, say) is gone, but Wine's main thread for it keeps waiting, so the process
            // never "ends" and the screen stays on the last picture. ntdll reports the crash status of the program the app started (wine_launched_process_did_exit); a few
            // seconds after it does, the session counts as over.
            var crashSeen: Date?
            while wine_process_is_running() != 0 {
                var status: UInt32 = 0
                if wine_crash_exit_status(&status) != 0 {
                    if crashSeen == nil {
                        crashSeen = Date()
                        let hex = String(status, radix: 16, uppercase: true)
                        DispatchQueue.main.async { LogStore.shared.log("[session] the game stopped with error 0x\(hex) (a crash); ending the session in 4 seconds") }
                    } else if Date().timeIntervalSince(crashSeen!) > 4 {
                        DispatchQueue.main.async { LogStore.shared.log("[session] the game's process is gone but Wine is still running; the session is over") }
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                ws_log_quiet = 0
                LogStore.shared.uiPaused = false
                PowerManager.shared.stop()
                PadInput.shared.endSession(); ProMotionHold.shared.end(); SchedHints.end(); GameLogTail.end()
                AutoBackup.afterSession()
                self?.endPlayCheckpoints()
                if let g = self?.game, self?.runningSince != nil {
                    self?.runningSince = nil
                    if g.installer != true { CompatStore.shared.sessionEnded(g, stats: Telemetry.shared.sessionStats()) }
                }
                if self?.dockGame != nil {
                    self?.endDockPolling(); self?.dockGame = nil; self?.dockStatus = nil
                    MadeiraDock.cleanup(); SteamStore.shared.dockEnded()
                }
                winios_window_census_enable(0)   // the late restore of windows first shown minimized (PR 243) ends with the session
                self?.state = .ended
            }
        }
    }

    /// Ask the game to close (Alt+F4). The runtime cannot be restarted reliably in-process, so after a game ends the app should be relaunched.
    func requestClose() {
        winios_post_key(0x12, 1); winios_post_key(0x73, 1); winios_post_key(0x73, 0); winios_post_key(0x12, 0)
    }
}


// MARK: - The launch screen

extension SessionController {
    /// Whether the launch screen should be up: from pressing Play until the game's own window has put a picture on screen (or the launch failed).
    var launchOverlayActive: Bool {
        guard let g = game, g.installer != true, g.inDesktop != true else { return false }
        switch state {
        case .enablingJIT, .starting, .failed: return true
        case .running: return !launchGameUp
        default: return false
        }
    }

    /// What the launch screen shows right now.
    var launchData: LaunchData? {
        guard launchOverlayActive, let g = game else { return nil }
        let steam = launchViaSteam
        let plan: [(LaunchStep, String)] = steam
            ? [(.jit, "Turn on JIT"), (.prepare, "Get Steam ready"), (.steam, "Start Steam"), (.signIn, "Sign in to Steam"), (.load, "Load the game")]
            : [(.jit, "Turn on JIT"), (.load, "Start the game")]
        let current = state == .enablingJIT ? LaunchStep.jit : launchStep
        let steps = plan.map { item in
            LaunchStepData(id: "\(item.0.rawValue)", title: item.1, state: item.0.rawValue < current.rawValue ? .done : (item.0 == current ? .active : .pending))
        }
        let headline: String, detail: String
        switch current {
        case .jit:
            headline = jitWaitMessage != nil ? "Waiting for JIT" : "Turning on JIT"
            detail = jitWaitMessage ?? "JIT lets games run at full speed. Porthole switches it on through a private link on this device; the first time can take a little while."
        case .prepare:
            headline = (dockStatus ?? "Getting Steam ready").replacingOccurrences(of: "\u{2026}", with: "")
            detail = "Before Steam starts, Porthole brings down your Steam Cloud saves and installs any shared files the game needs."
        case .steam:
            headline = "Starting Steam"
            detail = "Valve's own Steam client runs inside Porthole. It checks that you own the game before it opens."
        case .signIn:
            headline = launchHold ? "Steam won't start the game yet" : "Signing in to Steam"
            detail = launchHold ? (dockStatus ?? "Steam needs this game's files to be up to date first.") : "Steam is confirming your licence for this game."
        case .load:
            headline = "Loading the game"
            detail = "The first start of a game can take a few minutes while it builds its caches. The screen stays here until the game's window appears."
        }
        var chips = [LaunchSettingChip(symbol: steam ? "shield.checkered" : "play.fill", text: steam ? "Through Steam" : "Run directly"),
                     LaunchSettingChip(symbol: "display", text: activeSettings.displaySize.text),
                     LaunchSettingChip(symbol: "bolt.fill", text: activeSettings.power.title)]
        if activeSettings.swapMB > 0 { chips.append(LaunchSettingChip(symbol: "internaldrive", text: "Swap \(activeSettings.swapMB / 1024) GB")) }
        var failure: String?
        if case .failed(let message) = state { failure = message }
        return LaunchData(gameID: g.id, name: g.name, steps: steps, headline: headline, detail: detail, chips: chips, failure: failure, cleanCancel: !wineStarted)
    }

    var canPeekAtSteam: Bool { launchViaSteam && wineStarted && state == .running && !launchGameUp }

    /// The Cancel button. Before the game's program starts this really takes the launch back; after that there is nothing clean to undo (the runtime cannot
    /// be restarted in this process), so it stops the game by closing the app, which opens fresh next time.
    func cancelLaunch() {
        if case .failed = state { dismiss(); return }
        if wineStarted {
            LogStore.shared.log("[launch] stop requested while the game was starting: closing the app")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            return
        }
        launchCancelled = true
        prepareTask?.cancel(); prepareTask = nil
        jitWaitTimer?.invalidate(); jitWaitTimer = nil; jitWaitMessage = nil
        endDockPolling()
        if dockGame != nil { MadeiraDock.cleanup(); SteamStore.shared.dockEnded(); dockGame = nil }
        dockStatus = nil
        LogStore.shared.log("[launch] cancelled before the game started")
        ExternalLibrary.shared.releaseSession(force: true)
        state = .idle; game = nil
    }

    fileprivate func startLaunchWatch(for game: Game, steam: Bool) {
        launchWatch?.invalidate()
        guard game.installer != true, game.inDesktop != true else { launchGameUp = true; return }
        winios_window_census_enable(1)
        launchPresentsAtStart = UInt64(madeira_frame_count()) + UInt64(winios_surface_present_count())
        let folder = steam ? "c:\\program files (x86)\\steam\\steamapps\\" : Self.folderPrefix(ofWindowsPath: game.exe)
        launchWatch = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLaunchWindows(folder: folder) }
        }
    }

    private func checkLaunchWindows(folder: String) {
        guard !launchGameUp else { stopLaunchWatch(); return }
        if state == .ended || state == .idle { stopLaunchWatch(); return }
        let waited = Date().timeIntervalSince(launchBegan)
        var found = false
        var windows = [winios_census_window](repeating: winios_census_window(), count: Int(WINIOS_CENSUS_MAX))
        let count = Int(winios_window_census(&windows, Int32(windows.count)))
        for var w in windows.prefix(count) {
            let image = withUnsafePointer(to: &w.image) { $0.withMemoryRebound(to: CChar.self, capacity: Int(WINIOS_CENSUS_IMAGE)) { String(cString: $0) } }
            if image.hasPrefix(folder), w.visible != 0, w.w >= 160, w.h >= 120, w.metal != 0 || w.presents > 0 { found = true; break }
        }
        // A game started directly (no Wine desktop) draws straight into our view, and the window census is not fed there. Its pictures are the signal instead:
        // the graphics layer counts every frame it presents, and a window of ours (GDI) counts its own.
        if !found, !launchViaSteam {
            let presents = UInt64(madeira_frame_count()) + UInt64(winios_surface_present_count())
            if presents >= launchPresentsAtStart + 8 { found = true }
        }
        if found || waited > 360 {
            launchGameUp = true
            LogStore.shared.log("[launch] \(found ? "the game's window is up" : "no game window seen; showing the screen anyway") after \(Int(waited)) s")
            stopLaunchWatch(keepRestoring: found)
        }
    }

    /// `keepRestoring`: the census found the game's window, which is often a splash or a launcher's window; the main window can still be shown for the first time
    /// minimized after that, so the census goes on restoring such windows (and counts nothing) until the session ends (census mode 2, PR 243).
    private func stopLaunchWatch(keepRestoring: Bool = false) {
        launchWatch?.invalidate(); launchWatch = nil
        winios_window_census_enable(keepRestoring ? 2 : 0)
    }

    nonisolated static func folderPrefix(ofWindowsPath path: String) -> String {
        var parts = path.lowercased().split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1 { parts.removeLast() }
        return parts.joined(separator: "\\") + "\\"
    }
}
