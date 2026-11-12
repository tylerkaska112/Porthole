// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Downloads a game from Steam into the Wine prefix: asks Steam for the app's Windows depots, their keys and manifests, fetches
// every chunk from Steam's content servers, decrypts, unpacks and verifies it, writes the files, and finally records the game
// the way Steam does (steamapps/appmanifest_<id>.acf) so it shows up as installed. Resumes where it stopped.
import CommonCrypto
import Foundation

struct SteamDownloadProgress: Equatable {
    enum Phase: Equatable { case preparing, downloading, finishing }
    var phase = Phase.preparing
    var doneBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    var fraction: Double { totalBytes == 0 ? 0 : min(1, Double(doneBytes) / Double(totalBytes)) }
    var secondsLeft: Double? { bytesPerSecond > 1 ? Double(totalBytes - min(doneBytes, totalBytes)) / bytesPerSecond : nil }

    init() {}
    init(doneBytes: UInt64, totalBytes: UInt64, bytesPerSecond: Double) {
        phase = .downloading; self.doneBytes = doneBytes; self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond
    }
}

final class SteamInstaller {
    enum State: Equatable {
        case idle
        case preparing(String)
        case downloading(SteamDownloadProgress)
        case finished
        case failed(String)
        case cancelled

        var isFinal: Bool { switch self { case .finished, .failed, .cancelled: return true; default: return false } }
    }

    let appid: Int
    let name: String
    private(set) var state: State = .idle { didSet { if oldValue != state { onState?(state) } } }
    var onState: ((State) -> Void)?
    /// Tests can shrink these.
    var parallelChunks = 24
    /// The game is going onto an external drive: few chunks at once, written one at a time and in the order they were asked for, and files not extended to their full size up
    /// front. A cheap flash drive manages a few MB/s of sequential writing but only a fraction of that when dozens of writers jump between files, and extending a file on exFAT
    /// can write zeros for all of it first.
    var slowDisk: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _slowDisk }
        set { lock.lock(); _slowDisk = newValue; lock.unlock() }
    }
    private var _slowDisk = false
    /// The game is going onto an external drive. A drive that tested fast is written like the device; if its writes then turn out slow (a cheap SSD whose cache has
    /// filled, a drive that got hot) the download switches to the gentle way by itself.
    var external = false
    private let diskQueue = DispatchQueue(label: "steam.disk-writes", qos: .userInitiated)
    /// Tests turn this off to keep the number in flight fixed.
    var adaptive = true
    var retriesPerChunk = 4
    var freeSpaceOverride: (() -> Int64?)?

    /// The `steamapps` folder the game goes into (its `common` folder holds the files, `appmanifest_<id>.acf` records the install).
    private let steamApps: URL
    private let backend: SteamContentBackend
    private let fm: FileManager
    private var token = 0

    // Everything below is guarded by `lock` once downloading starts.
    private let lock = NSLock()
    private var cancelled = false
    private var failure: String?
    private var written: UInt64 = 0
    private var networkBytes: UInt64 = 0
    private var rejected = 0
    private var currentTarget = 0
    private var lastPerfLog = Date.distantPast
    private var samples: [(time: Date, bytes: UInt64)] = []
    private var pendingDone: [UInt32] = []
    private var descriptors: [Int: Int32] = [:]
    private var remaining: [Int: Int] = [:]
    private var progressTimer: Timer?
    private var total: UInt64 = 0
    /// For each install path (compared as Windows does), the index of the last depot that lists it. Valve's client keeps the copy from the depot mounted later, so that depot alone writes
    /// the file (from Madeira, PR 524: both copies written to one path made every repair flip the file between them).
    private var lastOwner: [String: Int] = [:]
    /// What the transfer is measured in for the person: the compressed bytes that cross the network (the same figure the Install button showed), not the bytes the files take on disk.
    /// `networkTotal` is every chunk's compressed size, `networkAlreadyDone` the part of it a resumed download had already fetched.
    private var networkTotal: UInt64 = 0
    private var networkAlreadyDone: UInt64 = 0

    private struct Item { var depot: Int; var file: Int; var chunk: Int; var global: UInt32 }
    private var manifests: [SteamManifest] = []
    private var keys: [Data] = []
    private var servers: [SteamCDNServer] = []
    private var hostBook = SteamHostBook(hosts: [])
    private var statChunks = 0, statNet = 0.0, statDecode = 0.0, statWrite = 0.0      // per-chunk time, summed between two log lines
    private var totalWriteSeconds = 0.0        // all the time chunks spent being written (never reset: `watchDisk` compares two readings)
    private(set) var gameFolder = URL(fileURLWithPath: "/")
    private var progressFolder = URL(fileURLWithPath: "/")
    private(set) var installInfo: SteamAppInfo?
    /// The account that owns the game, written into the install record the way Steam does.
    var ownerSteamID: String?
    /// Which version (branch) and which DLC to install. The default is the public branch with the game's own files.
    var selection = SteamInstallSelection()
    /// Set to download one Workshop item instead of a game: its files go to `steamapps/workshop/content/<app>/<item>` and the Workshop record is updated.
    var workshop: WorkshopTarget?
    struct WorkshopTarget: Equatable {
        var item: UInt64
        var depot: Int
        var manifest: UInt64
        /// When the item was last changed on Steam, written into the record.
        var updated: Date?
    }
    /// Depots the install record already lists at the manifest being installed: not fetched again, and kept in the record.
    private var keptDepots: [InstalledDepot] = []
    struct InstalledDepot: Equatable { var id: Int; var manifest: UInt64; var size: UInt64; var dlcApp: Int? }

    init(appid: Int, name: String, steamApps: URL, backend: SteamContentBackend, fileManager: FileManager = .default) {
        self.appid = appid; self.name = name; self.steamApps = steamApps; self.backend = backend; fm = fileManager
    }

    /// Where a download keeps what it has finished, so it can continue later.
    static func progressFolder(appID: Int, steamApps: URL) -> URL { steamApps.appendingPathComponent("downloading/\(appID)") }
    static func hasPartialDownload(appID: Int, steamApps: URL) -> Bool {
        let done = progressFolder(appID: appID, steamApps: steamApps).appendingPathComponent("done.bin")
        return ((try? done.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    // MARK: Start and stop

    func start() {
        guard state == .idle || state.isFinal else { return }
        token += 1
        lock.lock(); cancelled = false; failure = nil; written = 0; networkBytes = 0; networkTotal = 0; networkAlreadyDone = 0; rejected = 0; lastPerfLog = Date(); samples = []; pendingDone = []; descriptors = [:]; remaining = [:]; lock.unlock()
        state = .preparing("Asking Steam about \(name)…")
        if let workshop {
            SteamLog.event("Steam download: starting Workshop item \(workshop.item) of app \(appid).")
            prepareWorkshop(token, workshop)
            return
        }
        SteamLog.event("Steam download: starting app \(appid).")
        prepare(token)
    }

    func cancel() {
        guard !state.isFinal else { return }
        lock.lock(); cancelled = true; lock.unlock()
        token += 1
        progressTimer?.invalidate(); progressTimer = nil
        closeAll(); flushProgress()
        backend.close()
        state = .cancelled
        SteamLog.event("Steam download: cancelled (what was downloaded is kept, so it can resume).")
    }

    private func fail(_ message: String, _ id: Int) {
        guard id == token, !state.isFinal else { return }
        progressTimer?.invalidate(); progressTimer = nil
        lock.lock(); cancelled = true; lock.unlock()
        closeAll(); flushProgress()
        backend.close()
        SteamLog.event("Steam download failed: \(message)")
        state = .failed(message)
    }

    // MARK: Preparing: app info, keys, manifests

    private func prepare(_ id: Int) {
        backend.appInfo(appid) { [weak self] result in
            guard let self, id == self.token else { return }
            switch result {
            case .failure(let error): self.fail(error.notOwned ? "Steam does not list \(self.name) for this account." : error.message, id)
            case .success(var info):
                // The build number the record states is the chosen branch's, so Valve's client and the update check agree with what was installed.
                if self.selection.branch != SteamBranch.publicName {
                    guard let branch = info.branches.first(where: { $0.name == self.selection.branch }) else {
                        self.fail("Steam does not list a version called \u{201C}\(self.selection.branch)\u{201D} of \(self.name).", id); return
                    }
                    if let build = branch.buildID { info.buildID = build }
                }
                self.installInfo = info
                let depots = SteamDepotPlanner.windowsDepots(app: info, selection: self.selection)
                guard !depots.isEmpty else {
                    let needsKey = self.selection.branch != SteamBranch.publicName && self.selection.branchKey == nil && info.depots.contains { $0.encryptedManifests[self.selection.branch] != nil }
                    self.fail(needsKey ? "The \u{201C}\(self.selection.branch)\u{201D} version of \(self.name) needs its password." : self.selection.branch == SteamBranch.publicName
                              ? "\(self.name) has no Windows version on Steam." : "The \u{201C}\(self.selection.branch)\u{201D} version of \(self.name) has no Windows files.", id); return
                }
                self.resolveManifests(depots, info: info, id)
            }
        }
    }

    private func prepareWorkshop(_ id: Int, _ target: WorkshopTarget) {
        installInfo = SteamAppInfo(appid: appid, name: name, installDirectory: nil, buildID: nil, depots: [])
        let job = SteamDepotJob(depot: SteamDepot(id: target.depot, manifest: target.manifest), manifest: target.manifest, keyApp: appid)
        fetchManifests([job], id)
    }

    private func resolveManifests(_ depots: [SteamDepot], info: SteamAppInfo, _ id: Int) {
        var jobs: [SteamDepotJob] = []
        var borrowed: [Int: SteamAppInfo] = [:]
        func next(_ index: Int) {
            guard id == token else { return }
            if index >= depots.count { fetchManifests(jobs, id); return }
            let depot = depots[index]
            if let manifest = depot.manifest { jobs.append(SteamDepotJob(depot: depot, manifest: manifest, keyApp: depot.fromApp ?? appid)); next(index + 1); return }
            guard let source = depot.fromApp else { next(index + 1); return }
            func use(_ other: SteamAppInfo) {
                // The same branch of the other app, else its public one.
                if let theirs = other.depots.first(where: { $0.id == depot.id }),
                   let entry = SteamDepotPlanner.manifestEntry(of: theirs, selection: self.selection) ?? SteamDepotPlanner.publicEntry(of: theirs) {
                    var resolved = depot; resolved.manifest = entry.gid
                    jobs.append(SteamDepotJob(depot: resolved, manifest: entry.gid, keyApp: source))
                }
                next(index + 1)
            }
            if let other = borrowed[source] { use(other); return }
            backend.appInfo(source) { [weak self] result in
                guard let self, id == self.token else { return }
                if case .success(let other) = result { borrowed[source] = other; use(other) } else { next(index + 1) }
            }
        }
        state = .preparing("Reading the list of files…")
        next(0)
    }

    private func fetchManifests(_ allJobs: [SteamDepotJob], _ id: Int) {
        guard !allJobs.isEmpty else { fail("Steam gave no files to download for \(name).", id); return }
        // A depot the install record already lists at this very manifest is on the disk already: it is neither fetched nor lost from the record.
        let previous = (workshop != nil || selection.verify) ? [:] : Self.installedDepots(appid: appid, steamApps: steamApps, fileManager: fm)
        let dlcByDepot = Dictionary(installInfo?.depots.map { ($0.id, $0.dlcApp) } ?? [], uniquingKeysWith: { a, _ in a })
        keptDepots = allJobs.compactMap { job in
            guard let had = previous[job.depot.id], had.manifest == job.manifest else { return nil }
            return InstalledDepot(id: job.depot.id, manifest: had.manifest, size: had.size, dlcApp: (dlcByDepot[job.depot.id] ?? nil) ?? had.dlcApp)
        }
        let jobs = allJobs.filter { job in !keptDepots.contains { $0.id == job.depot.id } }
        if !keptDepots.isEmpty { SteamLog.event("Steam download: \(keptDepots.count) depot(s) already installed at the right version: \(keptDepots.map { String($0.id) }.joined(separator: ", ")).") }
        if jobs.isEmpty {
            // Nothing to fetch (a version that only changes the record, or DLC that is already there).
            guard let info = installInfo else { return }
            gameFolder = steamApps.appendingPathComponent("common/" + SteamDepotPlanner.safeInstallDirectory(info))
            writeAppManifest(info)
            backend.close()
            SteamLog.event("Steam download: \(name) is up to date.")
            state = .finished
            return
        }
        backend.servers { [weak self] found in
            guard let self, id == self.token else { return }
            guard !found.isEmpty else { self.fail("Steam's content servers could not be reached. Check the internet connection.", id); return }
            self.servers = found
            self.hostBook = SteamHostBook(hosts: found)
            SteamLog.event("[steam-perf] \(found.count) content servers: " + found.prefix(6).map { "\($0.host.replacingOccurrences(of: ".steamcontent.com", with: "")) load \($0.load)" }.joined(separator: ", "))
            var loaded: [SteamManifest] = [], loadedKeys: [Data] = []
            var skipped: [String] = []
            func next(_ index: Int) {
                guard id == self.token else { return }
                if index >= jobs.count {
                    guard !loaded.isEmpty else { self.fail(skipped.first ?? "No depot of \(self.name) could be downloaded.", id); return }
                    if !skipped.isEmpty { SteamLog.event("Steam download: \(skipped.count) depot(s) were left out (\(skipped.joined(separator: " "))); the game may be incomplete if one of them was needed.") }
                    self.manifests = loaded; self.keys = loadedKeys
                    self.beginTransfer(id); return
                }
                let job = jobs[index]
                self.state = .preparing("Getting the file list (\(index + 1) of \(jobs.count))…")
                self.backend.depotKey(app: job.keyApp, depot: job.depot.id) { key in
                    guard id == self.token else { return }
                    switch key {
                    case .failure(let error):
                        if error.notOwned || error.blocked { skipped.append(error.message); SteamLog.event("Steam download: skipping depot \(job.depot.id): \(error.message)"); next(index + 1) }
                        else { self.fail(error.message, id) }
                    case .success(let depotKey):
                        self.backend.manifestCode(app: job.keyApp, depot: job.depot.id, manifest: job.manifest) { code in
                            guard id == self.token else { return }
                            switch code {
                            case .failure(let error): self.fail(error.message, id)
                            case .success(let requestCode):
                                self.downloadManifest(job, code: requestCode, key: depotKey, attempt: 0, id) { result in
                                    switch result {
                                    case .failure(let message): self.fail(message.description, id)
                                    case .success(let manifest): loaded.append(manifest); loadedKeys.append(depotKey); next(index + 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            next(0)
        }
    }

    private func downloadManifest(_ job: SteamDepotJob, code: UInt64, key: Data, attempt: Int, _ id: Int, completion: @escaping (Result<SteamManifest, ManifestFailure>) -> Void) {
        guard attempt < min(servers.count, 4), let url = SteamCDN.manifestURL(servers[attempt % servers.count], depot: job.depot.id, manifest: job.manifest, code: code) else {
            completion(.failure(ManifestFailure("The file list for \(name) could not be downloaded from Steam's servers."))); return
        }
        backend.fetch(url) { [weak self] result in
            guard let self, id == self.token else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    if let manifest = try? SteamManifest.parse(zipped: data, depotKey: key) { completion(.success(manifest)) }
                    else { completion(.failure(ManifestFailure("Steam's file list for \(self.name) could not be read."))) }
                case .failure: self.downloadManifest(job, code: code, key: key, attempt: attempt + 1, id, completion: completion)
                }
            }
        }
    }
    struct ManifestFailure: Error, ExpressibleByStringLiteral, CustomStringConvertible {
        var description: String
        init(_ text: String) { description = text }
        init(stringLiteral value: String) { description = value }
    }

    // MARK: Transfer

    private func beginTransfer(_ id: Int) {
        guard let info = installInfo else { return }
        let installDirectory = SteamDepotPlanner.safeInstallDirectory(info)
        if let workshop {
            gameFolder = SteamWorkshopFiles.itemFolder(appID: appid, item: workshop.item, steamApps: steamApps)
            progressFolder = steamApps.appendingPathComponent("downloading/workshop_\(appid)_\(workshop.item)")
        } else {
            gameFolder = steamApps.appendingPathComponent("common/" + installDirectory)
            progressFolder = Self.progressFolder(appID: appid, steamApps: steamApps)
        }
        // What will actually be written: no folders, no links, and not Steam's redistributable installers.
        lastOwner = [:]
        for (depotIndex, manifest) in manifests.enumerated() {
            for file in manifest.files where Self.isWanted(file) { lastOwner[Self.overlapKey(file.path)] = depotIndex }
        }
        total = manifests.enumerated().reduce(0) { sum, entry in
            sum + entry.element.files.reduce(0) { $0 + (Self.isWanted($1) && lastOwner[Self.overlapKey($1.path)] == entry.offset ? $1.size : 0) }
        }

        // Room for it? Keep half a gigabyte free for the system.
        let need = Int64(total) + 512 << 20
        if let free = freeSpaceOverride?() ?? Self.freeSpace(at: steamApps), free < need {
            fail("There is not enough space on this device: \(name) needs \(Self.size(Int64(total))) and \(Self.size(max(0, free))) is free.", id); return
        }
        // An update of a Workshop item replaces its files: what an older version had and this one does not must not stay behind.
        if workshop != nil {
            let samePlan = (try? String(contentsOf: progressFolder.appendingPathComponent("plan.txt"), encoding: .utf8)) == manifests.map { "\($0.depotID):\($0.manifestID)" }.joined(separator: ",")
            if !samePlan { try? fm.removeItem(at: gameFolder) }
        }
        do {
            try fm.createDirectory(at: gameFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: progressFolder, withIntermediateDirectories: true)
        } catch { fail("The game's folder could not be created (\(error.localizedDescription)).", id); return }

        // Resume only when the same manifests are being fetched.
        let plan = manifests.map { "\($0.depotID):\($0.manifestID)" }.joined(separator: ",")
        let planFile = progressFolder.appendingPathComponent("plan.txt"), doneFile = progressFolder.appendingPathComponent("done.bin")
        var done = Set<UInt32>()
        if (try? String(contentsOf: planFile, encoding: .utf8)) == plan, let data = try? Data(contentsOf: doneFile) {
            let bytes = Array(data)
            var at = 0
            while at + 4 <= bytes.count { done.insert(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24); at += 4 }
            SteamLog.event("Steam download: resuming, \(done.count) chunk(s) already on disk.")
        } else {
            try? fm.removeItem(at: doneFile)
            try? plan.write(to: planFile, atomically: true, encoding: .utf8)
        }

        // Chunks whose bytes are already in the files on the disk are not fetched again: an update of an installed game (most of a depot is unchanged), a repair, a download that lost
        // its list of finished chunks. The file regions are hashed off the main thread and compared with the manifest.
        state = .preparing("Checking the files already on the device\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let began = Date()
            let found = self.reusableChunks(skipping: done, id: id)
            DispatchQueue.main.async { [weak self] in
                guard let self, id == self.token, !self.state.isFinal else { return }
                if found.files > 0 {
                    SteamLog.event("Steam download: \(self.name): \(found.done.count) chunk(s) (\(Self.size(Int64(found.bytes)))) in \(found.files) file(s) on the device already match Steam's, checked in \(String(format: "%.0f", Date().timeIntervalSince(began))) s.")
                }
                self.layOutAndTransfer(id, done: done.union(found.done))
            }
        }
    }

    /// Hashes the regions of the files already on the disk that the manifests describe, and returns the chunks whose bytes are right (those in `skipping` are not looked at).
    private func reusableChunks(skipping done: Set<UInt32>, id: Int) -> (done: Set<UInt32>, files: Int, bytes: UInt64) {
        struct Job { var path: String; var file: SteamManifestFile; var first: UInt32 }
        var jobs: [Job] = []
        var candidates: [Job] = []
        var global: UInt32 = 0
        var totalBytes: UInt64 = 0
        for (depotIndex, manifest) in manifests.enumerated() {
            for file in manifest.files {
                // The same numbering as the layout: directories count nothing, links, redistributables and files a later depot overrides count their chunks, empty files nothing.
                if Self.isRedistributable(file.path) || file.isSymlink { global += UInt32(file.chunks.count); continue }
                if file.isDirectory { continue }
                if lastOwner[Self.overlapKey(file.path)] != depotIndex { global += UInt32(file.chunks.count); continue }
                if file.chunks.isEmpty || file.size == 0 { continue }
                candidates.append(Job(path: gameFolder.appendingPathComponent(file.path).path, file: file, first: global))
                global += UInt32(file.chunks.count)
            }
        }
        // Which of them already exist: one stat per file, all at once (on a drive each is a round trip, and a game has thousands of files).
        var sizes = [Int64](repeating: 0, count: candidates.count)
        sizes.withUnsafeMutableBufferPointer { sizesBuffer in
            let output = sizesBuffer
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                var info = stat()
                if stat(candidates[i].path, &info) == 0 { output[i] = Int64(info.st_size) }
            }
        }
        for (i, candidate) in candidates.enumerated() where sizes[i] > 0 { jobs.append(candidate); totalBytes += UInt64(sizes[i]) }
        guard !jobs.isEmpty else { return ([], 0, 0) }
        let merge = NSLock()
        var found = Set<UInt32>(), files = 0, bytes: UInt64 = 0, checkedBytes: UInt64 = 0, lastShown = -1
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            self.lock.lock(); let stop = self.cancelled || self.failure != nil || id != self.token; self.lock.unlock()
            if stop { return }
            let job = jobs[index]
            var info = stat()
            guard stat(job.path, &info) == 0, info.st_size > 0 else { return }
            let size = UInt64(info.st_size)
            let fd = open(job.path, O_RDONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var local: [UInt32] = []
            var localBytes: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            for (i, chunk) in job.file.chunks.enumerated() {
                let g = job.first + UInt32(i)
                if done.contains(g) { continue }
                let length = chunk.originalSize
                guard length > 0, chunk.offset + UInt64(length) <= size else { continue }
                if buffer.count < length { buffer = [UInt8](repeating: 0, count: length) }
                let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(chunk.offset)) }
                guard got == length else { continue }
                buffer.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(length), &digest) }
                if digest.elementsEqual(chunk.sha) { local.append(g); localBytes += UInt64(length) }
            }
            merge.lock()
            if !local.isEmpty { found.formUnion(local); files += 1; bytes += localBytes }
            checkedBytes += size
            let percent = totalBytes > 0 ? Int(Double(checkedBytes) / Double(totalBytes) * 100) : 100
            let show = percent != lastShown
            if show { lastShown = percent }
            merge.unlock()
            if show { DispatchQueue.main.async { [weak self] in if let self, id == self.token, case .preparing = self.state { self.state = .preparing("Checking the files already on the device\u{2026} \(percent)%") } } }
        }
        return (found, files, bytes)
    }

    private struct Layout { var items: [Item]; var remaining: [Int: Int]; var doneBytes: UInt64; var netTotal: UInt64; var netDone: UInt64; var overridden: Int }

    /// Creating every folder and empty file of a game takes a long time on a slow drive (thousands of small operations), so it is done off the main thread.
    private func layOutAndTransfer(_ id: Int, done: Set<UInt32>) {
        state = .preparing("Creating the game's folders\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let layout = self.layOut(done: done)
            DispatchQueue.main.async { [weak self] in
                guard let self, id == self.token, !self.state.isFinal else { return }
                self.startTransfer(id, layout)
            }
        }
    }

    /// Lays out the folders and empty files, and the list of chunks still to fetch. Touches no state the main thread uses.
    private func layOut(done: Set<UInt32>) -> Layout {
        var items: [Item] = []
        var global: UInt32 = 0
        var doneBytes: UInt64 = 0
        var netTotal: UInt64 = 0, netDone: UInt64 = 0
        var remainingLocal: [Int: Int] = [:]
        var overridden = 0
        // One folder is made once, not once per file in it: on a drive each call is a round trip, and a game has hundreds of files in a few dozen folders.
        var madeFolders = Set<String>()
        var folderCalls = 0, fileCount = 0
        let began = Date()
        func ensureFolder(_ url: URL) {
            guard madeFolders.insert(url.path).inserted else { return }
            folderCalls += 1
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer {
            SteamLog.event("[steam-depot] laid out \(fileCount) file(s) in \(folderCalls) folder(s) in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        }
        for (depotIndex, manifest) in manifests.enumerated() {
            for (fileIndex, file) in manifest.files.enumerated() {
                if Self.isRedistributable(file.path) { global += UInt32(file.chunks.count); continue }
                let target = gameFolder.appendingPathComponent(file.path)
                if file.isDirectory { ensureFolder(target); continue }
                if file.isSymlink { global += UInt32(file.chunks.count); continue }
                if lastOwner[Self.overlapKey(file.path)] != depotIndex { global += UInt32(file.chunks.count); overridden += 1; continue }
                fileCount += 1
                // A file with data gets its folder when its first chunk is written (see `write`): on a slow drive every folder call is a round trip, and Preparing used to make all of them
                // before anything was downloaded. Only an empty file, which is made right here, needs its folder now.
                if file.chunks.isEmpty || file.size == 0 {
                    ensureFolder(target.deletingLastPathComponent())
                    if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
                    continue
                }
                var left = 0
                for (chunkIndex, chunk) in file.chunks.enumerated() {
                    netTotal += UInt64(chunk.compressedSize)
                    if done.contains(global) { doneBytes += UInt64(chunk.originalSize); netDone += UInt64(chunk.compressedSize) }
                    else { items.append(Item(depot: depotIndex, file: fileIndex, chunk: chunkIndex, global: global)); left += 1 }
                    global += 1
                }
                if left > 0 { remainingLocal[fileKey(depotIndex, fileIndex)] = left }
                else {
                    // Every chunk was already right: the file only needs the new length (an older version may have been longer or shorter).
                    var info = stat()
                    if stat(target.path, &info) == 0, UInt64(info.st_size) != file.size { _ = truncate(target.path, off_t(file.size)) }
                }
            }
        }
        return Layout(items: items, remaining: remainingLocal, doneBytes: doneBytes, netTotal: netTotal, netDone: netDone, overridden: overridden)
    }

    private func startTransfer(_ id: Int, _ layout: Layout) {
        let items = layout.items, doneBytes = layout.doneBytes, netTotal = layout.netTotal, netDone = layout.netDone, overridden = layout.overridden
        remaining = layout.remaining
        lock.lock(); written = doneBytes; networkTotal = netTotal; networkAlreadyDone = netDone; lock.unlock()
        if overridden > 0 { SteamLog.event("[steam-depot] overlap files=\(overridden) (a later depot's copy is installed, as Valve's client does)") }
        SteamLog.event("Steam download: \(items.count) chunk(s) to fetch, \(Self.size(Int64(netTotal))) to download (\(Self.size(Int64(total))) on disk).")
        state = .downloading(netTotal > 0 ? SteamDownloadProgress(doneBytes: netDone, totalBytes: netTotal, bytesPerSecond: 0) : SteamDownloadProgress(doneBytes: doneBytes, totalBytes: total, bytesPerSecond: 0))
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }

        // How many chunks are in flight adapts to what the connection can carry (see ConcurrencyController).
        let gentleChunks = 4
        let fixed = slowDisk ? gentleChunks : parallelChunks
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var controller = ConcurrencyController(start: max(1, fixed), floor: max(1, min(fixed, 8)), ceiling: self.adaptive ? 96 : max(1, fixed))
            var watch = DiskWatch()
            let gate = NSCondition()
            var inFlight = 0
            for item in items {
                gate.lock()
                var stopped = false
                while true {
                    self.lock.lock(); stopped = self.cancelled || self.failure != nil; let bytes = self.networkBytes; self.lock.unlock()
                    if stopped { break }
                    if self.adaptive { controller.observe(totalBytes: bytes, now: Date()) }
                    if self.external && !self.slowDisk { self.watchDisk(&watch) }
                    let limit = self.slowDisk ? min(controller.target, gentleChunks) : controller.target
                    self.lock.lock(); self.currentTarget = limit; self.lock.unlock()
                    if inFlight < limit { break }
                    gate.wait(until: Date().addingTimeInterval(0.5))
                }
                if stopped { gate.unlock(); break }
                inFlight += 1
                gate.unlock()
                self.fetchChunk(item, attempt: 0) { gate.lock(); inFlight -= 1; gate.signal(); gate.unlock() }
            }
            gate.lock()
            while inFlight > 0 { gate.wait(until: Date().addingTimeInterval(0.5)) }
            gate.unlock()
            DispatchQueue.main.async { [weak self] in self?.transferEnded(id) }
        }
    }

    /// Steam's own runtime installers (DirectX, Visual C++, .NET ...) sit in `_CommonRedist`. They are big, and they are for Windows itself, not for Wine.
    static func isRedistributable(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.caseInsensitiveCompare("_CommonRedist") == .orderedSame }
    }
    private static func isWanted(_ file: SteamManifestFile) -> Bool { !file.isDirectory && !file.isSymlink && !isRedistributable(file.path) }
    /// One install path, compared as Windows compares names: any case, either slash.
    private static func overlapKey(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/").lowercased() }

    private func fileKey(_ depot: Int, _ file: Int) -> Int { depot << 32 | file }

    private func fetchChunk(_ item: Item, attempt: Int, finished: @escaping () -> Void) {
        lock.lock(); let stop = cancelled || failure != nil; lock.unlock()
        if stop { finished(); return }
        let manifest = manifests[item.depot]
        let chunk = manifest.files[item.file].chunks[item.chunk]
        let book = hostBook
        guard let server = book.choose(), let url = SteamCDN.chunkURL(server, depot: manifest.depotID, sha: chunk.sha) else {
            setFailure("Steam's content servers could not be reached."); finished(); return
        }
        let began = Date()
        backend.fetch(url) { [weak self] result in
            let netSeconds = Date().timeIntervalSince(began)
            guard let self else { finished(); return }
            DispatchQueue.global(qos: .userInitiated).async {
                switch result {
                case .success(let data):
                    book.finished(host: server.host, bytes: data.count, seconds: netSeconds, ok: true)
                    self.lock.lock(); self.networkBytes += UInt64(data.count); self.lock.unlock()
                    let decodeStart = Date()
                    let plain = SteamCipher.unpackChunk(data, key: self.keys[item.depot], originalSize: chunk.originalSize)
                    let verified = plain != nil && plain!.count == chunk.originalSize && SteamCipher.sha1(plain!) == chunk.sha
                    let writeStart = Date()
                    if let plain, verified, self.writeInOrder(plain, item: item, network: UInt64(data.count)) {
                        self.lock.lock()
                        self.statChunks += 1; self.statNet += netSeconds; self.statDecode += writeStart.timeIntervalSince(decodeStart); self.statWrite += Date().timeIntervalSince(writeStart); self.totalWriteSeconds += Date().timeIntervalSince(writeStart)
                        self.lock.unlock()
                        finished(); return
                    }
                    // Say which check failed (no content of the game is logged, only sizes and the first bytes of the packed chunk).
                    let why = plain == nil ? "could not be unpacked" : plain!.count != chunk.originalSize ? "unpacked to \(plain!.count) bytes, expected \(chunk.originalSize)" : plain == nil || SteamCipher.sha1(plain!) != chunk.sha ? "its hash differs" : "could not be written"
                    SteamLog.event("[steam-depot] chunk rejected: depot=\(manifest.depotID) packed=\(data.count) \(why)")
                    self.lock.lock(); self.rejected += 1; self.lock.unlock()
                    self.retry(item, attempt: attempt, reason: "a chunk did not check out", finished: finished)
                case .failure(let error):
                    book.finished(host: server.host, bytes: 0, seconds: netSeconds, ok: false)
                    if error.notOwned { self.setFailure("Steam refused the download (\(error.message)). Try signing in for downloads again."); finished(); return }
                    self.retry(item, attempt: attempt, reason: error.message, finished: finished)
                }
            }
        }
    }

    private func retry(_ item: Item, attempt: Int, reason: String, finished: @escaping () -> Void) {
        if attempt + 1 >= retriesPerChunk {
            setFailure("Downloading \(name) stopped: \(reason) (after \(retriesPerChunk) tries). The download can be resumed."); finished(); return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4 * Double(attempt + 1)) { [weak self] in self?.fetchChunk(item, attempt: attempt + 1, finished: finished) ?? finished() }
    }

    private func setFailure(_ message: String) { lock.lock(); if failure == nil { failure = message }; lock.unlock() }

    /// What `watchDisk` remembers between looks: the counters at the start of the window.
    struct DiskWatch { var began: Date?; var written: UInt64 = 0; var writeSeconds = 0.0 }

    /// Backpressure from the drive itself. Every 8 seconds: if the chunks written in that time took more than one writer's whole time between them (the downloads are
    /// waiting on the drive, not on the network) and the drive took less than the gentle limit, the rest of this download is written gently.
    private func watchDisk(_ watch: inout DiskWatch) {
        let now = Date()
        lock.lock(); let doneBytes = written; let writeTime = totalWriteSeconds; lock.unlock()
        guard let began = watch.began else { watch = DiskWatch(began: now, written: doneBytes, writeSeconds: writeTime); return }
        let elapsed = now.timeIntervalSince(began)
        guard elapsed >= 8 else { return }
        let mbps = Double(doneBytes &- watch.written) / elapsed / 1_048_576
        let busy = (writeTime - watch.writeSeconds) / elapsed
        watch = DiskWatch(began: now, written: doneBytes, writeSeconds: writeTime)
        if busy > 1.0 && mbps < DriveWriteMode.gentleBelowMBps {
            slowDisk = true
            SteamLog.event(String(format: "[steam-depot] the drive takes %.1f MB/s with the writers waiting on it (%.1f writers' time): writing gently from here", mbps, busy))
        }
    }

    /// On an external drive the writes go through one queue, so only one is happening at a time (the chunks wait in memory: at most as many as are in flight, four).
    private func writeInOrder(_ plain: Data, item: Item, network: UInt64) -> Bool {
        slowDisk ? diskQueue.sync { write(plain, item: item, network: network) } : write(plain, item: item, network: network)
    }

    /// Put a chunk at its place in its file. Returns false if the disk write failed.
    private func write(_ plain: Data, item: Item, network: UInt64) -> Bool {
        let manifest = manifests[item.depot]
        let file = manifest.files[item.file]
        let chunk = file.chunks[item.chunk]
        let key = fileKey(item.depot, item.file)
        lock.lock()
        var descriptor = descriptors[key]
        lock.unlock()
        if descriptor == nil {
            // Opening a file and giving it its full size can take seconds on a drive (a thumb drive may write zeros to extend it), and `lock` is the one the main thread's
            // progress tick takes: it must not be held meanwhile, or the whole app waits for the drive. `openLock` only keeps two chunks of one file from opening it twice.
            openLock.lock()
            lock.lock(); descriptor = descriptors[key]; lock.unlock()
            if descriptor == nil {
                let path = gameFolder.appendingPathComponent(file.path).path
                var opened = open(path, O_RDWR | O_CREAT, 0o644)
                if opened < 0, errno == ENOENT {
                    // The folder is not there yet (folders are made when their first file is written, not while Preparing): make it, with its parents, and open again.
                    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    opened = open(path, O_RDWR | O_CREAT, 0o644)
                }
                if opened >= 0 {
                    if !slowDisk, fstat_size(opened) != Int64(file.size) { _ = ftruncate(opened, off_t(file.size)) }
                    lock.lock(); descriptors[key] = opened; lock.unlock()
                    descriptor = opened
                }
            }
            openLock.unlock()
        }
        guard let fd = descriptor else { setFailure("A file of the game could not be written."); return false }
        let count = plain.withUnsafeBytes { pwrite(fd, $0.baseAddress, plain.count, off_t(chunk.offset)) }
        guard count == plain.count else { setFailure("The disk write failed. The device may be out of space."); return false }
        lock.lock()
        written += UInt64(plain.count)
        pendingDone.append(item.global)
        let left = (remaining[key] ?? 1) - 1
        remaining[key] = left
        let finished = left <= 0 ? descriptors.removeValue(forKey: key) : nil
        lock.unlock()
        if let finished {
            // A file that was not sized up front gets its length now (it only differs when the manifest says the file ends in a gap no chunk covers).
            if slowDisk, fstat_size(finished) != Int64(file.size) { _ = ftruncate(finished, off_t(file.size)) }
            close(finished)     // closing a finished file can wait for the drive to flush it: not under the lock
        }
        return true
    }

    private let openLock = NSLock()

    private func fstat_size(_ fd: Int32) -> Int64 { var info = stat(); return fstat(fd, &info) == 0 ? Int64(info.st_size) : -1 }

    private func closeAll() {
        lock.lock(); let all = descriptors.values; descriptors = [:]; lock.unlock()
        for fd in all { close(fd) }
    }

    /// Chunks that are done are remembered on disk, so an interrupted download continues instead of starting over.
    /// One queue for the list of finished chunks, so its writes keep their order and the main thread never waits for a busy drive (an SSD or a thumb drive with dozens of chunk writes
    /// in flight can take seconds to answer a small append, and this is called from the progress tick on the main thread).
    private let progressQueue = DispatchQueue(label: "steam.progress-file", qos: .utility)

    /// `wait`: pause, cancel and the end of the download need the list complete on disk before they go on; the progress tick does not.
    private func flushProgress(wait: Bool = true) {
        lock.lock(); let batch = pendingDone; pendingDone = []; lock.unlock()
        guard !batch.isEmpty else { return }
        var data = Data(capacity: batch.count * 4)
        for value in batch { for i in 0..<4 { data.append(UInt8((value >> (8 * UInt32(i))) & 0xFF)) } }
        let file = progressFolder.appendingPathComponent("done.bin")
        let write = {
            if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() } else { try? data.write(to: file) }
        }
        if wait { progressQueue.sync(execute: write) } else { progressQueue.async(execute: write) }
    }

    private func tick() {
        guard case .downloading = state else { return }
        flushProgress(wait: false)
        lock.lock()
        let now = Date()
        samples.append((now, networkBytes)); samples.removeAll { now.timeIntervalSince($0.time) > 4 }
        let speed: Double = samples.count >= 2 ? Double(networkBytes - samples[0].bytes) / max(0.5, now.timeIntervalSince(samples[0].time)) : 0
        let done = written
        let netTotal = networkTotal, netDone = min(networkTotal, networkAlreadyDone + networkBytes)
        let target = currentTarget, refused = rejected
        let logNow = now.timeIntervalSince(lastPerfLog) >= 10
        var times = (chunks: 0, net: 0.0, decode: 0.0, write: 0.0)
        if logNow { lastPerfLog = now; times = (statChunks, statNet, statDecode, statWrite); statChunks = 0; statNet = 0; statDecode = 0; statWrite = 0 }
        lock.unlock()
        if logNow {
            let n = Double(max(times.chunks, 1))
            SteamLog.event(String(format: "[steam-perf] network %.1f MB/s, written %.0f of %.0f MB, in flight %d, rejected chunks %d | per chunk: fetch %.0f ms, unpack %.0f ms, write %.0f ms (n=%d) | %@",
                                  speed / 1_048_576, Double(done) / 1_048_576, Double(total) / 1_048_576, target, refused,
                                  times.net / n * 1000, times.decode / n * 1000, times.write / n * 1000, times.chunks, hostBook.summary()))
        }
        // The bar, "x of y" and the time left all use network bytes, the unit the speed is measured in (the disk size is 2 to 3 times larger for most games, which made the time left too long).
        state = .downloading(netTotal > 0 ? SteamDownloadProgress(doneBytes: netDone, totalBytes: netTotal, bytesPerSecond: speed) : SteamDownloadProgress(doneBytes: done, totalBytes: total, bytesPerSecond: speed))
    }

    private func transferEnded(_ id: Int) {
        guard id == token, !state.isFinal else { return }
        progressTimer?.invalidate(); progressTimer = nil
        closeAll(); flushProgress()
        lock.lock(); let problem = failure; let stopped = cancelled; lock.unlock()
        if stopped && problem == nil { return }
        if let problem { fail(problem, id); return }
        guard let info = installInfo else { return }
        if let workshop {
            let account = ownerSteamID.flatMap { UInt64($0) }.map { String($0 & 0xFFFFFFFF) } ?? "0"
            SteamWorkshopFiles.record(SteamWorkshopFiles.Installed(id: workshop.item, size: total, manifest: workshop.manifest, updated: workshop.updated),
                                      appID: appid, steamApps: steamApps, subscribedBy: account)
        } else {
            writeAppManifest(info)
        }
        try? fm.removeItem(at: progressFolder)
        backend.close()
        SteamLog.event("Steam download: \(name) is installed.")
        state = .finished
    }

    // MARK: Recording the install

    /// The depots an install record lists, by depot id (empty when there is no record or it is not a finished install).
    static func installedDepots(appid: Int, steamApps: URL, fileManager: FileManager = .default) -> [Int: InstalledDepot] {
        let url = steamApps.appendingPathComponent("appmanifest_\(appid).acf")
        guard let text = try? String(contentsOf: url, encoding: .utf8), let root = SteamVDF.parse(text), let state = root["appstate"] as? [String: Any],
              (state["stateflags"] as? String) == "4", let depots = state["installeddepots"] as? [String: Any] else { return [:] }
        var found: [Int: InstalledDepot] = [:]
        for (key, value) in depots {
            guard let depot = Int(key), let node = value as? [String: Any], let manifest = (node["manifest"] as? String).flatMap({ UInt64($0) }) else { continue }
            found[depot] = InstalledDepot(id: depot, manifest: manifest, size: (node["size"] as? String).flatMap { UInt64($0) } ?? 0, dlcApp: (node["dlcappid"] as? String).flatMap { Int($0) })
        }
        return found
    }

    /// The text of the install record Steam keeps for an app (steamapps/appmanifest_<id>.acf).
    static func recordText(appid: Int, name: String, owner: String, installDir: String, buildID: String, sizeOnDisk: UInt64, updated: Date,
                           depots: [InstalledDepot], branch: String) -> String {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var lines = ["\"AppState\"", "{", "\t\"appid\"\t\t\(quoted(String(appid)))", "\t\"Universe\"\t\t\"1\"", "\t\"name\"\t\t\(quoted(name))",
                     "\t\"StateFlags\"\t\t\"4\"", "\t\"LastOwner\"\t\t\(quoted(owner))", "\t\"installdir\"\t\t\(quoted(installDir))",
                     "\t\"LastUpdated\"\t\t\(quoted(String(Int(updated.timeIntervalSince1970))))", "\t\"SizeOnDisk\"\t\t\(quoted(String(sizeOnDisk)))",
                     "\t\"buildid\"\t\t\(quoted(buildID))", "\t\"InstalledDepots\"", "\t{"]
        for depot in depots.sorted(by: { $0.id < $1.id }) {
            lines += ["\t\t\(quoted(String(depot.id)))", "\t\t{", "\t\t\t\"manifest\"\t\t\(quoted(String(depot.manifest)))", "\t\t\t\"size\"\t\t\(quoted(String(depot.size)))"]
            if let dlc = depot.dlcApp { lines.append("\t\t\t\"dlcappid\"\t\t\(quoted(String(dlc)))") }
            lines.append("\t\t}")
        }
        lines += ["\t}"] + SteamManifestLanguage.blockLines(branch: branch) + ["}", ""]
        return lines.joined(separator: "\n")
    }

    private func writeAppManifest(_ info: SteamAppInfo) {
        let steamapps = gameFolder.deletingLastPathComponent().deletingLastPathComponent()
        let dlcByDepot = Dictionary(info.depots.map { ($0.id, $0.dlcApp) }, uniquingKeysWith: { a, _ in a })
        let fetched = manifests.map { InstalledDepot(id: $0.depotID, manifest: $0.manifestID, size: $0.totalOriginal, dlcApp: (dlcByDepot[$0.depotID] ?? nil)) }
        let all = fetched + keptDepots
        let text = Self.recordText(appid: appid, name: info.name, owner: ownerSteamID ?? "0", installDir: gameFolder.lastPathComponent, buildID: info.buildID ?? "0",
                                   sizeOnDisk: total + keptDepots.reduce(0) { $0 + $1.size }, updated: Date(), depots: all, branch: selection.branch)
        try? text.write(to: steamapps.appendingPathComponent("appmanifest_\(appid).acf"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    /// Free space where the game will be written. "Important usage" is the number iOS offers for the device's own storage, but an external drive (exFAT, NTFS) often reports 0 or nothing
    /// for it while having plenty of room: a download to the SSD was refused with "0 MB is free". When it is not a positive number the ordinary capacity and the file system's own
    /// figure are asked, and the largest known is used; a genuinely full drive is still zero, and when nothing can be read the answer is nil (the download goes on).
    static func freeSpace(at url: URL) -> Int64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        let important = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let important, important > 0 { return important }
        let ordinary = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map { Int64($0) }
        let filesystem = ((try? FileManager.default.attributesOfFileSystem(forPath: folder.path))?[.systemFreeSize] as? NSNumber)?.int64Value
        return [important, ordinary, filesystem].compactMap { $0 }.filter { $0 >= 0 }.max()
    }
    static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= Double(1 << 30) { return String(format: "%.1f GB", value / Double(1 << 30)) }
        return String(format: "%.0f MB", value / Double(1 << 20))
    }
}
