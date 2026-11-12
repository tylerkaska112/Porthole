// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Installing a GOG game through GOG's own offline installer. Older GOG titles (Fallout 2 and most of the classic catalogue) have no build in GOG's download
// system at all; the setup file is all there is. So: ask GOG (signed in) for the game's Windows installer files, download them with resume, check them
// against GOG's checksum, run the setup silently inside Porthole's Wine into C:\GOG\<name>, then read the goggame-<id>.info file the installer leaves to
// learn which program starts the game and add it to the library. The setup files are deleted once the game is in.
//
// Nothing here logs a token or a download address (they carry a short-lived token); only counts, sizes and states.

import Foundation
import Combine
import CryptoKit
import UIKit

enum GogInstallError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct GogInstalledGame: Codable {
    var game: GogGame
    /// Relative to drive C ("GOG/fallout_2").
    var installDir: String
    /// The program's Windows path ("C:\\GOG\\fallout_2\\falloutw.exe") and its arguments, from the game's own goggame-<id>.info.
    var exe: String
    var args: String
    /// The GOG build it was installed from (depot installs only), so a newer build can be told apart later.
    var build: String?
    /// The game's own Galaxy client identity, from its build's manifest (see GogGalaxy); nil for a game installed before it was read, or whose build has none.
    var galaxy: GOGGalaxyClient?
}

@MainActor final class GogInstaller: ObservableObject {
    static let shared = GogInstaller()

    enum State: Equatable {
        case queued, active, paused, failed(String)
        /// The setup files are in; the installer has not run (or did not finish).
        case ready
        /// The installer is running in Porthole's Wine.
        case running
        case installed
    }
    struct Install: Equatable {
        var state: State
        var progress = SteamDownloadProgress()
        var isDownload: Bool { switch state { case .queued, .active, .paused, .failed: return true; default: return false } }
    }
    struct Store: Codable {
        var installed: [Int: GogInstalledGame] = [:]
        var pending: [Int: GogGame] = [:]
        /// The setup program of a finished download, kept until the install is done: id -> file name.
        var setups: [Int: String] = [:]
    }

    @Published private(set) var installs: [Int: Install] = [:]
    @Published private(set) var installed: [Int: GogInstalledGame] = [:]
    @Published private(set) var ready = false
    @Published var error: String?

    private var pending: [Int: GogGame] = [:]
    private var setups: [Int: String] = [:]
    private var queue: [Int] = []
    private var active: (id: Int, task: Task<Void, Never>)?
    private var runningID: Int?
    private var removing = Set<Int>()
    private var backgroundPaused = Set<Int>()
    private var saving: Task<Void, Never>?
    private var lastProgressPublish = Date.distantPast
    private let worker = GogInstallWorker()
    private let background = EpicBackground(store: "gog", label: "GOG")

    private init() {
        Task {
            do {
                let store = try await worker.load()
                installed = store.installed; pending = store.pending; setups = store.setups
                for (id, record) in installed {
                    if await worker.exists(record.exe) { installs[id] = Install(state: .installed); register(record) }
                    else { installed.removeValue(forKey: id) }
                }
                for (id, _) in pending where installs[id] == nil {
                    installs[id] = Install(state: setups[id] != nil ? .ready : .paused)
                }
                background.attach(active: { [weak self] in self?.active != nil || self?.queue.isEmpty == false },
                                  pause: { [weak self] in self?.pauseForBackground() },
                                  resume: { [weak self] in self?.resumeAfterBackground() })
                background.anyPaused = { [weak self] in self?.installs.values.contains { $0.state == .paused } == true }
                ready = true
            } catch { self.error = "Could not read GOG installs: " + ErrorText.plain(error) }
        }
    }

    // MARK: Asking

    func isInstalled(_ id: Int) -> Bool { installs[id]?.state == .installed }
    var activeID: Int? { active?.id }
    func record(_ id: Int) -> GogInstalledGame? { installed[id] }
    /// Remembers a game's Galaxy client once it has been read for a game installed before.
    func setGalaxy(_ client: GOGGalaxyClient, for id: Int) {
        guard installed[id] != nil else { return }
        installed[id]?.galaxy = client
        persist()
    }
    func game(for id: Int) -> GogGame? { pending[id] ?? installed[id]?.game }
    /// The game as the library holds it once installed (reports and settings are about that program).
    func entry(_ id: Int) -> Game? { installed[id] == nil ? nil : AppModel.shared.games.first { $0.gogID == id } }

    private func register(_ record: GogInstalledGame) {
        AppModel.shared.upsertGog(id: record.game.id, title: record.game.title, exe: record.exe, args: record.args, art: record.game.art)
    }

    private func persist() {
        let store = Store(installed: installed, pending: pending, setups: setups), previous = saving
        saving = Task {
            await previous?.value
            do { try await worker.save(store) } catch { self.error = "Could not save GOG installs: " + ErrorText.plain(error) }
        }
    }

    /// The library's newest pictures for the games that are installed (their records kept the picture of the day they were installed).
    func refreshArt(from list: [GogGame]) {
        var changed = false
        for (id, record) in installed {
            guard let fresh = list.first(where: { $0.id == id }), fresh.artURL != record.game.artURL else { continue }
            var updated = record
            updated.game = fresh
            installed[id] = updated
            register(updated)
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Actions

    func install(_ game: GogGame) {
        guard ready, !removing.contains(game.id), installed[game.id] == nil else { return }
        let id = game.id
        if installs[id]?.state == .active || installs[id]?.state == .queued || installs[id]?.state == .running { return }
        // The setup files are already here: run them instead of downloading again.
        if setups[id] != nil {
            switch installs[id]?.state { case .ready?, .failed?: runInstaller(id); return; default: break }
        }
        pending[id] = game
        installs[id] = Install(state: .queued, progress: installs[id]?.progress ?? SteamDownloadProgress())
        error = nil
        queue.append(id); persist(); startNext()
    }

    func pause(_ id: Int) {
        backgroundPaused.remove(id)
        queue.removeAll { $0 == id }
        if active?.id == id { active?.task.cancel() }
        if installed[id] == nil, installs[id]?.state == .queued || installs[id]?.state == .active { installs[id]?.state = .paused }
        persist()
    }
    func pauseAll() { for id in queue + (active.map { [$0.id] } ?? []) { pause(id) } }
    /// The games waiting, in the order they will start (the shared Downloads page shows them).
    var queueOrder: [Int] { queue }
    /// Starts a paused or failed download again.
    func resume(_ id: Int) { if let game = pending[id] { install(game) } }
    /// Puts a waiting download first: the one running now is stopped, goes back behind it, and carries on afterwards.
    func startNow(_ id: Int) {
        guard ready, installed[id] == nil, pending[id] != nil, active?.id != id else { return }
        let displaced = active?.id
        queue.removeAll { $0 == id }
        queue.insert(id, at: 0)
        installs[id] = Install(state: .queued, progress: installs[id]?.progress ?? SteamDownloadProgress())
        if let displaced {
            backgroundPaused.remove(displaced)
            active?.task.cancel()
            installs[displaced]?.state = .queued
            queue.insert(displaced, at: 1)
        } else { startNext() }
        persist()
    }
    func resumeAll() { for (id, install) in installs where install.state == .paused { if let game = pending[id] { self.install(game) } } }
    func cancelCurrent() {
        if let id = activeID ?? queue.first ?? installs.first(where: { $0.value.isDownload })?.key { cancel(id) }
    }
    private func pauseForBackground() {
        for id in queue + (active.map { [$0.id] } ?? []) { pause(id); backgroundPaused.insert(id) }
    }
    private func resumeAfterBackground() {
        let ids = backgroundPaused; backgroundPaused.removeAll()
        for id in ids { if let game = pending[id] { install(game) } }
    }

    /// Stops a download and throws away what was fetched; an installed game is left alone.
    func cancel(_ id: Int) { remove(id, uninstall: false) }
    func uninstall(_ id: Int) { remove(id, uninstall: true) }

    private func remove(_ id: Int, uninstall: Bool) {
        guard ready, !removing.contains(id) else { return }
        if uninstall, AppModel.shared.session.isActive, AppModel.shared.session.game?.gogID == id {
            error = "End the game session before uninstalling."; return
        }
        if !uninstall, installed[id] != nil { return }
        removing.insert(id); pause(id)
        let task = active?.id == id ? active?.task : nil
        // A cancelled download also clears the folder a half-finished install may have started (an installed game's folder is only removed by uninstall).
        let dir = installed[id]?.installDir ?? (pending[id].map { "GOG/" + GogInstallWorker.folderName(for: $0) })
        Task {
            await task?.value
            await worker.removeFiles(id: id, installDir: dir)
            pending.removeValue(forKey: id); setups.removeValue(forKey: id)
            if uninstall { installed.removeValue(forKey: id); AppModel.shared.removeGog(id: id) }
            installs.removeValue(forKey: id)
            persist(); removing.remove(id)
        }
    }

    // MARK: The queue

    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let game = pending[id], !removing.contains(id) else { startNext(); return }
        installs[id]?.state = .active
        background.downloadStarted(name: game.title)
        let task = Task(priority: .userInitiated) {
            var outcome = EpicBackground.Outcome.paused
            do {
                let token = try await GogAuth.shared.validAccessToken()
                let result = try await worker.download(game, token: token) { progress in
                    await MainActor.run {
                        guard self.active?.id == id, self.installs[id]?.state == .active else { return }
                        let now = Date()
                        guard now.timeIntervalSince(self.lastProgressPublish) >= 0.5 || self.installs[id]?.progress.phase != progress.phase else { return }
                        self.lastProgressPublish = now
                        self.installs[id]?.progress = progress
                        self.background.progress(progress, waiting: self.queue.count)
                    }
                }
                try Task.checkCancellation()
                switch result {
                case .installed(let record):
                    // Fetched straight from GOG's content system: nothing to run, the game is in.
                    installed[id] = record; pending.removeValue(forKey: id); setups.removeValue(forKey: id)
                    register(record)
                    installs[id] = Install(state: .installed)
                    persist()
                    outcome = .completed
                case .setup(let name):
                    setups[id] = name
                    installs[id]?.state = .ready
                    persist()
                    outcome = .downloaded
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if installs[id]?.state != .queued { installs[id]?.state = .paused }
                } else {
                    let message = (error as? GogAuthError)?.message ?? ErrorText.plain(error)
                    installs[id]?.state = .failed(message)
                    outcome = .failed(message)
                    LogStore.shared.log("[gog-install] failure: \(message)", level: .error)
                }
            }
            active = nil
            background.downloadEnded(name: game.title, outcome: outcome, queueEmpty: queue.isEmpty)
            startNext()
            // Downloaded while the app is in front and nothing else is running: start the setup now; otherwise it waits behind a button.
            if outcome == .downloaded, UIApplication.shared.applicationState == .active, !AppModel.shared.session.isActive { runInstaller(id) }
        }
        active = (id, task)
    }

    // MARK: Running the setup

    /// Starts the downloaded setup in Porthole's Wine (the person watches it on the desktop; it is silent apart from its progress window).
    func runInstaller(_ id: Int) {
        guard let game = pending[id] ?? installed[id]?.game, let setup = setups[id], runningID == nil, !AppModel.shared.session.isActive else {
            if AppModel.shared.session.isActive { error = "End the running game before installing." }
            return
        }
        let folder = GogInstallWorker.folderName(for: game)
        var runner = Game(name: "Installer: " + game.title, exe: "C:\\Installers\\GOG\\\(id)\\" + setup)
        // Inno Setup (what GOG's setups are): silent apart from the progress window, into a folder with no spaces (arguments are split at spaces).
        runner.args = "/SILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\\GOG\\\(folder)"
        runner.inDesktop = true; runner.installer = true
        runningID = id
        installs[id]?.state = .running
        error = nil
        LogStore.shared.log("[gog-install] running the setup for game \(id)")
        AppModel.shared.session.start(runner)
    }

    /// The Wine session ended: if it was the setup, look for what it installed.
    func sessionEnded() {
        guard let id = runningID, let game = pending[id] ?? installed[id]?.game else { return }
        runningID = nil
        Task {
            do {
                let record = try await worker.finish(game)
                installed[id] = record; pending.removeValue(forKey: id); setups.removeValue(forKey: id)
                register(record)
                installs[id] = Install(state: .installed)
                persist()
                LogStore.shared.log("[gog-install] installed game \(id)")
            } catch {
                installs[id]?.state = .ready
                self.error = ErrorText.plain(error)
                LogStore.shared.log("[gog-install] the setup did not leave a game: \(error.localizedDescription)", level: .error)
            }
        }
    }
}

// MARK: - Worker

enum GogInstallResult {
    case installed(GogInstalledGame)
    case setup(String)
}

/// File work and network off the main actor.
private actor GogInstallWorker {
    private let storeURL: URL

    init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        storeURL = support.appendingPathComponent("gog-installs.json")
    }
    func load() throws -> GogInstaller.Store {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return GogInstaller.Store() }
        return try JSONDecoder().decode(GogInstaller.Store.self, from: Data(contentsOf: storeURL))
    }
    func save(_ store: GogInstaller.Store) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }

    private var drive: URL { AppModel.driveC }
    func exists(_ windowsPath: String) -> Bool {
        AppModel.unixURL(forWindows: windowsPath).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The folder name the game goes in: GOG's own slug, kept to plain letters (it is in a program argument, where spaces would split it).
    nonisolated static func folderName(for game: GogGame) -> String {
        let base = game.slug.isEmpty ? "game\(game.id)" : game.slug
        let clean = base.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_" }.joined()
        return clean.isEmpty ? "game\(game.id)" : clean
    }
    private func setupDirectory(_ id: Int) -> URL { drive.appendingPathComponent("Installers/GOG/\(id)", isDirectory: true) }

    func removeFiles(id: Int, installDir: String?) {
        try? FileManager.default.removeItem(at: setupDirectory(id))
        if let installDir, installDir.hasPrefix("GOG/"), !installDir.contains("..") {
            try? FileManager.default.removeItem(at: drive.appendingPathComponent(installDir, isDirectory: true))
        }
    }

    // MARK: Download

    private struct PlanFile { let id: String; let size: UInt64; let downlink: URL }

    private func authorised(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    /// The Windows installer files of a game, from GOG (signed in).
    private func plan(_ game: GogGame, token: String) async throws -> (files: [PlanFile], version: String) {
        var components = URLComponents(string: "https://api.gog.com/products/\(game.id)")!
        components.queryItems = [URLQueryItem(name: "expand", value: "downloads")]
        let (data, response) = try await StoreNetwork.session.data(for: authorised(components.url!, token: token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let downloads = json["downloads"] as? [String: Any], let installers = downloads["installers"] as? [[String: Any]] else {
            LogStore.shared.log("[gog-install] product details answered \(status), \(data.count) bytes", level: .error)
            throw GogInstallError.invalid("GOG did not list the installer for this game (answer \(status)).")
        }
        let windows = installers.filter { ($0["os"] as? String) == "windows" }
        guard !windows.isEmpty else { throw GogInstallError.invalid("GOG has no Windows installer for this game.") }
        let wanted = Locale.current.language.languageCode?.identifier ?? "en"
        let chosen = windows.first { ($0["language"] as? String) == wanted } ?? windows.first { ($0["language"] as? String) == "en" } ?? windows[0]
        var files: [PlanFile] = []
        for file in (chosen["files"] as? [[String: Any]]) ?? [] {
            guard let link = (file["downlink"] as? String).flatMap(URL.init(string:)), link.scheme == "https", link.host?.hasSuffix("gog.com") == true else { continue }
            let id = (file["id"] as? String) ?? "\(file["id"] ?? "")"
            let size = (file["size"] as? NSNumber)?.uint64Value ?? 0
            files.append(PlanFile(id: id, size: size, downlink: link))
        }
        guard !files.isEmpty else { throw GogInstallError.invalid("GOG listed no files for this game's installer.") }
        LogStore.shared.log("[gog-install] plan: \(windows.count) Windows installer(s), \(files.count) file(s), \(files.reduce(0) { $0 + $1.size } / 1_048_576) MB")
        return (files, (chosen["version"] as? String) ?? "")
    }

    /// The address a file can be fetched from right now, with GOG's md5 of it when it published one.
    private func resolve(_ file: PlanFile, token: String) async throws -> (url: URL, md5: String?) {
        let (data, response) = try await StoreNetwork.session.data(for: authorised(file.downlink, token: token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = (json["downlink"] as? String).flatMap(URL.init(string:)), link.scheme == "https" else {
            LogStore.shared.log("[gog-install] download link answered \(status)", level: .error)
            throw GogInstallError.invalid("GOG did not give a download link (answer \(status)).")
        }
        var md5: String?
        if let checksum = (json["checksum"] as? String).flatMap(URL.init(string:)), checksum.scheme == "https",
           let (xml, _) = try? await StoreNetwork.session.data(from: checksum), let text = String(data: xml, encoding: .utf8),
           let range = text.range(of: "md5=\"[0-9a-fA-F]{32}\"", options: .regularExpression) {
            md5 = String(text[range].dropFirst(5).dropLast()).lowercased()
        }
        return (link, md5)
    }

    private nonisolated static func md5(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func safeName(_ raw: String) -> String {
        let clean = raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? String($0) : "_" }.joined()
        return clean.isEmpty || clean.hasPrefix(".") ? "setup_" + clean : clean
    }

    /// Installs from GOG's content system when the game has a build there (no setup program involved), and otherwise downloads GOG's setup file.
    func download(_ game: GogGame, token: String, progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> GogInstallResult {
        if let build = try await GogContent.latestBuild(productID: game.id) {
            return .installed(try await installFromDepots(game, build: build, progress: progress))
        }
        LogStore.shared.log("[gog-install] no Galaxy build for game \(game.id): using GOG's setup file")
        return .setup(try await downloadSetup(game, token: token, progress: progress))
    }

    /// Downloads every file of the installer into drive C's Installers/GOG/<id> (resuming what is there) and returns the name of the setup program.
    private func downloadSetup(_ game: GogGame, token: String, progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> String {
        let (files, _) = try await plan(game, token: token)
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        let dir = setupDirectory(game.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let values = try drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = UInt64(max(0, max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))))
        // The setup files and the installed game are on the device at once, and the game is about as big again.
        guard free >= total * 2 + 256 * 1024 * 1024 else {
            throw GogInstallError.invalid("Not enough free space: the installer is \(total / 1_048_576) MB and needs about twice that while it installs.")
        }
        var status = SteamDownloadProgress()
        status.phase = .downloading; status.totalBytes = total
        await progress(status)
        var finished: UInt64 = 0, names: [String] = []
        let meter = GogMeter(total: total)
        for file in files {
            try Task.checkCancellation()
            let (link, md5) = try await resolve(file, token: token)
            let name = Self.safeName(link.lastPathComponent.removingPercentEncoding ?? link.lastPathComponent)
            names.append(name)
            let final = dir.appendingPathComponent(name), part = dir.appendingPathComponent(name + ".part")
            // A file under its final name was fetched and checked earlier (GOG's listed sizes are rounded to whole megabytes, so they cannot be compared).
            if let size = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.uint64Value, size > 0 {
                finished += size; status.doneBytes = finished; await progress(status); continue
            }
            let base = finished
            let resumedAt = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.uint64Value ?? 0
            try await GogFileFetcher.fetchFast(url: link, to: part) { have in
                if let p = meter.progress(base: base, have: have, resumedAt: resumedAt) { Task { await progress(p) } }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.uint64Value ?? 0
            meter.fileDone(received: size > resumedAt ? size - resumedAt : 0)
            guard size > 0 else {
                try? FileManager.default.removeItem(at: part)
                throw GogInstallError.invalid("GOG sent an empty file. Try again.")
            }
            if let md5 {
                status.doneBytes = finished + size; status.phase = .finishing; await progress(status)
                let actual = try Self.md5(of: part)
                guard actual == md5 else {
                    try? FileManager.default.removeItem(at: part)
                    throw GogInstallError.invalid("A downloaded file failed GOG's checksum. Try again.")
                }
                status.phase = .downloading
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            finished += size
        }
        status.doneBytes = total; status.phase = .finishing
        await progress(status)
        // The setup program is the .exe (the extra .bin files are its data).
        guard let setup = names.first(where: { $0.lowercased().hasSuffix(".exe") }) else {
            throw GogInstallError.invalid("GOG's installer has no setup program in it.")
        }
        return setup
    }

    // MARK: Depots (GOG's content system)

    private func installFromDepots(_ game: GogGame, build: (id: String, link: URL),
                                   progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> GogInstalledGame {
        var status = SteamDownloadProgress()
        await progress(status)
        let meta = try await GogContent.meta(link: build.link, buildID: build.id)
        let language = (Locale.current.language.languageCode?.identifier ?? "en") + "-" + (Locale.current.region?.identifier ?? "US")
        let depots = GogContent.chooseDepots(meta, preferred: language)
        guard !depots.isEmpty else { throw GogInstallError.invalid("GOG's build of this game lists nothing to download.") }
        var manifests: [GogDepotManifest] = []
        for depot in depots { try Task.checkCancellation(); manifests.append(try await GogContent.depot(depot.manifest)) }
        LogStore.shared.log("[gog-install] build \(build.id): \(depots.count) of \(meta.depots.count) depot(s), \(depots.reduce(0) { $0 + $1.size } / 1_048_576) MB; redistributables skipped: \(meta.dependencies.count)")

        // What goes where. "support" files are GOG's install-script extras: only those meant for the game folder (app/...) are used.
        struct Job { let manifest: Int; let item: GogDepotItem }
        var byPath: [String: Job] = [:], directories: [String] = []
        var skippedSupport = 0
        for (index, manifest) in manifests.enumerated() {
            for item in manifest.items {
                if item.isDirectory { directories.append(item.path); continue }
                var path = item.path
                if item.isSupport {
                    guard path.lowercased().hasPrefix("app/") else { skippedSupport += 1; continue }
                    path = String(path.dropFirst(4))
                }
                guard !path.isEmpty else { continue }
                byPath[path.lowercased()] = Job(manifest: index, item: item.moved(to: path))
            }
        }
        guard !byPath.isEmpty else { throw GogInstallError.invalid("GOG's build of this game has no files.") }

        let folder = Self.folderName(for: game)
        let root = drive.appendingPathComponent("GOG/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A file already under its final name was written and verified on an earlier try.
        var todo: [Job] = []
        var reused = 0
        for job in byPath.values {
            let target = root.appendingPathComponent(job.item.path)
            if let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue, size == job.item.size { reused += 1; continue }
            todo.append(job)
        }
        let sources = Dictionary(uniqueKeysWithValues: Set(depots.map(\.productId)).map { ($0, GogChunkSource(productId: $0)) })
        func source(_ manifest: Int) -> GogChunkSource { sources[depots[manifest].productId]! }

        // How much comes down and how much lands on disk.
        var wanted: UInt64 = 0, write: UInt64 = 0
        var containerNeeded = Set<Int>()           // manifest * 1_000_000 + chunk index
        var starts: [[Int]] = manifests.map { m in var s = 0; return m.containerChunks.map { c in defer { s += c.size }; return s } }
        for job in todo {
            write += UInt64(job.item.size)
            if let c = job.item.container {
                guard c.offset >= 0, c.size >= 0, let last = starts[job.manifest].last, let lastChunk = manifests[job.manifest].containerChunks.last,
                      c.offset + c.size <= last + lastChunk.size else { throw GogInstallError.invalid("GOG's small-files container does not hold \(job.item.path).") }
                let chunks = manifests[job.manifest].containerChunks
                for i in chunks.indices where starts[job.manifest][i] < c.offset + c.size && starts[job.manifest][i] + chunks[i].size > c.offset { containerNeeded.insert(job.manifest * 1_000_000 + i) }
            } else {
                wanted += job.item.chunks.reduce(0) { $0 + UInt64($1.compressedSize) }
            }
        }
        for key in containerNeeded { wanted += UInt64(manifests[key / 1_000_000].containerChunks[key % 1_000_000].compressedSize) }
        let values = try drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = UInt64(max(0, max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))))
        guard free >= write + 256 * 1024 * 1024 else {
            throw GogInstallError.invalid("Not enough free space: this game needs about \(write / 1_048_576) MB more.")
        }
        LogStore.shared.log("[gog-install] \(todo.count) file(s) to fetch, \(reused) already present, \(skippedSupport) support file(s) left out; \(wanted / 1_048_576) MB to download, \(write / 1_048_576) MB to write")

        let staging = storeURL.deletingLastPathComponent().appendingPathComponent("Gog Staging/\(game.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for directory in directories { try? FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true) }

        status.phase = .downloading; status.totalBytes = wanted
        await progress(status)
        var done: UInt64 = 0
        var lastReport = Date.distantPast
        let began = Date()
        func report(force: Bool = false) async {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= 0.25 else { return }
            lastReport = now
            status.doneBytes = min(done, wanted)
            status.bytesPerSecond = Double(done) / max(0.5, now.timeIntervalSince(began))
            await progress(status)
        }
        func publish(_ part: URL, to target: URL) throws {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            guard rename(part.path, target.path) == 0 else { throw GogInstallError.invalid("A downloaded file could not be put in place. The device may be out of storage: free some space and start the download again.") }
        }
        func verify(_ md5: Insecure.MD5, _ sha: SHA256, of job: Job) throws {
            if let want = job.item.md5, md5.finalize().map({ String(format: "%02x", $0) }).joined() != want {
                throw GogInstallError.invalid("\(job.item.path) failed GOG's checksum. Try again.")
            }
            if let want = job.item.sha256, sha.finalize().map({ String(format: "%02x", $0) }).joined() != want {
                throw GogInstallError.invalid("\(job.item.path) failed GOG's checksum. Try again.")
            }
        }

        // Porthole 0.50.382: every chunk this install needs is named up front, in the order the loops below ask for them, and a look-ahead window (ChunkWindow) keeps an
        // adaptive number of them in flight and decoded ahead of the writer. It used to be four at a time with a wait for the slowest, files and small-file containers
        // one after the other.
        struct ChunkRef: Sendable { let source: GogChunkSource; let chunk: GogChunk }
        var plan: [String: ChunkRef] = [:], order: [String] = []
        func key(_ manifest: Int, _ chunk: GogChunk) -> String {
            let k = "\(manifest):\(chunk.compressedMd5)"
            if plan[k] == nil { plan[k] = ChunkRef(source: source(manifest), chunk: chunk); order.append(k) }
            return k
        }
        let packed = todo.filter { $0.item.container != nil }.sorted {
            ($0.manifest, $0.item.container!.offset) < ($1.manifest, $1.item.container!.offset)
        }
        func coveringChunks(_ job: Job) -> [Int] {
            guard let c = job.item.container else { return [] }
            let chunks = manifests[job.manifest].containerChunks
            return chunks.indices.filter { starts[job.manifest][$0] < c.offset + c.size && starts[job.manifest][$0] + chunks[$0].size > c.offset }
        }
        for job in todo where job.item.container == nil { for chunk in job.item.chunks { _ = key(job.manifest, chunk) } }
        for job in packed { for i in coveringChunks(job) { _ = key(job.manifest, manifests[job.manifest].containerChunks[i]) } }
        let planned = plan
        let window = ChunkWindow<String>(order: order, weight: { planned[$0]?.chunk.size ?? 0 }, fetch: { k in
            let ref = planned[k]!
            let raw = try await ref.source.raw(ref.chunk.compressedMd5)
            return (try GogChunkSource.decode(raw, as: ref.chunk), raw.count)
        })
        defer { window.cancel() }

        // Files made of their own chunks.
        for job in todo where job.item.container == nil {
            try Task.checkCancellation()
            let target = root.appendingPathComponent(job.item.path)
            let part = staging.appendingPathComponent("file.part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let handle = try FileHandle(forWritingTo: part)
            do {
                var md5 = Insecure.MD5(), sha = SHA256()
                for chunk in job.item.chunks {
                    try Task.checkCancellation()
                    let data = try await window.take(key(job.manifest, chunk))
                    try handle.write(contentsOf: data)
                    if job.item.md5 != nil { md5.update(data: data) }
                    if job.item.sha256 != nil { sha.update(data: data) }
                    done += UInt64(chunk.compressedSize)
                    await report()
                }
                try verify(md5, sha, of: job)
                try handle.close()   // no fsync per file: the file's own checksum was just checked, and a resumed install keeps only files of the right size
                try publish(part, to: target)
            } catch {
                try? handle.close(); try? FileManager.default.removeItem(at: part)
                throw error
            }
        }

        // Small files, cut out of the container's chunks (in container order, so each chunk is fetched about once).
        var counted = Set<String>()
        for job in packed {
            try Task.checkCancellation()
            guard let c = job.item.container else { continue }
            let chunks = manifests[job.manifest].containerChunks
            var bytes = Data()
            for i in coveringChunks(job) {
                let k = key(job.manifest, chunks[i])
                let data = try await window.take(k)
                if counted.insert(k).inserted { done += UInt64(chunks[i].compressedSize); await report() }
                let from = max(c.offset, starts[job.manifest][i]) - starts[job.manifest][i]
                let to = min(c.offset + c.size, starts[job.manifest][i] + chunks[i].size) - starts[job.manifest][i]
                bytes.append(data.subdata(in: from ..< to))
            }
            guard bytes.count == c.size else { throw GogInstallError.invalid("GOG's small-files container was short for \(job.item.path).") }
            // The file's own checksum, or (for a file in one chunk) that chunk's.
            if let want = job.item.md5 ?? (job.item.chunks.count == 1 && job.item.chunks[0].size == c.size ? job.item.chunks[0].md5 : nil),
               GogChunkSource.md5(bytes) != want { throw GogInstallError.invalid("\(job.item.path) failed GOG's checksum. Try again.") }
            let part = staging.appendingPathComponent("file.part")
            try bytes.write(to: part)
            try publish(part, to: root.appendingPathComponent(job.item.path))
        }
        await report(force: true)
        status.phase = .finishing
        await progress(status)

        var record = try finish(game)
        record.build = build.id
        record.galaxy = meta.galaxy
        return record
    }

    // MARK: After the setup

    /// The path with each part spelled as it is on disk (matched ignoring case), or nil when some part is not there.
    private nonisolated static func resolveCase(root: URL, components: [String]) -> [String]? {
        var current = root, result: [String] = []
        for part in components {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            guard let match = names.first(where: { $0 == part }) ?? names.first(where: { $0.lowercased() == part.lowercased() }) else { return nil }
            result.append(match)
            current.appendPathComponent(match)
        }
        return result
    }

    /// Reads what the installer left in C:\GOG\<name>: the goggame-<id>.info file names the program that starts the game.
    func finish(_ game: GogGame) throws -> GogInstalledGame {
        let folder = Self.folderName(for: game)
        let root = drive.appendingPathComponent("GOG/\(folder)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw GogInstallError.invalid("The installer did not install the game. Run it again from the game's page.")
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let infoName = contents.first { $0.lowercased() == "goggame-\(game.id).info" } ?? contents.first { $0.lowercased().hasPrefix("goggame-") && $0.lowercased().hasSuffix(".info") }
        var program: String?, arguments = ""
        if let infoName, let data = try? Data(contentsOf: root.appendingPathComponent(infoName)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tasks = (json["playTasks"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String ?? "FileTask") == "FileTask" && $0["path"] is String }
            let task = tasks.first { ($0["isPrimary"] as? Bool) == true } ?? tasks.first { ($0["category"] as? String) == "game" } ?? tasks.first
            if let task, let path = task["path"] as? String {
                program = path.replacingOccurrences(of: "/", with: "\\")
                arguments = (task["arguments"] as? String) ?? ""
            }
            LogStore.shared.log("[gog-install] info file read: \(tasks.count) play task(s)")
        }
        if program == nil {
            // No info file: the one program in the folder that is not an uninstaller.
            let exes = contents.filter { $0.lowercased().hasSuffix(".exe") && !$0.lowercased().hasPrefix("unins") }
            if exes.count == 1 { program = exes[0]; LogStore.shared.log("[gog-install] no info file; using the only program in the folder") }
        }
        guard var program else {
            throw GogInstallError.invalid("The game installed, but Porthole could not tell which program starts it. Add it from Files with the + button (folder C:\\GOG\\\(folder)).")
        }
        // Windows names are not case-sensitive and this file system is: the info file says RCT.exe where the depot holds RCT.EXE. Use the name on disk.
        if let real = Self.resolveCase(root: root, components: program.split(separator: "\\").map(String.init)) { program = real.joined(separator: "\\") }
        let windows = "C:\\GOG\\\(folder)\\" + program
        guard exists(windows) else {
            throw GogInstallError.invalid("The installer finished but \(program) is not there.")
        }
        // The setup files are no longer needed.
        try? FileManager.default.removeItem(at: setupDirectory(game.id))
        return GogInstalledGame(game: game, installDir: "GOG/\(folder)", exe: windows, args: arguments, build: nil)
    }
}

// MARK: - Resumable file download

/// Speed and position of a download, reported from the network's own queue: at most four times a second.
private final class GogMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private let start = Date()
    private var lastReport = Date.distantPast
    private var received: UInt64 = 0
    init(total: UInt64) { self.total = total }

    func progress(base: UInt64, have: UInt64, resumedAt: UInt64) -> SteamDownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.25 else { return nil }
        lastReport = now
        let current = have > resumedAt ? have - resumedAt : 0
        return SteamDownloadProgress(doneBytes: base + have, totalBytes: total,
                                     bytesPerSecond: Double(received + current) / max(0.5, now.timeIntervalSince(start)))
    }
    func fileDone(received bytes: UInt64) { lock.lock(); received += bytes; lock.unlock() }
}

/// One file to disk, with a Range request to carry on from what an earlier try left. Reports the file's size on disk as bytes arrive.
final class GogFileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let onProgress: @Sendable (UInt64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var written: UInt64 = 0
    private var failure: Error?
    private var alreadyComplete = false
    /// The file's full size as the server states it (Content-Length, or the total of Content-Range), -1 when it did not say.
    private var expectedTotal: Int64 = -1
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private let lock = NSLock()

    private init(file: URL, onProgress: @escaping @Sendable (UInt64) -> Void) { self.file = file; self.onProgress = onProgress }

    static func fetch(url: URL, to file: URL, onProgress: @escaping @Sendable (UInt64) -> Void) async throws {
        let fetcher = GogFileFetcher(file: file, onProgress: onProgress)
        try await withTaskCancellationHandler { try await fetcher.run(url) } onCancel: { fetcher.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    private func run(_ url: URL) async throws {
        let have = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
        written = have
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let configuration = StoreNetwork.configuration()
        configuration.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
            continuation = c
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { failure = GogInstallError.invalid("The download server sent no answer."); completionHandler(.cancel); return }
        switch http.statusCode {
        case 206:
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
            if let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/"), let total = Int64(range[range.index(after: slash)...]) { expectedTotal = total }
        case 200:
            expectedTotal = http.expectedContentLength
            // The server started over (or there was nothing to resume): the file is rewritten from its first byte.
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try? FileHandle(forWritingTo: file)
            written = 0
        case 416:
            alreadyComplete = true; completionHandler(.cancel); return
        default:
            failure = GogInstallError.invalid("The download server answered \(http.statusCode).")
            completionHandler(.cancel); return
        }
        if handle == nil { failure = GogInstallError.invalid("The download could not be written to storage. Free some space on the device and start it again."); completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += UInt64(data.count)
            onProgress(written)
        } catch {
            failure = GogInstallError.invalid("Could not write the download to disk (is the device full?).")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        lock.lock(); let c = continuation; continuation = nil; let wasCancelled = cancelled; lock.unlock()
        if alreadyComplete { c?.resume(); return }
        if let failure { c?.resume(throwing: failure); return }
        if wasCancelled || (error as NSError?)?.code == NSURLErrorCancelled { c?.resume(throwing: CancellationError()); return }
        if let error { c?.resume(throwing: error); return }
        // The connection can end cleanly before the last byte; the server's own length is the check (GOG's file list only has rounded sizes).
        if expectedTotal >= 0, written != UInt64(expectedTotal) {
            c?.resume(throwing: GogInstallError.invalid("The download ended early. Try again (it carries on from where it stopped).")); return
        }
        c?.resume()
    }
}
