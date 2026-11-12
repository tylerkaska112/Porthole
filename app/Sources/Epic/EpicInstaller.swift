// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz (willfaust/Madeira pull request 207); adapted for Porthole. Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Chunk assembly follows Legendary's downloader/mp/manager.py and workers.py (derrod and contributors, GPL-3.0-or-later).

import Foundation
import Combine

struct EpicInstalledGame: Codable {
    var game: EpicGame
    var appName: String
    var installDir: String
    var buildVersion: String
    var launchExe: String
    var launchCommand: String
    var prereqName: String
    var prereqPath: String
    var prereqArgs: String
    /// The game's own prerequisite installer was run from the game's page (it runs only when asked, never by itself).
    var prereqDone: Bool?
}

@MainActor final class EpicInstaller: ObservableObject {
    static let shared = EpicInstaller()
    enum State: Equatable { case queued, active, paused, failed(String), installed }
    struct Install: Equatable {
        var state: State
        var progress = SteamDownloadProgress()
        /// Queued, running, paused or failed (not a finished install).
        var isDownload: Bool { if case .installed = state { return false }; return true }
    }
    struct Pending: Codable { var game: EpicGame; var installDir: String }
    struct Store: Codable {
        var installed: [String: EpicInstalledGame] = [:]
        var pending: [String: Pending] = [:]
    }
    @Published private(set) var installs: [String: Install] = [:]
    @Published private(set) var installed: [String: EpicInstalledGame] = [:]
    @Published private(set) var ready = false
    @Published var error: String?
    private var pending: [String: Pending] = [:]
    private var queue: [String] = []
    private var active: (id: String, task: Task<Void, Never>)?
    private var removing = Set<String>()
    private var backgroundPaused = Set<String>()
    private var saving: Task<Void, Never>?
    private var lastProgressPublish = Date.distantPast
    private let worker = EpicInstallWorker(drive: AppModel.driveC)
    private let background = EpicBackground()

    private init() {
        Task {
            do {
                let store = try await worker.load()
                installed = store.installed; pending = store.pending
                for (id, record) in installed {
                    if await worker.exists(record.installDir + "/" + record.launchExe) {
                        installs[id] = Install(state: .installed)
                        register(record)
                    } else { installed.removeValue(forKey: id) }
                }
                for id in pending.keys { installs[id] = Install(state: .paused) }
                attachBackground()
                ready = true
            } catch { self.error = "Could not read Epic installs: " + ErrorText.plain(error) }
        }
    }
    private func attachBackground() {
        background.attach(active: { [weak self] in self?.hasActiveDownload == true },
                          pause: { [weak self] in self?.pauseForBackground() },
                          resume: { [weak self] in self?.resumeAfterBackground() })
        background.anyPaused = { [weak self] in self?.installs.values.contains { $0.isDownload && $0.state != .queued && $0.state != .active } == true }
    }
    private var hasActiveDownload: Bool { active != nil || !queue.isEmpty }
    /// A download queued, running, paused or failed. A finished install stays in
    /// `installs` with the state .installed, so "has an entry" is not "downloading".
    func isDownloading(_ appName: String) -> Bool { installs[appName]?.isDownload == true }
    /// The one being downloaded right now, and the ones waiting behind it in order (the downloads page lists them).
    var activeID: String? { active?.id }
    var queueOrder: [String] { queue }
    /// A game with a download or install on record, even when the library has not loaded.
    func game(for appName: String) -> EpicGame? { pending[appName]?.game ?? installed[appName]?.game }
    /// What is installed, as the page of a game shows it.
    func record(_ appName: String) -> EpicInstalledGame? { installed[appName] }

    /// The prerequisite installer a game's manifest lists (Unreal games: UE4PrereqSetup_x64.exe, which sets up the Visual C++ runtime and DirectX), when its file is in the install.
    struct Prerequisite { let name: String; let windowsPath: String; let args: String; let done: Bool }
    func prerequisite(_ appName: String) -> Prerequisite? {
        guard let r = installed[appName], !r.prereqPath.isEmpty else { return nil }
        let relative = r.installDir + "/" + r.prereqPath.replacingOccurrences(of: "\\", with: "/")
        let windows = AppModel.windowsPath(forRelative: relative)
        guard let file = AppModel.unixURL(forWindows: windows), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return Prerequisite(name: r.prereqName.isEmpty ? file.lastPathComponent : r.prereqName, windowsPath: windows, args: r.prereqArgs, done: r.prereqDone == true)
    }
    /// The prerequisite setup that was started: the game's app name and the id of the runner game the session was started with (so only the end of THAT session counts).
    private var prerequisiteRunner: (appName: String, gameID: UUID)?

    /// Runs the game's prerequisite installer in Porthole's Windows, once, when the person asks (the game's page). The person watches it on the desktop. Most games run without it
    /// (the Visual C++ runtime is provided), so it is never started on its own: an installer that hangs must not stand between a person and their game.
    func runPrerequisite(_ appName: String) {
        guard let p = prerequisite(appName) else { return }
        guard !AppModel.shared.session.isActive else { error = "End the running game before installing its prerequisites."; return }
        var runner = Game(name: "Prerequisites: " + p.name, exe: p.windowsPath)
        runner.args = p.args
        runner.inDesktop = true; runner.installer = true
        prerequisiteRunner = (appName, runner.id)      // overwritten by the next try, so a start that failed leaves nothing stuck
        error = nil
        LogStore.shared.log("[epic-install] running the prerequisite installer of \(appName): \(p.windowsPath) \(p.args)")
        AppModel.shared.session.start(runner)
    }

    /// The Wine session ended: if it was a prerequisite installer, remember that it ran.
    func sessionEnded() {
        guard let running = prerequisiteRunner, AppModel.shared.session.game?.id == running.gameID else { return }      // the end of some other session is not this setup's
        let name = running.appName
        prerequisiteRunner = nil
        installed[name]?.prereqDone = true
        persist()
        LogStore.shared.log("[epic-install] the prerequisite installer of \(name) finished")
    }
    /// The library entry of an installed game.
    func entry(_ appName: String) -> Game? {
        guard installed[appName] != nil else { return nil }
        return AppModel.shared.games.first { $0.epicAppName == appName }
    }
    private func register(_ record: EpicInstalledGame) {
        let windows = AppModel.windowsPath(forRelative: record.installDir + "/" + record.launchExe)
        AppModel.shared.upsertEpic(appName: record.appName, title: record.game.title, exe: windows, command: record.launchCommand,
                                   artwork: record.game.artworkURL, hero: record.game.heroURL)
    }
    private func persist() {
        let store = Store(installed: installed, pending: pending), previous = saving
        saving = Task {
            await previous?.value
            do { try await worker.save(store) }
            catch { self.error = "Could not save Epic installs: " + ErrorText.plain(error) }
        }
    }
    func install(_ game: EpicGame) {
        // An installed game can be installed again only to finish an update that was paused (its pending record is still there).
        guard ready, !removing.contains(game.appName), installed[game.appName] == nil || pending[game.appName] != nil else { return }
        let id = game.appName
        if installs[id]?.state == .active || installs[id]?.state == .queued { return }
        if pending[id] == nil {
            let safe = SteamInstallFiles.safeFolderName(game.title)
            // The app name suffix prevents two sanitized titles sharing an uninstall directory.
            let suffix = EpicSHA1.hash(Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            pending[id] = Pending(game: game, installDir: "Program Files/Epic Games/\(safe.isEmpty ? "Game" : safe)-\(suffix)")
        } else if game.catalogItemId != nil { pending[id]?.game = game }
        installs[id] = Install(state: .queued, progress: installs[id]?.progress ?? SteamDownloadProgress())
        queue.append(id); persist(); startNext()
    }
    /// An installed game whose newest build on Epic is not the one on this device.
    func updateAvailable(_ appName: String) -> Bool {
        guard let record = installed[appName], !record.buildVersion.isEmpty,
              let latest = EpicLibrary.shared.games.first(where: { $0.appName == appName })?.latestBuild else { return false }
        return record.buildVersion != latest
    }

    /// Brings an installed game to the newest build: only the files that differ are downloaded, into the folder it is in.
    func update(_ game: EpicGame) {
        guard ready, let record = installed[game.appName], !removing.contains(game.appName) else { return }
        let id = game.appName
        if installs[id]?.state == .active || installs[id]?.state == .queued { return }
        pending[id] = Pending(game: game.catalogItemId != nil ? game : record.game, installDir: record.installDir)
        installs[id] = Install(state: .queued, progress: SteamDownloadProgress())
        queue.append(id); persist(); startNext()
    }

    func pause(_ id: String) {
        backgroundPaused.remove(id)
        queue.removeAll { $0 == id }
        if active?.id == id { active?.task.cancel() }
        if installed[id] == nil, installs[id] != nil { installs[id]?.state = .paused }
        persist()
    }
    /// Puts a waiting (or paused) game first and starts it now; the one that was running is paused and waits for its turn again.
    func startNow(_ id: String) {
        guard ready, installed[id] == nil, pending[id] != nil, active?.id != id else { return }
        let displaced = active?.id
        queue.removeAll { $0 == id }
        queue.insert(id, at: 0)
        installs[id] = Install(state: .queued, progress: installs[id]?.progress ?? SteamDownloadProgress())
        if let displaced {
            // The running one is stopped (paused) and goes back behind the new first; its task ending starts the first in the queue.
            backgroundPaused.remove(displaced)
            active?.task.cancel()
            installs[displaced]?.state = .queued
            queue.insert(displaced, at: 1)
        } else { startNext() }
        persist()
    }
    /// The one running (or, when paused, the first stopped one): what the download card's Cancel button stops.
    func cancelCurrent() {
        if let id = activeID ?? queue.first ?? installs.first(where: { $0.value.isDownload })?.key { cancel(id) }
    }
    func pauseAll() {
        for id in queue + (active.map { [$0.id] } ?? []) { pause(id) }
    }
    func resumeAll() {
        for (id, install) in installs where install.isDownload && install.state != .queued && install.state != .active {
            if let game = pending[id]?.game { self.install(game) }
        }
    }
    private func pauseForBackground() {
        let ids = queue + (active.map { [$0.id] } ?? [])
        for id in ids { pause(id); backgroundPaused.insert(id) }
    }
    private func resumeAfterBackground() {
        let ids = backgroundPaused; backgroundPaused.removeAll()
        for id in ids { if let game = pending[id]?.game { install(game) } }
    }
    func cancel(_ id: String) { remove(id, uninstall: false) }
    func uninstall(_ id: String) { remove(id, uninstall: true) }
    private func remove(_ id: String, uninstall: Bool) {
        // Cancelling an update must never delete the game that is installed: only the update stops.
        if !uninstall, installed[id] != nil, !removing.contains(id) {
            removing.insert(id); pause(id)
            let task = active?.id == id ? active?.task : nil
            Task {
                await task?.value
                pending.removeValue(forKey: id)
                installs[id] = Install(state: .installed)
                persist(); removing.remove(id)
            }
            return
        }
        guard ready, !removing.contains(id), let dir = pending[id]?.installDir ?? installed[id]?.installDir else { return }
        if uninstall, AppModel.shared.session.isActive, AppModel.shared.session.game?.epicAppName == id {
            error = "End the game session before uninstalling."; return
        }
        removing.insert(id); pause(id)
        let task = active?.id == id ? active?.task : nil
        Task {
            await task?.value
            do {
                try await worker.remove(dir)
                pending.removeValue(forKey: id)
                if uninstall {
                    installed.removeValue(forKey: id)
                    AppModel.shared.removeEpic(appName: id)
                }
                installs.removeValue(forKey: id); persist()
            } catch { installs[id] = Install(state: .failed("Could not remove Epic files: " + ErrorText.plain(error))) }
            removing.remove(id)
        }
    }
    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let job = pending[id], !removing.contains(id) else { startNext(); return }
        installs[id]?.state = .active
        background.downloadStarted(name: job.game.title)
        let task = Task(priority: .userInitiated) {
            var outcome = EpicBackground.Outcome.paused
            do {
                guard let catalog = job.game.catalogItemId else {
                    EpicLibrary.shared.refresh()
                    throw EpicContentError.invalid("Refresh your Epic library, then try installing again.")
                }
                let token = try await EpicAuth.shared.validAccessToken()
                let record = try await worker.run(job, catalog: catalog, token: token) { progress in
                    await MainActor.run {
                        guard self.active?.id == id, self.installs[id]?.state == .active else { return }
                        // The worker reports after every piece of every file (hundreds a second); each report redraws every screen that shows Epic games.
                        let now = Date()
                        guard now.timeIntervalSince(self.lastProgressPublish) >= 0.5 || self.installs[id]?.progress.phase != progress.phase else { return }
                        self.lastProgressPublish = now
                        self.installs[id]?.progress = progress
                        self.background.progress(progress, waiting: self.queue.count)
                    }
                }
                try Task.checkCancellation()
                installed[id] = record; pending.removeValue(forKey: id)
                register(record); installs[id]?.state = .installed; persist()
                outcome = .completed
            } catch {
                if Task.isCancelled {
                    if installs[id]?.state != .queued { installs[id]?.state = .paused }
                } else {
                    let message = (error as? EpicAuthError)?.message ?? ErrorText.plain(error)
                    installs[id]?.state = .failed(message)
                    outcome = .failed(message)
                    LogStore.shared.log("[epic-install] failure completed-bytes=\(installs[id]?.progress.doneBytes ?? 0) total-bytes=\(installs[id]?.progress.totalBytes ?? 0) reason=\(message)", level: .error)
                }
            }
            active = nil
            background.downloadEnded(name: job.game.title, outcome: outcome, queueEmpty: queue.isEmpty)
            startNext()
        }
        active = (id, task)
    }
}

/// All hashing, decompression and file writes stay off the main actor.
private actor EpicInstallWorker {
    private let drive: URL
    private let storeURL: URL

    init(drive: URL, support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.drive = drive; storeURL = support.appendingPathComponent("epic-installs.json")
    }
    func load() throws -> EpicInstaller.Store {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return EpicInstaller.Store() }
        return try JSONDecoder().decode(EpicInstaller.Store.self, from: Data(contentsOf: storeURL))
    }
    func save(_ store: EpicInstaller.Store) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }
    func exists(_ path: String) -> Bool { (try? safeURL(path, under: drive)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    private func safeURL(_ path: String, under root: URL) throws -> URL {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":") || $0.contains("\0") }) else {
            throw EpicContentError.invalid("Unsafe path in Epic content.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(path).standardizedFileURL
        // Reject existing symlinks too: writes must never escape through an old install.
        var cursor = base
        for part in parts {
            cursor.appendPathComponent(String(part))
            if let type = try? FileManager.default.attributesOfItem(atPath: cursor.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink { throw EpicContentError.invalid("Epic install path contains a symbolic link.") }
        }
        guard url.path.hasPrefix(base.path + "/") else { throw EpicContentError.invalid("Unsafe Epic install path.") }
        return url
    }
    private func folder(_ relative: String) throws -> URL {
        guard relative.hasPrefix("Program Files/Epic Games/"), relative.split(separator: "/").count == 3 else {
            throw EpicContentError.invalid("Invalid Epic install directory.")
        }
        return try safeURL(relative, under: drive)
    }
    func remove(_ relative: String) throws {
        let url = try folder(relative)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func run(_ job: EpicInstaller.Pending, catalog: String, token: String,
             progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> EpicInstalledGame {
        let (manifest, base) = try await EpicManifest.fetch(namespace: job.game.namespace, catalogItemID: catalog,
                                                         appName: job.game.appName, token: token)
        return try await assemble(job, manifest: manifest, base: base, progress: progress)
    }
    func assemble(_ job: EpicInstaller.Pending, manifest: EpicManifest, base: URL,
                  fetch: @escaping @Sendable (URL, EpicManifest.Chunk) async throws -> Data = { url, chunk in
                      try await EpicManifest.download(URLRequest(url: url), limit: chunk.fileSize)
                  },
                  progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> EpicInstalledGame {
        try Task.checkCancellation()
        // The build's own AppName can differ from the library's (another internal name,
        // or other capitals) for the right game: the manifest came from that game's
        // assets endpoint and matched Epic's SHA-1, and Legendary does not compare them.
        // Logged, never fatal: refusing here stopped installs of games the account owns.
        if manifest.meta.appName.caseInsensitiveCompare(job.game.appName) != .orderedSame {
            LogStore.shared.log("[epic-install] manifest app name differs from the library's (accepted)")
        }
        let root = try folder(job.installDir), requestedLaunch = manifest.meta.launchExe.replacingOccurrences(of: "\\", with: "/")
        _ = try safeURL(requestedLaunch, under: root)
        if !manifest.meta.prereqPath.isEmpty { _ = try safeURL(manifest.meta.prereqPath, under: root) }
        guard let launchFile = manifest.files.first(where: { $0.filename.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(requestedLaunch) == .orderedSame }) else {
            throw EpicContentError.invalid("Epic manifest does not contain its launch executable.")
        }
        let launch = launchFile.filename.replacingOccurrences(of: "\\", with: "/")
        let stagingKey = EpicSHA1.hash(Data(job.game.appName.utf8)).map { String(format: "%02x", $0) }.joined()
        let staging = storeURL.deletingLastPathComponent().appendingPathComponent("Epic Staging/" + stagingKey)
        // Only unfinished data lives here. A killed process cannot leave large orphan files in the game.
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var chunks: [String: EpicManifest.Chunk] = [:]
        for chunk in manifest.chunks {
            guard chunks[chunk.guid] == nil, chunk.windowSize > 0, chunk.windowSize <= EpicChunk.maximumSize,
                  chunk.fileSize > 0, chunk.fileSize <= EpicChunk.maximumSize + 1024 else {
                throw EpicContentError.invalid("Invalid Epic chunk description.")
            }
            _ = try chunk.path(featureLevel: manifest.meta.featureLevel)
            chunks[chunk.guid] = chunk
        }
        var names = Set<String>(), remaining: [String: Int] = [:], files: [EpicManifest.File] = []
        var required: UInt64 = 0, reused = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let url = try safeURL(file.filename, under: root)
            guard file.symlink.isEmpty, names.insert(url.path.lowercased()).inserted else {
                throw EpicContentError.invalid("Duplicate or symbolic-link file in Epic manifest.")
            }
            for part in file.parts {
                guard let chunk = chunks[part.guid], part.offset <= chunk.windowSize, part.size <= chunk.windowSize - part.offset else {
                    throw EpicContentError.invalid("Epic file references an invalid chunk part.")
                }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if size.map(UInt64.init) == file.size, (try? EpicSHA1.file(url)) == file.sha { reused += 1; continue }
            files.append(file); required += file.size
            for part in file.parts { remaining[part.guid, default: 0] += 1 }
        }
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let values = try drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Some volumes return zero for the reclaimable-space estimate despite having free blocks.
        let capacity = max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))
        guard UInt64(max(0, capacity)) >= required + 128 * 1024 * 1024 else {
            throw EpicContentError.invalid("Not enough free space for this Epic game (\(required / 1024 / 1024) MB plus working space required).")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let total = remaining.keys.reduce(UInt64(0)) { $0 + UInt64(chunks[$1]!.fileSize) }
        var status = SteamDownloadProgress()
        status.phase = .downloading; status.totalBytes = total
        var fetched = Set<String>(), received: UInt64 = 0
        let start = Date()
        LogStore.shared.log("[epic-install] start files=\(manifest.files.count) reused=\(reused) chunks=\(remaining.count) download-bytes=\(total) write-bytes=\(required)")
        await progress(status)
        // Porthole 0.50.380: chunks are fetched ahead of the writer in a sliding window (adaptive number in flight, a memory budget), not four at a time with a wait
        // for the slowest of them before the next four. The old loop was 2-3x slower than the Steam downloader on the same connection.
        var order: [String] = [], queued = Set<String>()
        for file in files { for part in file.parts where queued.insert(part.guid).inserted { order.append(part.guid) } }
        let counter = EpicByteCounter()
        var controller = ConcurrencyController(start: 12, floor: 6, ceiling: 48)
        var inflight: [String: Task<(Data, Int), Error>] = [:]   // started, not yet taken by the writer
        var ready: [String: (Data, Int)] = [:]                    // arrived, waiting for the writer's first use
        var kept: [String: Data] = [:], keptOrder: [String] = []  // used once and needed again by a later part (small LRU)
        var next = 0, heldBytes = 0
        let budget = 96 * 1024 * 1024
        func begin(_ guid: String) {
            let chunk = chunks[guid]!, url = base.appendingPathComponent((try? chunk.path(featureLevel: manifest.meta.featureLevel)) ?? "")
            heldBytes += chunk.windowSize
            inflight[guid] = Task.detached(priority: .userInitiated) {   // off the worker: the downloads and their decompression run in parallel
                var lastError: Error?
                for attempt in 0..<4 {
                    try Task.checkCancellation()
                    do {
                        let bytes = try await fetch(url, chunk)
                        counter.add(bytes.count)
                        return (try EpicChunk.parse(bytes, expected: chunk), bytes.count)
                    } catch {
                        if error is CancellationError { throw error }
                        lastError = error
                        try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                    }
                }
                throw lastError ?? EpicContentError.invalid("Epic chunk download failed.")
            }
        }
        func pump() {
            controller.observe(totalBytes: counter.value, now: Date())
            while next < order.count, inflight.count < controller.target, heldBytes + chunks[order[next]]!.windowSize <= budget {
                let guid = order[next]; next += 1
                if inflight[guid] == nil, ready[guid] == nil { begin(guid) }
            }
        }
        defer { for task in inflight.values { task.cancel() } }
        for file in files {
            try Task.checkCancellation()
            let target = try safeURL(file.filename, under: root)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Publish only a verified file; a pause discards at most this file's unfinished data.
            let temporary = staging.appendingPathComponent("file.part")
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                var hash = EpicSHA1()
                for part in file.parts {
                    try Task.checkCancellation()
                    pump()
                    let data: Data
                    if let again = kept[part.guid] { data = again }
                    else {
                        if inflight[part.guid] == nil, ready[part.guid] == nil { begin(part.guid) }   // evicted copy of a shared chunk: fetch it again
                        if ready[part.guid] == nil, let task = inflight[part.guid] {
                            let (parsed, size) = try await task.value
                            inflight[part.guid] = nil; ready[part.guid] = (parsed, size)
                            received += UInt64(size)
                            if fetched.insert(part.guid).inserted { status.doneBytes += UInt64(size) }
                        }
                        guard let have = ready[part.guid] else { throw EpicContentError.invalid("Missing Epic chunk.") }
                        data = have.0
                    }
                    let bytes = data.subdata(in: part.offset..<part.offset + part.size)
                    try handle.write(contentsOf: bytes); hash.update(bytes)
                    remaining[part.guid, default: 0] -= 1
                    if remaining[part.guid] == 0 {
                        if ready.removeValue(forKey: part.guid) != nil { heldBytes -= chunks[part.guid]!.windowSize }
                        kept.removeValue(forKey: part.guid); keptOrder.removeAll { $0 == part.guid }
                    } else {
                        if ready.removeValue(forKey: part.guid) != nil { heldBytes -= chunks[part.guid]!.windowSize }
                        kept[part.guid] = data; keptOrder.removeAll { $0 == part.guid }; keptOrder.append(part.guid)
                        while kept.values.reduce(0, { $0 + $1.count }) > 8 * 1024 * 1024, let oldest = keptOrder.first {
                            kept.removeValue(forKey: oldest); keptOrder.removeFirst()
                        }
                    }
                    pump()
                    status.bytesPerSecond = Double(received) / max(0.1, Date().timeIntervalSince(start))
                    await progress(status)
                }
                guard hash.finish() == file.sha else { throw EpicContentError.invalid("Epic file SHA-1 mismatch. Resume to retry.") }
                try handle.close()   // no fsync per file: a resumed install checks every file's size and SHA-1 before it is reused
                try Task.checkCancellation()
                // POSIX rename replaces atomically on the same volume, including an old partial install.
                guard rename(temporary.path, target.path) == 0 else { throw EpicContentError.invalid("Could not finalize an Epic game file.") }
            } catch {
                try? handle.close(); try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        status.phase = .finishing; await progress(status)
        LogStore.shared.log("[epic-install] finish files=\(manifest.files.count) reused=\(reused) chunks=\(fetched.count) received-bytes=\(received) written-bytes=\(required)")
        return EpicInstalledGame(game: job.game, appName: job.game.appName, installDir: job.installDir,
                                 buildVersion: manifest.meta.buildVersion, launchExe: launch, launchCommand: manifest.meta.launchCommand,
                                 prereqName: manifest.meta.prereqName, prereqPath: manifest.meta.prereqPath, prereqArgs: manifest.meta.prereqArgs)
    }
}

/// Bytes received so far, written by the download tasks and read by the window logic.
final class EpicByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    func add(_ n: Int) { lock.lock(); bytes &+= UInt64(n); lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return bytes }
}
