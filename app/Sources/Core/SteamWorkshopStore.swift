// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Steam Workshop inside the app: browsing a game's items, subscribing, and keeping the subscribed items downloaded where the game (and Steam's own client) look for them.
/// The protocol work is in `Sources/Steam/SteamWorkshop.swift` and `SteamInstaller` (workshop mode); this is the layer the screens talk to.
@MainActor
final class SteamWorkshopStore: ObservableObject {
    static let shared = SteamWorkshopStore()

    struct Progress: Equatable {
        /// `waiting`: the item is in the game's Workshop depot and the app's Steam connection is closed while a game runs; it starts when the game ends.
        enum State: Equatable { case queued, active, waiting, failed(String) }
        var state: State
        var fraction = 0.0
    }

    struct Job: Equatable, Codable {
        var appID: Int
        var gameName: String
        var item: UInt64
        var title: String
        var manifest: UInt64
        var updated: Date?
        var fileURL: URL?
        var filename: String?
        var creator: UInt64?
        var creatorApp: Int?
    }

    /// Items being fetched or waiting, by `key(appID, item)`; a failed one stays until it is tried again or dismissed.
    @Published private(set) var progress: [String: Progress] = [:]
    /// Goes up whenever an item arrives or goes, so screens that list what is installed read it again.
    @Published private(set) var changes = 0
    /// How many subscribed items are missing or older than Steam's version, per game, from the last check that did not download them.
    @Published private(set) var updates: [Int: Int] = [:]
    /// Items that finished downloading since the app opened (the in-game Workshop page offers a restart when it is above zero).
    @Published private(set) var arrived = 0
    private var lastCheck: [Int: Date] = [:]

    /// Whether the app downloads Workshop updates by itself when a game's page opens (on by default).
    static var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: "f4.workshopAutoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "f4.workshopAutoUpdate") }
    }

    private let service = SteamService.shared
    /// Items that wait for the game to end (see `Progress.State.waiting`).
    private var deferred: [Job] = []
    /// Every item that was asked for and has not finished (queued, downloading or waiting), kept across launches: after a game the app closes itself and is opened again, and
    /// the same happens if it is force-closed, so the list has to survive. Failed items are not kept.
    private var unfinished: [String: Job] = [:] { didSet { saveUnfinished() } }
    private static let unfinishedKey = "steam.workshop.unfinished.v1"
    private var queue: [Job] = []
    private var running = false
    private var depots: [Int: Int] = [:]
    /// The job of an item that failed, so trying again does not have to ask Steam about the item first.
    private var failedJobs: [String: Job] = [:]

    static func key(_ appID: Int, _ item: UInt64) -> String { "\(appID)/\(item)" }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.unfinishedKey), let saved = try? JSONDecoder().decode([String: Job].self, from: data) {
            unfinished = saved
            for (key, _) in saved { progress[key] = Progress(state: .queued) }
        }
    }

    private func saveUnfinished() {
        if let data = try? JSONEncoder().encode(unfinished) { UserDefaults.standard.set(data, forKey: Self.unfinishedKey) }
    }

    /// Call when the app opens (SteamStore.start): items left over from before, for example waiting for a game that has ended since, start again. A little later, so the
    /// sign-in and the screens come first.
    func resumeAfterLaunch() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            await repairAllCaches()
        }
        guard !unfinished.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let left = unfinished.values.filter { job in !queue.contains { $0.appID == job.appID && $0.item == job.item } }
            guard !left.isEmpty, !service.connectionHeld else { return }
            SteamLog.event("[workshop] \(left.count) unfinished item(s) from before start again")
            for job in left { progress[Self.key(job.appID, job.item)] = nil; enqueue(job) }
        }
    }

    /// The game ended (or the app opened with no game running): the items that waited for the connection are queued now.
    func gameEnded() {
        guard !service.connectionHeld, !deferred.isEmpty else { return }
        let waiting = deferred
        deferred = []
        SteamLog.event("[workshop] \(waiting.count) item(s) that waited for the game to close start now")
        for job in waiting { progress[Self.key(job.appID, job.item)] = nil; enqueue(job) }
    }

    /// Puts an item in the waiting list, to be started when the game ends.
    private func wait(_ job: Job) {
        let key = Self.key(job.appID, job.item)
        if !deferred.contains(where: { $0.appID == job.appID && $0.item == job.item }) { deferred.append(job) }
        progress[key] = Progress(state: .waiting)
        SteamLog.event("[workshop] item \(job.item) of app \(job.appID) waits for the game to close")
    }

    // MARK: Reading

    func browse(appID: Int, sort: SteamWorkshopSort, search: String, page: Int) async throws -> (items: [SteamWorkshopItem], total: Int) {
        try await service.workshopBrowse(appID: appID, sort: sort, search: search, page: page)
    }

    /// What the account is subscribed to for the game, newest subscription first. The manifest in Steam's list is the current one.
    func subscribed(appID: Int) async throws -> [SteamWorkshopItem] {
        let files = try await service.workshopSubscribed(appID: appID)
        guard !files.isEmpty else { return [] }
        let details = Dictionary(try await service.workshopItems(ids: files.map(\.id), appID: appID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return files.sorted { ($0.subscribed ?? .distantPast) > ($1.subscribed ?? .distantPast) }.map { file in
            var item = details[file.id] ?? SteamWorkshopItem(id: file.id, appID: appID, title: "Item \(file.id)", summary: "")
            if file.manifest != 0 { item.contentManifest = file.manifest }
            if item.updated == nil { item.updated = file.updated }
            if item.fileSize == 0 { item.fileSize = file.size }
            return item
        }
    }

    /// The items on this device for a game.
    func installed(appID: Int) async -> [UInt64: SteamWorkshopFiles.Installed] {
        (try? await withSteamApps(appID: appID, write: false) { SteamWorkshopFiles.installed(appID: appID, steamApps: $0) }) ?? [:]
    }

    /// The items on this device for a game, with their titles and pictures (Steam's public details; no connection to Steam's servers is needed, so it works while a game runs).
    func installedItems(appID: Int) async throws -> [SteamWorkshopItem] {
        let have = await installed(appID: appID)
        guard !have.isEmpty else { return [] }
        let found = Dictionary(try await service.workshopItems(ids: Array(have.keys), appID: appID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return have.keys.map { id -> SteamWorkshopItem in
            var item = found[id] ?? SteamWorkshopItem(id: id, appID: appID, title: "Item \(id)", summary: "")
            if item.updated == nil { item.updated = have[id]?.updated }
            return item
        }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    // MARK: Changing

    /// Subscribes the account to an item on Steam and downloads it.
    func subscribe(_ item: SteamWorkshopItem, gameName: String) async throws {
        try await service.workshopSubscribe(id: item.id, appID: item.appID, subscribe: true)
        enqueue(job(for: item, gameName: gameName))
    }

    /// Unsubscribes on Steam and deletes the item from this device.
    func unsubscribe(id: UInt64, appID: Int) async throws {
        try await service.workshopSubscribe(id: id, appID: appID, subscribe: false)
        queue.removeAll { $0.appID == appID && $0.item == id }
        deferred.removeAll { $0.appID == appID && $0.item == id }
        unfinished[Self.key(appID, id)] = nil
        progress[Self.key(appID, id)] = nil
        let account = service.accountNumber
        _ = try? await withSteamApps(appID: appID, write: true) { steamApps in
            SteamWorkshopFiles.remove(item: id, appID: appID, steamApps: steamApps, subscribedBy: account)
        }
        changes += 1
    }

    /// Whether anything for this game is still downloading, queued or waiting for the connection.
    func hasPending(appID: Int) -> Bool {
        progress.contains { $0.key.hasPrefix("\(appID)/") && { if case .failed = $0.value.state { return false }; return true }($0) }
    }

    /// Items waiting for the game to end (they download when the app is opened again).
    var waitingCount: Int { progress.values.filter { $0.state == .waiting }.count }

    /// Makes sure Valve's finished-download cache holds every single-file item installed here (see `SteamWorkshopFiles.seedReferenced`): the ones installed before that was done,
    /// and any the client removed. Needs Steam's public item details once for an item that is missing there (its creator); no connection to Steam's servers.
    func repairCache(appID: Int) async {
        let account = service.accountNumber
        guard account != "0" else { return }
        let have = await installed(appID: appID)
        let steamRoot = SteamStore.steamApps.deletingLastPathComponent()
        // Cheap test first: an item with a folder in the cache and recorded as a single-file item is done. (The cache folder is named by the item's UGC handle, which the record
        // keeps as the manifest.)
        let todo = have.values.filter {
            $0.manifest != 0 && ($0.ugcHandle == 0 || !FileManager.default.fileExists(atPath: SteamWorkshopFiles.referencedFolder(steamRoot: steamRoot, account: account, handle: $0.manifest).appendingPathComponent("data.vdf").path))
        }
        guard !todo.isEmpty, let details = try? await service.workshopItems(ids: todo.map(\.id), appID: appID) else { return }
        let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let steamApps = (try? await withSteamApps(appID: appID, write: true) { $0 }) ?? SteamStore.steamApps
        var filled = 0, marked = 0
        for entry in todo {
            guard let item = byID[entry.id], item.fileURL != nil else { continue }          // depot items are Steam's own business
            if entry.ugcHandle == 0 {
                var fixed = entry; fixed.ugcHandle = entry.manifest
                SteamWorkshopFiles.record(fixed, appID: appID, steamApps: steamApps, subscribedBy: account)
                marked += 1
            }
            guard let filename = item.filename, let creator = item.creator, !filename.contains("..") else { continue }
            let file = SteamWorkshopFiles.itemFolder(appID: appID, item: entry.id, steamApps: steamApps).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: file.path), !SteamWorkshopFiles.isSeeded(filename: filename, handle: entry.manifest, steamRoot: steamRoot, account: account) else { continue }
            let handle = entry.manifest, app = item.creatorApp ?? appID
            let ok = await Task.detached(priority: .utility) { SteamWorkshopFiles.seedReferenced(file: file, filename: filename, handle: handle, appID: app, creator: creator, steamRoot: steamRoot, account: account) }.value
            if ok { filled += 1 }
        }
        if filled > 0 || marked > 0 { SteamLog.event("[workshop] app \(appID): Valve's cache filled for \(filled) item(s), \(marked) recorded as single-file items") }
    }

    /// For every game that has Workshop items on this device (the account's records under steamapps/workshop).
    func repairAllCaches() async {
        let folder = SteamStore.steamApps.appendingPathComponent("workshop", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("appworkshop_") && name.hasSuffix(".acf") {
            if let id = Int(name.dropFirst("appworkshop_".count).dropLast(".acf".count)) { await repairCache(appID: id) }
        }
    }

    /// The subscribed items that are missing here or older than Steam's version.
    private func needed(_ items: [SteamWorkshopItem], have: [UInt64: SteamWorkshopFiles.Installed]) -> [SteamWorkshopItem] {
        items.filter { item in
            if let present = have[item.id], present.manifest == item.contentManifest || (item.contentManifest == 0 && item.fileURL != nil) { return false }
            return true
        }
    }

    /// Downloads whatever the account is subscribed to that is missing here or older than Steam's version. Returns how many items it queued.
    @discardableResult
    func sync(appID: Int, gameName: String) async throws -> Int {
        let items = try await subscribed(appID: appID)
        let todo = needed(items, have: await installed(appID: appID))
        for item in todo { enqueue(job(for: item, gameName: gameName)) }
        updates[appID] = 0
        return todo.count
    }

    /// Looks for Workshop updates for a game without opening its Workshop page: when `download` is set the missing and outdated items are queued, otherwise only counted
    /// (see `updates`). At most every 5 minutes per game, never while a game runs (Steam's connection is closed then), and quietly nothing if Steam can't be reached.
    func checkForUpdates(appID: Int, gameName: String, download: Bool) async {
        guard !service.connectionHeld, Date().timeIntervalSince(lastCheck[appID] ?? .distantPast) > 300 else { return }
        lastCheck[appID] = Date()
        await repairCache(appID: appID)
        guard let items = try? await subscribed(appID: appID), !items.isEmpty else { updates[appID] = 0; return }
        let todo = needed(items, have: await installed(appID: appID))
        SteamLog.event("[workshop] update check for app \(appID): \(todo.count) of \(items.count) subscribed items need a download" + (download ? " (downloading)" : ""))
        if download { for item in todo { enqueue(job(for: item, gameName: gameName)) }; updates[appID] = 0 } else { updates[appID] = todo.count }
    }

    func retry(appID: Int, item: UInt64, gameName: String, title: String) {
        let key = Self.key(appID, item)
        progress[key] = nil
        enqueue(failedJobs[key] ?? Job(appID: appID, gameName: gameName, item: item, title: title, manifest: 0, updated: nil, fileURL: nil, filename: nil, creator: nil, creatorApp: nil))
    }

    func dismiss(appID: Int, item: UInt64) { progress[Self.key(appID, item)] = nil }

    private func job(for item: SteamWorkshopItem, gameName: String) -> Job {
        Job(appID: item.appID, gameName: gameName, item: item.id, title: item.title, manifest: item.contentManifest, updated: item.updated, fileURL: item.fileURL, filename: item.filename,
            creator: item.creator, creatorApp: item.creatorApp)
    }

    // MARK: The queue

    private func enqueue(_ job: Job) {
        let key = Self.key(job.appID, job.item)
        guard !queue.contains(where: { $0.appID == job.appID && $0.item == job.item }), progress[key]?.state != .active, progress[key]?.state != .waiting else { return }
        queue.append(job)
        unfinished[key] = job
        progress[key] = Progress(state: .queued)
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let job = queue.removeFirst()
                await run(job)
            }
            running = false
        }
    }

    private func run(_ original: Job) async {
        var job = original
        let key = Self.key(job.appID, job.item)
        progress[key] = Progress(state: .active)
        do {
            if job.fileURL == nil {
                // Steam's public details say whether the item is a file at a web address (older items are) or in the game's Workshop depot; the lists do not always say.
                let found = try? await service.workshopItems(ids: [job.item], appID: job.appID).first
                if let found {
                    job.fileURL = found.fileURL; job.filename = found.filename; job.creator = found.creator; job.creatorApp = found.creatorApp
                    if job.manifest == 0 { job.manifest = found.contentManifest }
                    if job.updated == nil { job.updated = found.updated }
                    if job.title.isEmpty || job.title.hasPrefix("Item ") { job.title = found.title }
                } else if job.manifest == 0 {
                    throw SteamFailure(message: "Steam no longer lists this item.")
                }
            }
            guard job.manifest != 0 || job.fileURL != nil else { throw SteamFailure(message: "\u{201C}\(job.title)\u{201D} has no files to download.") }
            // Only an item stored in the game's Workshop depot needs the depot (and Steam's connection, which is closed while a game runs); a file at a web address does not.
            var depot = 0
            if job.fileURL == nil, job.manifest != 0 {
                // Already there at this version (Steam's own client may have fetched it while the game ran): nothing to do.
                if let present = await installed(appID: job.appID)[job.item], present.manifest == job.manifest {
                    progress[key] = nil; unfinished[key] = nil; changes += 1
                    SteamLog.event("[workshop] item \(job.item) of app \(job.appID) is already installed at this version")
                    return
                }
                if service.connectionHeld { wait(job); return }
                if let known = depots[job.appID] { depot = known } else { depot = try await service.workshopDepot(appID: job.appID); depots[job.appID] = depot }
            }
            try await withSteamApps(appID: job.appID, write: true) { steamApps in
                try FileManager.default.createDirectory(at: SteamWorkshopFiles.contentFolder(appID: job.appID, steamApps: steamApps), withIntermediateDirectories: true)
                // Items served from a web address (older ones, and plain files) are fetched from it; the others are in the game's Workshop depot.
                if job.fileURL == nil, job.manifest != 0 {
                    try await self.service.installWorkshopItem(appID: job.appID, name: job.title, depot: depot, item: job.item, manifest: job.manifest, updated: job.updated, steamApps: steamApps) { [weak self] p in
                        self?.progress[key]?.fraction = p.fraction
                    }
                } else if let url = job.fileURL {
                    try await self.service.installWorkshopFile(appID: job.appID, item: job.item, url: url, filename: job.filename, updated: job.updated, steamApps: steamApps,
                                                               content: job.manifest, creator: job.creator, creatorApp: job.creatorApp, steamRoot: SteamStore.steamApps.deletingLastPathComponent())
                }
            }
            progress[key] = nil
            unfinished[key] = nil
            failedJobs[key] = nil
            changes += 1; arrived += 1
            SteamLog.event("[workshop] installed item \(job.item) of app \(job.appID)")
        } catch {
            if error is CancellationError { progress[key] = nil; unfinished[key] = nil; return }
            // A game started while this item downloaded (or the connection closed before it began): it continues when the game ends.
            if job.fileURL == nil, job.manifest != 0, service.connectionHeld { wait(job); return }
            var text = (error as? SteamStorageError)?.localizedDescription ?? SteamSignIn.message(error)
            progress[key] = Progress(state: .failed(text))
            unfinished[key] = nil
            failedJobs[key] = job
            SteamLog.event("[workshop] failed item \(job.item): \(text) (file url \(job.fileURL == nil ? "no" : "yes"), manifest \(job.manifest))")
            SteamLog.event("[workshop] failed item \(job.item) of app \(job.appID): \(SteamSignIn.reason(error))")
        }
    }

    /// Runs `body` with the `steamapps` folder the game lives in (on the SSD when the game is there, holding the access for the whole operation).
    private func withSteamApps<T>(appID: Int, write: Bool, _ body: (URL) async throws -> T) async throws -> T {
        let libraryID = ExternalLibrary.shared.libraryID(for: appID)
        let access = try await ExternalLibrary.shared.accessForOperation(libraryID: libraryID, write: write)
        defer { access?.keepAlive() }
        let steamApps = try access.map { try SteamStoragePath.native("steamapps", root: $0.root) } ?? SteamStore.steamApps
        return try await body(steamApps)
    }
}
