// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Installing an Amazon Games game. Amazon's download system lists every file of a build in a signed manifest and serves each file whole, named by its SHA-256:
// ask for the build (signed in), read and verify the manifest, fetch the files (several at once, big ones in range pieces), check each against the manifest's hash, and
// put them in C:\Amazon\<name>. The game's own fuel.json says which program starts it.
//
// Nothing here logs a token or a download address (they carry credentials); only counts, sizes and states.

import Foundation
import Combine
import CryptoKit
import UIKit

struct AmazonInstalledGame: Codable {
    var game: AmazonGame
    /// Relative to drive C ("Amazon/Some_Game").
    var installDir: String
    /// The program's Windows path and its arguments, from the game's own fuel.json.
    var exe: String
    var args: String
    /// The program's working folder when fuel.json names one (a C:\ path).
    var workDir: String?
    /// Amazon's build id it was installed from, so a newer build can be told apart later.
    var version: String
}

@MainActor final class AmazonInstaller: ObservableObject {
    static let shared = AmazonInstaller()

    enum State: Equatable { case queued, active, paused, failed(String), installed }
    struct Install: Equatable {
        var state: State
        var progress = SteamDownloadProgress()
        var isDownload: Bool { switch state { case .queued, .active, .paused, .failed: return true; default: return false } }
    }
    struct Store: Codable {
        var installed: [String: AmazonInstalledGame] = [:]
        var pending: [String: AmazonGame] = [:]
    }

    @Published private(set) var installs: [String: Install] = [:]
    @Published private(set) var installed: [String: AmazonInstalledGame] = [:]
    @Published private(set) var ready = false
    @Published var error: String?

    private var pending: [String: AmazonGame] = [:]
    private var queue: [String] = []
    private var active: (id: String, task: Task<Void, Never>)?
    private var removing = Set<String>()
    private var backgroundPaused = Set<String>()
    private var saving: Task<Void, Never>?
    private var lastProgressPublish = Date.distantPast
    private let worker = AmazonInstallWorker()
    private let background = EpicBackground(store: "amazon", label: "Amazon Games")

    private init() {
        Task {
            do {
                let store = try await worker.load()
                installed = store.installed; pending = store.pending
                for (id, record) in installed {
                    if await worker.exists(record.exe) { installs[id] = Install(state: .installed); register(record) }
                    else { installed.removeValue(forKey: id) }
                }
                for (id, _) in pending where installs[id] == nil { installs[id] = Install(state: .paused) }
                background.attach(active: { [weak self] in self?.active != nil || self?.queue.isEmpty == false },
                                  pause: { [weak self] in self?.pauseForBackground() },
                                  resume: { [weak self] in self?.resumeAfterBackground() })
                background.anyPaused = { [weak self] in self?.installs.values.contains { $0.state == .paused } == true }
                ready = true
            } catch { self.error = "Could not read Amazon installs: " + error.localizedDescription }
        }
    }

    // MARK: Asking

    func isInstalled(_ id: String) -> Bool { installs[id]?.state == .installed }
    var activeID: String? { active?.id }
    func record(_ id: String) -> AmazonInstalledGame? { installed[id] }
    func game(for id: String) -> AmazonGame? { pending[id] ?? installed[id]?.game }
    /// The game as the library holds it once installed (reports and settings are about that program).
    func entry(_ id: String) -> Game? { installed[id] == nil ? nil : AppModel.shared.games.first { $0.amazonID == id } }

    private func register(_ record: AmazonInstalledGame) {
        AppModel.shared.upsertAmazon(id: record.game.id, title: record.game.title, exe: record.exe, args: record.args, workDir: record.workDir, art: record.game.art)
    }

    private func persist() {
        let store = Store(installed: installed, pending: pending), previous = saving
        saving = Task {
            await previous?.value
            do { try await worker.save(store) } catch { self.error = "Could not save Amazon installs: " + error.localizedDescription }
        }
    }

    /// The library's newest pictures for the games that are installed (their records kept the picture of the day they were installed).
    func refreshArt(from list: [AmazonGame]) {
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

    func install(_ game: AmazonGame) {
        guard ready, !removing.contains(game.id), installed[game.id] == nil else { return }
        let id = game.id
        if installs[id]?.state == .active || installs[id]?.state == .queued { return }
        pending[id] = game
        installs[id] = Install(state: .queued, progress: installs[id]?.progress ?? SteamDownloadProgress())
        error = nil
        queue.append(id); persist(); startNext()
    }

    func pause(_ id: String) {
        backgroundPaused.remove(id)
        queue.removeAll { $0 == id }
        if active?.id == id { active?.task.cancel() }
        if installed[id] == nil, installs[id]?.state == .queued || installs[id]?.state == .active { installs[id]?.state = .paused }
        persist()
    }
    func pauseAll() { for id in queue + (active.map { [$0.id] } ?? []) { pause(id) } }
    /// The games waiting, in the order they will start (the shared Downloads page shows them).
    var queueOrder: [String] { queue }
    /// Starts a paused or failed download again.
    func resume(_ id: String) { if let game = pending[id] { install(game) } }
    /// Puts a waiting download first: the one running now is stopped, goes back behind it, and carries on afterwards.
    func startNow(_ id: String) {
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
    func cancel(_ id: String) { remove(id, uninstall: false) }
    func uninstall(_ id: String) { remove(id, uninstall: true) }

    private func remove(_ id: String, uninstall: Bool) {
        guard ready, !removing.contains(id) else { return }
        if uninstall, AppModel.shared.session.isActive, AppModel.shared.session.game?.amazonID == id {
            error = "End the game session before uninstalling."; return
        }
        if !uninstall, installed[id] != nil { return }
        removing.insert(id); pause(id)
        let task = active?.id == id ? active?.task : nil
        let dir = installed[id]?.installDir ?? (pending[id].map { "Amazon/" + AmazonInstallWorker.folderName(for: $0) })
        let folder = (installed[id]?.game ?? pending[id]).map { AmazonInstallWorker.folderName(for: $0) }
        Task {
            await task?.value
            await worker.removeFiles(installDir: dir, staging: folder)
            pending.removeValue(forKey: id)
            if uninstall { installed.removeValue(forKey: id); AppModel.shared.removeAmazon(id: id) }
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
                let record = try await worker.download(game) { progress in
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
                installed[id] = record; pending.removeValue(forKey: id)
                register(record)
                installs[id] = Install(state: .installed)
                persist()
                outcome = .completed
                LogStore.shared.log("[amazon-install] installed \(game.title)")
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if installs[id]?.state != .queued { installs[id]?.state = .paused }
                } else {
                    let message = (error as? AmazonAuthError)?.message ?? error.localizedDescription
                    installs[id]?.state = .failed(message)
                    outcome = .failed(message)
                    LogStore.shared.log("[amazon-install] failure: \(message)", level: .error)
                }
            }
            active = nil
            background.downloadEnded(name: game.title, outcome: outcome, queueEmpty: queue.isEmpty)
            startNext()
        }
        active = (id, task)
    }
}

// MARK: - Worker

/// Counts bytes from many downloads at once and reports at most four times a second.
private final class AmazonMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private let start = Date()
    private var lastReport = Date.distantPast
    private var done: UInt64
    private var inFlight: [Int: UInt64] = [:]
    private var fetchedThisRun: UInt64 = 0
    init(total: UInt64, alreadyHave: UInt64) { self.total = total; done = alreadyHave }

    /// A file's size on disk grew to `have` (its first report counts from what was there already).
    func set(file: Int, have: UInt64, resumedAt: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let before = inFlight[file] ?? 0
        if have > before {
            done += have - before                               // what an earlier try left on disk counts as done ...
            let counted = max(before, resumedAt)
            if have > counted { fetchedThisRun += have - counted }   // ... but not as speed
        }
        inFlight[file] = have
    }
    func add(_ bytes: UInt64) { lock.lock(); done += bytes; fetchedThisRun += bytes; lock.unlock() }
    /// Bytes already on disk from an earlier try that turned out to be useless (a part file that failed its hash): taken back.
    func take(back bytes: UInt64) { lock.lock(); done = done > bytes ? done - bytes : 0; lock.unlock() }

    func progress(force: Bool = false) -> SteamDownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.25 else { return nil }
        lastReport = now
        return SteamDownloadProgress(doneBytes: min(done, total), totalBytes: total, bytesPerSecond: Double(fetchedThisRun) / max(0.5, now.timeIntervalSince(start)))
    }
}

/// The address a build's files hang off. It can carry a signature that runs out, so it can be asked for again.
private actor AmazonSource {
    private var base: URL
    private var generation = 0
    private let renewal: @Sendable () async throws -> URL
    init(base: URL, renewal: @escaping @Sendable () async throws -> URL) { self.base = base; self.renewal = renewal }
    func current() -> (url: URL, generation: Int) { (base, generation) }
    /// Asks Amazon for a fresh address, unless another download already did since `seen`.
    func renew(after seen: Int) async throws {
        guard seen == generation else { return }
        base = try await renewal()
        generation += 1
    }
    func file(_ hashHex: String) -> (url: URL, generation: Int) {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = c.path.hasSuffix("/") ? c.path + "files/" + hashHex : c.path + "/files/" + hashHex
        return (c.url!, generation)
    }
    func manifest() -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = c.path.hasSuffix("/") ? c.path + "manifest.proto" : c.path + "/manifest.proto"
        return c.url!
    }
}

/// File work and network off the main actor.
private actor AmazonInstallWorker {
    private let storeURL: URL
    private let support: URL

    init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.support = support
        storeURL = support.appendingPathComponent("amazon-installs.json")
    }
    func load() throws -> AmazonInstaller.Store {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return AmazonInstaller.Store() }
        return try JSONDecoder().decode(AmazonInstaller.Store.self, from: Data(contentsOf: storeURL))
    }
    func save(_ store: AmazonInstaller.Store) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }

    private var drive: URL { AppModel.driveC }
    func exists(_ windowsPath: String) -> Bool {
        AppModel.unixURL(forWindows: windowsPath).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The folder name the game goes in: the title kept to plain letters, plus a few characters of the product id so two games never share one.
    nonisolated static func folderName(for game: AmazonGame) -> String {
        let letters = game.title.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
        let squeezed = letters.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        let tag = SHA256.hash(data: Data(game.id.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        return (squeezed.isEmpty ? "game" : String(squeezed.prefix(40))) + "_" + tag
    }
    private func staging(_ folder: String) -> URL { support.appendingPathComponent("Amazon Staging/\(folder)", isDirectory: true) }

    func removeFiles(installDir: String?, staging folder: String?) {
        if let folder, !folder.contains("/"), !folder.contains("..") { try? FileManager.default.removeItem(at: staging(folder)) }
        if let installDir, installDir.hasPrefix("Amazon/"), !installDir.contains("..") {
            try? FileManager.default.removeItem(at: drive.appendingPathComponent(installDir, isDirectory: true))
        }
    }

    // MARK: Download

    private struct Job { let index: Int; let file: AmazonManifestFile; let target: URL }

    func download(_ game: AmazonGame, progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> AmazonInstalledGame {
        var status = SteamDownloadProgress()
        await progress(status)
        let (token, _) = try await AmazonAuth.shared.session()
        let entitlement = game.entitlementID
        let (version, base) = try await AmazonAPI.download(entitlementID: entitlement, token: token)
        let source = AmazonSource(base: base, renewal: {
            let (fresh, _) = try await AmazonAuth.shared.session()
            return try await AmazonAPI.download(entitlementID: entitlement, token: fresh).base
        })
        let manifest = try await Self.fetchManifest(source)

        // Which files, where. Windows paths are not case-sensitive: the first spelling of a path wins.
        let folder = Self.folderName(for: game)
        let root = drive.appendingPathComponent("Amazon/\(folder)", isDirectory: true)
        var seen = Set<String>(), jobs: [Job] = []
        for file in manifest.files {
            guard let relative = Self.safeRelativePath(file.path) else { throw AmazonError.invalid("Amazon's file list holds an unsafe path, so nothing was installed.") }
            guard file.hashAlgorithm == "sha256", file.hash.count == 32 else { throw AmazonError.invalid("This game's files use a checksum this version does not know.") }
            guard seen.insert(relative.lowercased()).inserted else { continue }
            jobs.append(Job(index: jobs.count, file: file, target: root.appendingPathComponent(relative)))
        }
        let total = jobs.reduce(UInt64(0)) { $0 + UInt64($1.file.size) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in manifest.directories {
            if let relative = Self.safeRelativePath(directory) { try? FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true) }
        }
        let parts = staging(folder)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)

        // Files already in place (an earlier try, or the same build): kept when their hash matches.
        status.phase = .preparing
        await progress(status)
        var todo: [Job] = [], haveBytes: UInt64 = 0
        for job in jobs {
            try Task.checkCancellation()
            if let size = Self.size(of: job.target), size == UInt64(job.file.size), (try? Self.sha256(of: job.target)) == job.file.hash { haveBytes += size; continue }
            todo.append(job)
        }
        var needed: UInt64 = 0
        for job in todo { needed += UInt64(job.file.size) - min(Self.size(of: parts.appendingPathComponent(job.file.hashHex + ".part")) ?? 0, UInt64(job.file.size)) }
        let values = try drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = UInt64(max(0, max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))))
        guard free >= needed + 256 * 1024 * 1024 else {
            throw AmazonError.invalid("Not enough free space: this game needs about \(needed / 1_048_576) MB more.")
        }
        LogStore.shared.log("[amazon-install] build \(version.prefix(12)): \(jobs.count) file(s), \(todo.count) to fetch, \(total / 1_048_576) MB in all, \(haveBytes / 1_048_576) MB already here")

        status.phase = .downloading; status.totalBytes = total; status.doneBytes = haveBytes
        await progress(status)
        let meter = AmazonMeter(total: total, alreadyHave: haveBytes)
        // The big files go one at a time (each is fetched in range pieces, many at once); the small ones run several together.
        let big = todo.filter { $0.file.size >= 16 * 1024 * 1024 }, small = todo.filter { $0.file.size < 16 * 1024 * 1024 }
        for job in big {
            try Task.checkCancellation()
            try await Self.fetch(job, parts: parts, source: source, meter: meter)
            if let p = meter.progress() { await progress(p) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = small.makeIterator(), running = 0
            while true {
                while running < 8, let job = iterator.next() {
                    group.addTask { try await Self.fetch(job, parts: parts, source: source, meter: meter) }
                    running += 1
                }
                guard running > 0 else { break }
                try await group.next()
                running -= 1
                if let p = meter.progress() { await progress(p) }
            }
        }
        if let p = meter.progress(force: true) { await progress(p) }
        status.phase = .finishing
        await progress(status)
        try? FileManager.default.removeItem(at: parts)
        return try Self.finish(game, folder: folder, root: root, version: version)
    }

    /// Reads and checks the build's manifest.
    private static func fetchManifest(_ source: AmazonSource) async throws -> AmazonManifest {
        var request = URLRequest(url: await source.manifest())
        request.timeoutInterval = 60
        let data: Data, response: URLResponse
        do { (data, response) = try await StoreNetwork.session.data(for: request) } catch { throw AmazonAuthError.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AmazonError.invalid("Amazon did not give the file list for this game (answer \(status)).") }
        return try AmazonManifest.parse(data)
    }

    /// One file into place: fetched into the staging folder (a part file carries on after a pause), checked against the manifest's hash, then moved in.
    private static func fetch(_ job: Job, parts: URL, source: AmazonSource, meter: AmazonMeter) async throws {
        try Task.checkCancellation()
        let part = parts.appendingPathComponent(job.file.hashHex + ".part")
        let expected = UInt64(job.file.size)
        var attempt = 0
        while true {
            attempt += 1
            let resumedAt = min(size(of: part) ?? 0, expected)
            if let have = size(of: part), have > expected { try? FileManager.default.removeItem(at: part) }
            let (url, generation) = await source.file(job.file.hashHex)
            do {
                if expected == 0 {
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                } else if expected < 16 * 1024 * 1024 {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 60
                    let (data, response) = try await StoreNetwork.session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw AmazonError.invalid("The download server answered \(status).") }
                    guard UInt64(data.count) == expected else { throw AmazonError.invalid("A game file arrived with the wrong size. Try again.") }
                    try data.write(to: part, options: .atomic)
                    meter.add(expected)
                } else {
                    try await GogFileFetcher.fetchFast(url: url, to: part) { have in meter.set(file: job.index, have: have, resumedAt: resumedAt) }
                }
            } catch {
                // An address that has run out of time answers 403: ask Amazon for a fresh one and carry on from what is on disk.
                if !(error is CancellationError), "\(error.localizedDescription)".contains("403"), attempt < 3 {
                    try await source.renew(after: generation)
                    continue
                }
                throw error
            }
            guard size(of: part) == expected else {
                try? FileManager.default.removeItem(at: part)
                throw AmazonError.invalid("A game file ended early. Try again (finished files are kept).")
            }
            guard (try? sha256(of: part)) == job.file.hash else {
                try? FileManager.default.removeItem(at: part)
                meter.take(back: expected)
                throw AmazonError.invalid("\(job.file.path.split(separator: "\\").last.map(String.init) ?? "A game file") failed Amazon's checksum. Try again.")
            }
            try FileManager.default.createDirectory(at: job.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: job.target)
            guard rename(part.path, job.target.path) == 0 else { throw AmazonError.invalid("Could not finish a game file.") }
            return
        }
    }

    // MARK: Helpers

    private static func size(of url: URL) -> UInt64? { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value }

    static func sha256(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return Data(hash.finalize())
    }

    /// A path from the manifest ("Bin\\game.exe") as a relative path with "/", or nil if it could leave the game folder.
    nonisolated static func safeRelativePath(_ raw: String) -> String? {
        let parts = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("\\"), !raw.contains(":"), !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.joined(separator: "/")
    }

    /// The path with each part spelled as it is on disk (matched ignoring case), or nil when some part is not there.
    private static func resolveCase(root: URL, components: [String]) -> [String]? {
        var current = root, result: [String] = []
        for part in components {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            guard let match = names.first(where: { $0 == part }) ?? names.first(where: { $0.lowercased() == part.lowercased() }) else { return nil }
            result.append(match)
            current.appendPathComponent(match)
        }
        return result
    }

    /// Reads the game's fuel.json for the program that starts it.
    private static func finish(_ game: AmazonGame, folder: String, root: URL, version: String) throws -> AmazonInstalledGame {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var command: String?, arguments: [String] = [], workSub: String?
        if let name = contents.first(where: { $0.lowercased() == "fuel.json" }), let data = try? Data(contentsOf: root.appendingPathComponent(name)),
           let launch = AmazonLaunch.parse(data) {
            command = launch.command; arguments = launch.arguments; workSub = launch.workingSubdirectory
            LogStore.shared.log("[amazon-install] fuel.json read")
        } else {
            let exes = contents.filter { $0.lowercased().hasSuffix(".exe") && !$0.lowercased().hasPrefix("unins") }
            if exes.count == 1 { command = exes[0]; LogStore.shared.log("[amazon-install] no fuel.json; using the only program in the folder") }
        }
        guard var program = command?.replacingOccurrences(of: "/", with: "\\") else {
            throw AmazonError.invalid("The game installed, but Porthole could not tell which program starts it. Add it from Files with the + button (folder C:\\Amazon\\\(folder)).")
        }
        if let real = resolveCase(root: root, components: program.split(separator: "\\").map(String.init)) { program = real.joined(separator: "\\") }
        let windowsRoot = "C:\\Amazon\\\(folder)"
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(program.replacingOccurrences(of: "\\", with: "/")).path) else {
            throw AmazonError.invalid("The game installed but \(program) is not there.")
        }
        var workDir: String?
        if let sub = workSub?.replacingOccurrences(of: "/", with: "\\"), !sub.isEmpty, safeRelativePath(sub) != nil {
            let resolved = resolveCase(root: root, components: sub.split(separator: "\\").map(String.init))?.joined(separator: "\\") ?? sub
            workDir = windowsRoot + "\\" + resolved
        }
        let args = arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        return AmazonInstalledGame(game: game, installDir: "Amazon/\(folder)", exe: windowsRoot + "\\" + program, args: args, workDir: workDir, version: version)
    }
}
