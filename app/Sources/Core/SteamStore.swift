// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit
import CryptoKit

/// Your Steam account inside the app: who is signed in, which games you own, and downloads into the game library.
/// The Steam protocol work is in `Sources/Steam` (sign-in, library, downloads; written for this project from Steam's public protocol); this class is the thin layer the screens talk to.
@MainActor
final class SteamStore: ObservableObject {
    static let shared = SteamStore()

    struct Owned: Codable, Identifiable, Hashable {
        var id: Int
        var name: String
        var installDir: String
        var buildID: Int
        var sizeBytes: UInt64
        var launches: [SteamLaunchOption]
        var folderName: String { SteamInstallFiles.safeFolderName(installDir.isEmpty ? "app_\(id)" : installDir) }
    }

    /// What the person chose for one game besides the normal install: another version (branch) of it, and DLC to leave out. Kept on the device.
    struct Choice: Codable, Equatable {
        var branch = SteamBranch.publicName
        /// The passwords of private betas, by branch, as typed. Not the account's password.
        var betaPasswords: [String: String] = [:]
        var betaPassword: String? { betaPasswords[branch] }
        /// DLC the person turned off. DLC the account owns is installed by default, as Steam does.
        var disabledDLC: Set<Int> = []
        /// The build number of the chosen version as Steam last said (for the update check of a branch).
        var latestBuild: Int?
        var isDefault: Bool { branch == SteamBranch.publicName && disabledDLC.isEmpty }
    }

    struct Download: Equatable {
        enum State: Equatable { case queued, active, paused, failed(String) }
        var state: State
        var progress = SteamDownloadProgress()
    }

    @Published private(set) var signedIn = SteamSignIn.isSignedIn
    @Published private(set) var accountName = SteamSignIn.accountName
    @Published private(set) var owned: [Owned] = []
    @Published private(set) var refreshing = false
    @Published private(set) var downloads: [Int: Download] = [:]
    @Published private(set) var choices: [Int: Choice] = SteamStore.loadChoices()
    @Published var error: String?
    /// Called on the main actor when a download finishes: the game, its install folder and the Windows path of the program to run (nil if none was found).
    var onInstalled: ((Owned, String?) -> Void)?

    private let service = SteamService.shared
    private var queue: [Int] = [] { didSet { queueOrder = queue } }
    private var active: (id: Int, task: Task<Void, Never>)? { didSet { activeID = active?.id } }
    /// The waiting games in the order they will download, and the one downloading now (for the Downloads page).
    @Published private(set) var queueOrder: [Int] = []
    @Published private(set) var activeID: Int?
    private var displaced: Int?
    private var started = false
    private var resumeAfterBackgroundIDs = Set<Int>()
    private var resumeAfterGame = Set<Int>()
    private var gameIsRunning = false

    static var steamApps: URL { SteamInstallPaths.steamApps(drive: AppModel.driveC) }
    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("steam-library.json")
    }
    private struct Cache: Codable { var account: String; var updated: Date; var games: [Owned] }
    private var updated: Date?

    private static func key(_ account: String?) -> String {
        SHA256.hash(data: Data((account ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Call when the app starts: reads the saved list and refreshes it when it is more than six hours old.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: SteamSignIn.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signInChanged() }
        }
        SteamBackground.shared.attach(self)
        SteamWorkshopStore.shared.resumeAfterLaunch()      // Workshop items left unfinished by the last run (a game that ended, a force-quit) start again
        loadCache()
        if signedIn, Date().timeIntervalSince(updated ?? .distantPast) > 6 * 3600 { Task { await refresh(interactive: false) } }
    }

    private func signInChanged() {
        let now = SteamSignIn.isSignedIn
        accountName = SteamSignIn.accountName
        guard now != signedIn else { return }
        signedIn = now
        if now {
            owned = []; updated = nil
            Task { await refresh(interactive: true) }
        } else {
            for id in Array(downloads.keys) { pause(id) }
            service.logoff()
            owned = []; updated = nil; downloads = [:]
            try? FileManager.default.removeItem(at: Self.cacheURL)
        }
    }

    func signOut() { SteamSignIn.signOut(); SteamAchievementProgress.shared.clear() }

    private func loadCache() {
        guard signedIn, let data = try? Data(contentsOf: Self.cacheURL), data.count < 64 << 20,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.account == Self.key(accountName) else { return }
        owned = cache.games; updated = cache.updated
    }

    private func saveCache() {
        guard let updated else { return }
        try? JSONEncoder().encode(Cache(account: Self.key(accountName), updated: updated, games: owned)).write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: Library

    func refresh(interactive: Bool = true) async {
        guard signedIn, !refreshing else { return }
        // No network at all: keep the saved list and say nothing red (the grids show an Offline chip).
        guard NetworkStatus.shared.isOnline else { SteamLog.event("[steam-library] offline: keeping the saved list"); return }
        refreshing = true; defer { refreshing = false }
        do {
            let apps = try await service.ownedApps()
            owned = apps.map {
                Owned(id: $0.appid, name: $0.name, installDir: $0.installDirectory ?? "", buildID: Int($0.buildID ?? "") ?? 0,
                      sizeBytes: SteamDepotPlanner.sizes(app: $0).download, launches: $0.launches)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            updated = Date(); saveCache(); error = nil
            SteamLog.event("[steam-library] windows-installable=\(owned.count)")
        } catch {
            let text = SteamSignIn.message(error)
            SteamLog.event("[steam-library] refresh failed: \(SteamSignIn.reason(error))")
            if interactive { self.error = text }
        }
    }

    // MARK: Versions and DLC

    private static let choicesKey = "steam.gameChoices.v1"
    private static func loadChoices() -> [Int: Choice] {
        guard let data = UserDefaults.standard.data(forKey: choicesKey), let saved = try? JSONDecoder().decode([String: Choice].self, from: data) else { return [:] }
        return Dictionary(saved.compactMap { key, value in Int(key).map { ($0, value) } }, uniquingKeysWith: { a, _ in a })
    }
    private func saveChoices() {
        let encodable = Dictionary(uniqueKeysWithValues: choices.filter { !$0.value.isDefault || $0.value.latestBuild != nil }.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) { UserDefaults.standard.set(data, forKey: Self.choicesKey) }
    }
    func choice(_ id: Int) -> Choice { choices[id] ?? Choice() }
    private func update(_ id: Int, _ change: (inout Choice) -> Void) {
        var value = choice(id); change(&value)
        choices[id] = value; saveChoices()
    }
    /// Chooses which version of the game to have. The files change when the game is next installed or updated (the page offers it).
    func setBranch(_ id: Int, to branch: String, password: String? = nil) {
        update(id) {
            $0.branch = branch; $0.latestBuild = nil
            if let password, !password.isEmpty, branch != SteamBranch.publicName { $0.betaPasswords[branch] = password }
        }
        invalidateBuilds()
    }
    func setDLC(_ id: Int, app: Int, enabled: Bool) { update(id) { if enabled { $0.disabledDLC.remove(app) } else { $0.disabledDLC.insert(app) } } }

    /// The versions and DLC Steam lists for a game. Also remembers the chosen version's newest build for the update check.
    func details(_ id: Int) async throws -> SteamGameDetails {
        let found = try await service.gameDetails(appID: id)
        let chosen = choice(id).branch
        if let build = found.info.branches.first(where: { $0.name == chosen })?.buildID.flatMap({ Int($0) }), choice(id).latestBuild != build {
            update(id) { $0.latestBuild = build }
        }
        return found
    }

    /// The game's achievements and this account's progress (read-only).
    func achievements(_ id: Int) async throws -> [SteamAchievement] {
        let list = try await service.achievements(appID: id)
        SteamAchievementProgress.shared.record(appID: id, list: list)
        return list
    }

    /// Checks a beta password with Steam. On success the branch it opens is chosen for the game and the password is kept to read that branch's files.
    @discardableResult
    func unlockBranch(_ id: Int, password: String) async throws -> String {
        let opened = try await service.betaPassword(appID: id, password: password)
        guard let first = opened.first else { throw SteamFailure(message: "That password does not open a beta of this game.") }
        setBranch(id, to: first.branch, password: password)
        return first.branch
    }

    // MARK: Installed state

    /// The build the installed copy says it is, or nil when it is not installed.
    func installedBuild(_ id: Int) -> Int? {
        // Read from disk, and a list of tiles asks several times each per redraw, so the answer is kept for half a minute (and dropped when something installs or deletes).
        // A game on the SSD is answered from the catalog (no I/O, and it stays installed while the drive is unplugged).
        if let external = ExternalLibrary.shared.assignment(for: id), external.location.libraryID != SteamStorageLibrary.internalID {
            return external.installed ? (external.buildID ?? 0) : nil
        }
        if let hit = buildCache[id], Date().timeIntervalSince(hit.at) < 30 { return hit.build }
        let build = SteamInstallFiles.buildID(appID: id, steamApps: Self.steamApps)
        buildCache[id] = (build, Date())
        return build
    }
    private var buildCache: [Int: (build: Int?, at: Date)] = [:]
    func invalidateBuilds() { buildCache = [:] }
    func isInstalled(_ id: Int) -> Bool { installedBuild(id) != nil }
    func updateAvailable(_ game: Owned) -> Bool {
        guard let have = installedBuild(game.id) else { return false }
        // Another version than the public one is compared with that version's build, when Steam has said what it is.
        let chosen = choice(game.id)
        if chosen.branch != SteamBranch.publicName { return chosen.latestBuild.map { have != $0 } ?? false }
        return have < game.buildID
    }
    /// Installed games whose newest build is newer than the one on the device and that are not being downloaded right now.
    var gamesWithUpdates: [Owned] { owned.filter { downloads[$0.id] == nil && updateAvailable($0) } }

    /// Looks for new builds again when the list is over six hours old (called when the app comes to the front).
    func refreshIfStale() {
        guard signedIn, !refreshing, Date().timeIntervalSince(updated ?? .distantPast) > 6 * 3600 else { return }
        Task { await refresh(interactive: false) }
    }
    func hasPartialDownload(_ id: Int) -> Bool {
        if let external = ExternalLibrary.shared.assignment(for: id), external.location.libraryID != SteamStorageLibrary.internalID {
            return external.pending == true && !external.installed
        }
        return SteamInstaller.hasPartialDownload(appID: id, steamApps: Self.steamApps)
    }
    /// Whether this game's files are on the SSD, and that drive is not reachable right now.
    func storageMissing(_ id: Int) -> Bool {
        let lib = ExternalLibrary.shared
        return lib.isExternal(id) && !(lib.availability == .available || lib.availability == .readOnly)
    }

    // MARK: Downloads

    /// "Verify and update files": the same as an install, but every depot's file list is fetched and the files on the disk are checked against it, so a damaged or changed file
    /// is fetched again and nothing else.
    func verify(_ id: Int) {
        verifyRequests.insert(id)
        install(id)
    }
    private var verifyRequests = Set<Int>()

    func install(_ id: Int) {
        guard signedIn else { error = "Sign in to Steam first."; return }
        guard active?.id != id, !queue.contains(id) else { return }
        // Which library: an existing install or partial download keeps its own; a new one goes where Settings > Steam says (iPad unless the SSD is chosen).
        do {
            let lib = ExternalLibrary.shared
            let game = owned.first(where: { $0.id == id })
            let choice = lib.assignment(for: id)?.location.libraryID ?? (lib.newDownloadsGoExternal ? (lib.external?.id ?? SteamStorageLibrary.internalID) : SteamStorageLibrary.internalID)
            if choice != SteamStorageLibrary.internalID || lib.assignment(for: id) != nil {
                _ = try lib.assign(appID: id, name: game?.name ?? "Steam game", folder: game?.folderName ?? "app_\(id)", libraryID: choice)
            }
        } catch { self.error = error.localizedDescription; return }
        if gameIsRunning { resumeAfterGame.insert(id); downloads[id] = Download(state: .paused); return }
        downloads[id] = Download(state: .queued)
        queue.append(id)
        pump()
    }

    func pause(_ id: Int) {
        if let current = active, current.id == id { current.task.cancel() }
        else if let i = queue.firstIndex(of: id) { queue.remove(at: i); downloads[id]?.state = .paused }
    }

    // MARK: Queue order

    /// Moves a waiting game up (-1) or down (+1) the queue.
    func move(_ id: Int, by step: Int) {
        guard let i = queue.firstIndex(of: id) else { return }
        let j = min(max(i + step, 0), queue.count - 1)
        guard j != i else { return }
        queue.swapAt(i, j)
    }

    /// Starts this game now: the one downloading goes back to the front of the queue and carries on afterwards.
    func startNow(_ id: Int) {
        guard let i = queue.firstIndex(of: id) else { return }
        queue.remove(at: i); queue.insert(id, at: 0)
        if let current = active, current.id != id { displaced = current.id; current.task.cancel() } else { pump() }
    }

    func pauseAll() {
        for id in queue { downloads[id]?.state = .paused }
        queue.removeAll()
        if let current = active { current.task.cancel() }
    }

    /// The one running (or, when paused, the first stopped one): what the download card's Cancel button stops.
    func cancelCurrent() {
        if let id = activeID ?? queueOrder.first ?? downloads.first(where: { $0.value.state == .paused })?.key { cancel(id) }
    }

    func resumeAll() {
        for (id, d) in downloads where id != active?.id && !queue.contains(id) {
            if case .active = d.state { continue }
            install(id)
        }
    }

    /// Stops a download. A first-time install also loses its partial files; an update of an installed game is only paused.
    func cancel(_ id: Int) {
        let running = active?.id == id ? active?.task : nil
        invalidateBuilds()
        let wasInstalled = isInstalled(id)
        pause(id); downloads[id] = nil
        guard !wasInstalled, let game = owned.first(where: { $0.id == id }) else { return }
        Task { await running?.value; await deleteFiles(appID: id, folderName: game.folderName) }
    }

    /// An installed game that is no longer in the library (it was removed from it and the files stayed): finds its program again and adds it back, exactly as a
    /// finished download does, so it carries the Steam app id and starts through Steam. Returns false when no program is found.
    @discardableResult func addToLibrary(_ game: Owned) -> Bool {
        let libraryID = ExternalLibrary.shared.libraryID(for: game.id)
        if libraryID != SteamStorageLibrary.internalID {
            Task {
                do {
                    let exe = try await ExternalLibrary.shared.perform(libraryID: libraryID, write: false) { root -> String? in
                        let folder = try SteamStoragePath.native("steamapps/common/" + game.folderName, root: root)
                        return Self.windowsExecutable(for: game, folder: folder, external: true)
                    }
                    guard let exe else {
                        self.error = "No program to run was found in \(game.name)'s files. Verify and update them from the game's page, or use Add a game to pick it."
                        return
                    }
                    onInstalled?(game, exe)
                    objectWillChange.send()
                } catch { self.error = error.localizedDescription }
            }
            return true
        }
        let folder = SteamInstallPaths.common(drive: AppModel.driveC).appendingPathComponent(game.folderName, isDirectory: true)
        guard let exe = Self.windowsExecutable(for: game, folder: folder) else {
            error = "No program to run was found in \(game.name)'s files. Verify and update them from the game's page, or use Add a game to pick it."
            return false
        }
        onInstalled?(game, exe)
        objectWillChange.send()
        return true
    }

    /// Deletes an installed game's files (the library entry is removed by the caller).
    func uninstall(_ game: Owned) {
        pause(game.id); downloads[game.id] = nil
        Task { await deleteFiles(appID: game.id, folderName: game.folderName) }
    }

    /// Removes a game's files from whichever library has them (the SSD is reached under its scope; the catalog forgets the game only after the delete worked).
    private func deleteFiles(appID: Int, folderName: String) async {
        let libraryID = ExternalLibrary.shared.libraryID(for: appID)
        if libraryID == SteamStorageLibrary.internalID {
            do { try SteamInstallFiles.delete(appID: appID, folderName: folderName, steamApps: Self.steamApps) }
            catch { SteamLog.event("[steam-depot] delete app=\(appID) failed: \(error.localizedDescription)") }
        } else {
            do {
                try await ExternalLibrary.shared.perform(libraryID: libraryID, write: true) { root in
                    let apps = try SteamStoragePath.native("steamapps", root: root)
                    try SteamInstallFiles.delete(appID: appID, folderName: folderName, steamApps: apps)
                }
                try ExternalLibrary.shared.removed(appID: appID)
            } catch { self.error = error.localizedDescription }
        }
        invalidateBuilds()
        objectWillChange.send()
    }

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }

    /// iOS is ending the app's background time: stop cleanly (finished chunks are journaled) and carry on when the app is active again.
    func pauseForBackground() {
        if let current = active { resumeAfterBackgroundIDs.insert(current.id); current.task.cancel() }
        for id in queue { resumeAfterBackgroundIDs.insert(id); downloads[id]?.state = .paused }
        queue.removeAll()
        SteamLog.event("[steam-depot] paused for the background count=\(resumeAfterBackgroundIDs.count)")
    }

    func resumeAfterBackground() {
        guard !resumeAfterBackgroundIDs.isEmpty else { return }
        let ids = resumeAfterBackgroundIDs.sorted()
        resumeAfterBackgroundIDs.removeAll()
        for id in ids { install(id) }
    }

    /// Only one sign-in of the account may be online: before Valve's client takes over for a Dock launch, this app's own connection logs off and closes.
    func prepareForDock() async { await service.suspend() }
    /// The Dock session ended: let this app's connection come back.
    func dockEnded() {
        service.resume()
        SteamWorkshopStore.shared.gameEnded()                                  // Workshop items that waited for the connection start now
        Task.detached(priority: .utility) { SteamClientTraces.scrub() }       // Valve's client's saved sign-in is not kept (see SteamClientTraces)
    }

    /// A game is running: downloads would fight it for CPU and memory, so they wait and then continue.
    func gameRunning(_ running: Bool) {
        guard running != gameIsRunning else { return }
        gameIsRunning = running
        if running {
            if let current = active { resumeAfterGame.insert(current.id); current.task.cancel() }
            for id in queue { resumeAfterGame.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
        } else {
            let ids = resumeAfterGame.sorted(); resumeAfterGame.removeAll()
            for id in ids { install(id) }
        }
    }

    var isDownloading: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }

    private func pump() {
        guard active == nil, !gameIsRunning, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        downloads[id]?.state = .active
        SteamBackground.shared.downloadStarted(name: owned.first(where: { $0.id == id })?.name ?? "Steam game")
        UIApplication.shared.isIdleTimerDisabled = true          // the download stops if the phone locks, so keep the screen awake
        active = (id, Task { @MainActor [weak self] in await self?.run(id) })
    }

    private func run(_ id: Int) async {
        let name = owned.first(where: { $0.id == id })?.name ?? "Steam game"
        var outcome = SteamBackground.Outcome.paused
        do {
            // On the SSD the scope and coordination are held for the whole download, cleanup included (the lease keeps them until it is released here).
            let libraryID = ExternalLibrary.shared.libraryID(for: id)
            let access = try await ExternalLibrary.shared.accessForOperation(libraryID: libraryID, write: true)
            defer { access?.keepAlive() }
            let steamApps = try access.map { try SteamStoragePath.native("steamapps", root: $0.root) } ?? Self.steamApps
            try FileManager.default.createDirectory(at: steamApps.appendingPathComponent("common", isDirectory: true), withIntermediateDirectories: true)
            var lastPublished = Date.distantPast
            var selection = SteamInstallSelection()
            let chosen = choice(id)
            selection.branch = chosen.branch
            selection.dlc = .allExcept(chosen.disabledDLC)
            selection.verify = verifyRequests.remove(id) != nil
            if chosen.branch != SteamBranch.publicName, let password = chosen.betaPassword, !password.isEmpty {
                selection.branchKey = try await service.betaPassword(appID: id, password: password).first { $0.branch == chosen.branch }?.key
            }
            let (folder, info) = try await service.install(appID: id, name: name, steamApps: steamApps, selection: selection) { [weak self] progress in
                // Every change of this reaches every screen that shows a game; once a second is plenty for a percentage.
                let now = Date()
                if now.timeIntervalSince(lastPublished) >= 1 || self?.downloads[id]?.progress.phase != progress.phase {
                    lastPublished = now
                    self?.downloads[id]?.progress = progress
                }
                SteamBackground.shared.progress(progress)
            }
            if let access { ExternalLibrary.shared.ensureAlias(for: access) }
            if access != nil, var assigned = ExternalLibrary.shared.assignment(for: id) {
                assigned.installed = true; assigned.pending = false; assigned.buildID = Int(info.buildID ?? "")
                assigned.bytes = SteamInstallFiles.sizeOnDisk(appID: id, steamApps: steamApps)
                try? ExternalLibrary.shared.record(assigned)
            }
            downloads[id] = nil
            invalidateBuilds()
            let game = owned.first(where: { $0.id == id }) ?? Owned(id: id, name: info.name, installDir: info.installDirectory ?? "", buildID: Int(info.buildID ?? "") ?? 0,
                                                                    sizeBytes: 0, launches: info.launches)
            let exe = Self.windowsExecutable(for: game, folder: folder, external: access != nil)
            SteamLog.event("[steam-depot] installed app=\(id) exe=\(exe == nil ? "none" : "found")\(access != nil ? " (SSD)" : "")")
            onInstalled?(game, exe)
            outcome = .completed
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[id] != nil { downloads[id]?.state = .paused }
            } else {
                let text = (error as? SteamStorageError)?.localizedDescription ?? SteamSignIn.message(error)
                downloads[id]?.state = .failed(text)
                outcome = .failed(text)
                SteamLog.event("[steam-depot] failed app=\(id) reason=\(SteamSignIn.reason(error))")
            }
        }
        active = nil
        if let other = displaced {
            displaced = nil
            if downloads[other] != nil { downloads[other]?.state = .queued; queue.insert(other, at: min(1, queue.count)) }
        }
        if queue.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
        SteamBackground.shared.downloadEnded(name: name, outcome: outcome, queueEmpty: queue.isEmpty)
        pump()
    }

    // MARK: Which program to run

    /// The Windows path of the game's program: Steam's own launch entry for Windows when it exists on disk, else the biggest plausible .exe in the folder.
    nonisolated static func windowsExecutable(for game: Owned, folder: URL, external: Bool = false) -> String? {
        let fm = FileManager.default
        func rel(_ url: URL) -> String { String(url.path.dropFirst(folder.path.count + 1)) }
        for option in game.launches {
            let os = option.oslist.lowercased()
            guard os.isEmpty || os.contains("windows") else { continue }
            guard ["", "default", "none"].contains(option.type.lowercased()) else { continue }
            let parts = option.executable.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            if let url = resolve(parts, in: folder), url.pathExtension.lowercased() == "exe" { return windowsPath(folder: folder.lastPathComponent, relative: rel(url), external: external) }
        }
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Int)?
        for case let url as URL in walker {
            if rel(url).split(separator: "/").count > 4 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let name = url.lastPathComponent.lowercased()
            if ["unins", "crash", "redist", "vcredist", "vc_redist", "dxsetup", "dotnet", "setup", "installer", "helper", "launcher"].contains(where: name.contains) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > (best?.1 ?? -1) { best = (url, size) }
        }
        return best.map { windowsPath(folder: folder.lastPathComponent, relative: rel($0.0), external: external) }
    }

    /// Finds `parts` under `root` ignoring case (the downloaded names may not match the spelling in the launch entry).
    nonisolated private static func resolve(_ parts: [String], in root: URL) -> URL? {
        var url = root
        for part in parts {
            if part == "." || part.isEmpty { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                  let hit = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else { return nil }
            url.appendPathComponent(hit)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated private static func windowsPath(folder: String, relative: String, external: Bool = false) -> String {
        // On the SSD the program is reached through the drive_c alias (C:\MadeiraExternalLibrary), which every part of the app that expects a C:\ path understands.
        if external { return SteamStoragePath.externalWindowsRoot + "\\steamapps\\common\\" + folder + "\\" + relative.replacingOccurrences(of: "/", with: "\\") }
        return AppModel.windowsPath(forRelative: "\(SteamInstallPaths.libraryRelative)/common/\(folder)/\(relative)")
    }
}
