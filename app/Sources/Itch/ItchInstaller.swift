// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Installing an itch.io game. itch.io games are plain downloads: pick the game's Windows upload, fetch it (resumable), and then
//   * a .zip, .7z or .rar is unpacked into C:\itch\<name> and the game's program is found (itch's own .itch.toml manifest if there is one, else the likeliest .exe);
//   * a bare .exe that is not an installer is the game itself and is moved into C:\itch\<name>;
//   * an installer (.exe named setup/install, or an .msi) is run on the Wine desktop, and what it adds to Program Files is found afterwards.
// The download files are deleted once the game is in. Nothing here logs the API key or a signed download address.

import Foundation
import Combine
import UIKit

struct ItchInstalledGame: Codable {
    var game: ItchGame
    /// Relative to drive C ("itch/some-game" or "Program Files (x86)/Some Game").
    var installDir: String
    /// The program's Windows path.
    var exe: String
    var uploadID: Int
}

struct ItchSetup: Codable {
    var file: String
    /// "exe" or "msi".
    var kind: String
}

enum ItchInstallResult {
    case installed(ItchInstalledGame)
    case setup(ItchSetup)
}

@MainActor final class ItchInstaller: ObservableObject {
    static let shared = ItchInstaller()

    enum State: Equatable {
        case queued, active, paused, failed(String)
        /// An installer is downloaded and has not run (or did not finish).
        case ready
        case running
        case installed
    }
    struct Install: Equatable {
        var state: State
        var progress = SteamDownloadProgress()
        var isDownload: Bool { switch state { case .queued, .active, .paused, .failed: return true; default: return false } }
    }
    struct Pending: Codable { var game: ItchGame; var uploadID: Int? }
    struct Store: Codable {
        var installed: [Int: ItchInstalledGame] = [:]
        var pending: [Int: Pending] = [:]
        var setups: [Int: ItchSetup] = [:]
        /// What Program Files held before an installer ran, to tell what it added.
        var before: [Int: [String]] = [:]
    }

    @Published private(set) var installs: [Int: Install] = [:]
    @Published private(set) var installed: [Int: ItchInstalledGame] = [:]
    @Published private(set) var ready = false
    @Published var error: String?

    private var pending: [Int: Pending] = [:]
    private var setups: [Int: ItchSetup] = [:]
    private var before: [Int: [String]] = [:]
    private var queue: [Int] = []
    private var active: (id: Int, task: Task<Void, Never>)?
    private var runningID: Int?
    private var removing = Set<Int>()
    private var backgroundPaused = Set<Int>()
    private var saving: Task<Void, Never>?
    private var lastProgressPublish = Date.distantPast
    private let worker = ItchInstallWorker()
    private let background = EpicBackground(store: "itch", label: "itch.io")

    private init() {
        Task {
            do {
                let store = try await worker.load()
                installed = store.installed; pending = store.pending; setups = store.setups; before = store.before
                for (id, record) in installed {
                    if await worker.exists(record.exe) { installs[id] = Install(state: .installed); register(record) }
                    else { installed.removeValue(forKey: id) }
                }
                for (id, _) in pending where installs[id] == nil { installs[id] = Install(state: setups[id] != nil ? .ready : .paused) }
                background.attach(active: { [weak self] in self?.active != nil || self?.queue.isEmpty == false },
                                  pause: { [weak self] in self?.pauseForBackground() },
                                  resume: { [weak self] in self?.resumeAfterBackground() })
                background.anyPaused = { [weak self] in self?.installs.values.contains { $0.state == .paused } == true }
                ready = true
            } catch { self.error = "Could not read itch.io installs: " + error.localizedDescription }
        }
    }

    // MARK: Asking

    var activeID: Int? { active?.id }
    func isInstalled(_ id: Int) -> Bool { installs[id]?.state == .installed }
    func game(for id: Int) -> ItchGame? { pending[id]?.game ?? installed[id]?.game }
    func entry(_ id: Int) -> Game? { installed[id] == nil ? nil : AppModel.shared.games.first { $0.itchID == id } }

    private func register(_ record: ItchInstalledGame) {
        AppModel.shared.upsertItch(id: record.game.id, title: record.game.title, exe: record.exe, art: record.game.cover)
    }

    private func persist() {
        let store = Store(installed: installed, pending: pending, setups: setups, before: before), previous = saving
        saving = Task {
            await previous?.value
            do { try await worker.save(store) } catch { self.error = "Could not save itch.io installs: " + error.localizedDescription }
        }
    }

    /// The Windows downloads a game offers, best first, for the page's "which one" choice.
    func uploads(for game: ItchGame) async -> [ItchUpload] {
        guard let key = ItchAuth.shared.apiKey(), let all = try? await ItchAPI.uploads(of: game, key: key) else { return [] }
        return ItchInstallWorker.candidates(all)
    }

    func refreshArt(from list: [ItchGame]) {
        var changed = false
        for (id, record) in installed {
            guard let fresh = list.first(where: { $0.id == id }), fresh.coverURL != record.game.coverURL else { continue }
            var updated = record
            updated.game = fresh
            installed[id] = updated
            register(updated)
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Actions

    func install(_ game: ItchGame, uploadID: Int? = nil) {
        guard ready, !removing.contains(game.id), installed[game.id] == nil else { return }
        let id = game.id
        if installs[id]?.state == .active || installs[id]?.state == .queued || installs[id]?.state == .running { return }
        if setups[id] != nil {
            switch installs[id]?.state { case .ready?, .failed?: runInstaller(id); return; default: break }
        }
        pending[id] = Pending(game: game, uploadID: uploadID ?? pending[id]?.uploadID)
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
    func resume(_ id: Int) { if let p = pending[id] { install(p.game, uploadID: p.uploadID) } }
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
    func resumeAll() { for (id, install) in installs where install.state == .paused { if let p = pending[id] { self.install(p.game, uploadID: p.uploadID) } } }
    func cancelCurrent() { if let id = activeID ?? queue.first ?? installs.first(where: { $0.value.isDownload })?.key { cancel(id) } }
    private func pauseForBackground() { for id in queue + (active.map { [$0.id] } ?? []) { pause(id); backgroundPaused.insert(id) } }
    private func resumeAfterBackground() {
        let ids = backgroundPaused; backgroundPaused.removeAll()
        for id in ids { if let p = pending[id] { install(p.game, uploadID: p.uploadID) } }
    }

    func cancel(_ id: Int) { remove(id, uninstall: false) }
    func uninstall(_ id: Int) { remove(id, uninstall: true) }

    private func remove(_ id: Int, uninstall: Bool) {
        guard ready, !removing.contains(id) else { return }
        if uninstall, AppModel.shared.session.isActive, AppModel.shared.session.game?.itchID == id {
            error = "End the game session before uninstalling."; return
        }
        if !uninstall, installed[id] != nil { return }
        removing.insert(id); pause(id)
        let task = active?.id == id ? active?.task : nil
        let dir = installed[id]?.installDir
        let leftover = pending[id].map { "itch/" + ItchInstallWorker.folderName(for: $0.game) }
        Task {
            await task?.value
            await worker.removeFiles(id: id, installDir: dir ?? leftover)
            pending.removeValue(forKey: id); setups.removeValue(forKey: id); before.removeValue(forKey: id)
            if uninstall { installed.removeValue(forKey: id); AppModel.shared.removeItch(id: id) }
            installs.removeValue(forKey: id)
            persist(); removing.remove(id)
        }
    }

    // MARK: The queue

    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let job = pending[id], !removing.contains(id) else { startNext(); return }
        installs[id]?.state = .active
        background.downloadStarted(name: job.game.title)
        let task = Task(priority: .userInitiated) {
            var outcome = EpicBackground.Outcome.paused
            do {
                guard let key = ItchAuth.shared.apiKey() else { throw ItchError.notSignedIn }
                let result = try await worker.download(job.game, uploadID: job.uploadID, key: key) { progress in
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
                    installed[id] = record; pending.removeValue(forKey: id); setups.removeValue(forKey: id)
                    register(record)
                    installs[id] = Install(state: .installed)
                    persist()
                    outcome = .completed
                case .setup(let setup):
                    setups[id] = setup
                    installs[id]?.state = .ready
                    persist()
                    outcome = .downloaded
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if installs[id]?.state != .queued { installs[id]?.state = .paused }
                } else {
                    let message = error.localizedDescription
                    installs[id]?.state = .failed(message)
                    outcome = .failed(message)
                    LogStore.shared.log("[itch-install] failure: \(message)", level: .error)
                }
            }
            active = nil
            background.downloadEnded(name: job.game.title, outcome: outcome, queueEmpty: queue.isEmpty)
            startNext()
            if outcome == .downloaded, UIApplication.shared.applicationState == .active, !AppModel.shared.session.isActive { runInstaller(id) }
        }
        active = (id, task)
    }

    // MARK: Installers

    func runInstaller(_ id: Int) {
        guard let game = pending[id]?.game ?? installed[id]?.game, let setup = setups[id], runningID == nil, !AppModel.shared.session.isActive else {
            if AppModel.shared.session.isActive { error = "End the running game before installing." }
            return
        }
        Task {
            before[id] = await worker.snapshot()
            persist()
            let path = "C:\\Installers\\itch\\\(id)\\" + setup.file
            var runner = Game(name: "Installer: " + game.title, exe: setup.kind == "msi" ? "C:\\windows\\syswow64\\msiexec.exe" : path)
            if setup.kind == "msi" { runner.args = "/i " + path }
            runner.inDesktop = true; runner.installer = true
            runningID = id
            installs[id]?.state = .running
            error = nil
            LogStore.shared.log("[itch-install] running the installer for game \(id)")
            AppModel.shared.session.start(runner)
        }
    }

    /// The Wine session ended: if it was an installer, look for what it added.
    func sessionEnded() {
        guard let id = runningID, let game = pending[id]?.game ?? installed[id]?.game else { return }
        runningID = nil
        let snapshot = before[id] ?? []
        Task {
            do {
                let record = try await worker.finishInstaller(game, before: snapshot, uploadID: pending[id]?.uploadID ?? 0)
                installed[id] = record; pending.removeValue(forKey: id); setups.removeValue(forKey: id); before.removeValue(forKey: id)
                register(record)
                installs[id] = Install(state: .installed)
                persist()
                LogStore.shared.log("[itch-install] installed game \(id)")
            } catch {
                installs[id]?.state = .ready
                self.error = error.localizedDescription
                LogStore.shared.log("[itch-install] the installer left nothing to run: \(error.localizedDescription)", level: .error)
            }
        }
    }
}

// MARK: - Worker

private actor ItchInstallWorker {
    private let storeURL: URL

    init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        storeURL = support.appendingPathComponent("itch-installs.json")
    }
    func load() throws -> ItchInstaller.Store {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return ItchInstaller.Store() }
        return try JSONDecoder().decode(ItchInstaller.Store.self, from: Data(contentsOf: storeURL))
    }
    func save(_ store: ItchInstaller.Store) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }

    private var drive: URL { AppModel.driveC }
    func exists(_ windowsPath: String) -> Bool {
        AppModel.unixURL(forWindows: windowsPath).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// A short, plain folder name from the game's page address ("https://studio.itch.io/some-game" -> "some-game").
    nonisolated static func folderName(for game: ItchGame) -> String {
        let slug = game.page?.lastPathComponent ?? ""
        let base = slug.isEmpty ? "game\(game.id)" : slug
        let clean = base.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? String($0) : "_" }.joined()
        return clean.isEmpty ? "game\(game.id)" : clean
    }
    private func downloadDirectory(_ id: Int) -> URL { drive.appendingPathComponent("Installers/itch/\(id)", isDirectory: true) }

    func removeFiles(id: Int, installDir: String?) {
        try? FileManager.default.removeItem(at: downloadDirectory(id))
        guard let installDir, !installDir.contains("..") else { return }
        let parts = installDir.split(separator: "/")
        // Only a game's own folder: itch/<name> or Program Files[ (x86)]/<name>; never a root.
        guard parts.count == 2, ["itch", "Program Files", "Program Files (x86)"].contains(String(parts[0])) else { return }
        try? FileManager.default.removeItem(at: drive.appendingPathComponent(installDir, isDirectory: true))
    }

    // MARK: Choosing

    nonisolated static func candidates(_ uploads: [ItchUpload]) -> [ItchUpload] {
        uploads.filter { $0.windows && $0.type == "default" && $0.storage != "external" }.sorted { score($0) > score($1) }
    }

    private nonisolated static func score(_ upload: ItchUpload) -> Int {
        var s = 0
        if ["zip", "7z", "rar", "exe", "msi"].contains(upload.ext) { s += 100 }
        if !upload.demo { s += 50 }
        let name = (upload.filename + " " + upload.displayName).lowercased()
        if name.contains("64") { s += 10 }
        if name.contains("win") { s += 5 }
        if name.contains("demo") || name.contains("trial") { s -= 20 }
        return s
    }

    // MARK: Download and place

    func download(_ game: ItchGame, uploadID: Int?, key: String,
                  progress: @escaping @Sendable (SteamDownloadProgress) async -> Void) async throws -> ItchInstallResult {
        var status = SteamDownloadProgress()
        await progress(status)
        let uploads = Self.candidates(try await ItchAPI.uploads(of: game, key: key))
        guard let upload = uploads.first(where: { $0.id == uploadID }) ?? uploads.first else {
            throw ItchError.server("This game has no Windows download on itch.io (it may be a browser game, or Linux/Mac only).")
        }
        guard ["zip", "7z", "rar", "exe", "msi"].contains(upload.ext) else {
            throw ItchError.server("The Windows download is a .\(upload.ext) file, which Porthole cannot unpack yet.")
        }
        LogStore.shared.log("[itch-install] \(uploads.count) Windows upload(s); using a .\(upload.ext) of \(upload.size / 1_048_576) MB")

        let values = try drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = UInt64(max(0, max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))))
        guard upload.size == 0 || free >= upload.size * 3 + 256 * 1024 * 1024 else {
            throw ItchError.server("Not enough free space: the download is \(upload.size / 1_048_576) MB and needs about three times that while it unpacks.")
        }

        let dir = downloadDirectory(game.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Self.safeName(upload.filename)
        let final = dir.appendingPathComponent(name), part = dir.appendingPathComponent(name + ".part")
        status.phase = .downloading; status.totalBytes = upload.size
        await progress(status)
        if let size = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.uint64Value, size > 0 {
            // fetched whole on an earlier try
        } else {
            let link = try await ItchAPI.downloadURL(upload: upload, game: game, key: key)
            let resumedAt = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let meter = ItchMeter(total: upload.size)
            try await GogFileFetcher.fetchFast(url: link, to: part) { have in
                if let p = meter.progress(have: have, resumedAt: resumedAt) { Task { await progress(p) } }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size > 0 else { try? FileManager.default.removeItem(at: part); throw ItchError.server("itch.io sent an empty file. Try again.") }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
        }

        let folder = Self.folderName(for: game)
        let root = drive.appendingPathComponent("itch/\(folder)", isDirectory: true)
        status.doneBytes = upload.size; status.phase = .finishing
        await progress(status)

        switch upload.ext {
        case "zip", "7z", "rar":
            try? FileManager.default.removeItem(at: root)
            do {
                // By what the file really is (a ".zip" that is a 7z, or the other way round, does exist).
                if ItchRar.isRar(final) { try ItchRar.extract(final, to: root, stripCommonFolder: true) { _ in } }
                else if ItchSevenZip.is7z(final) { try ItchSevenZip.extract(final, to: root, stripCommonFolder: true) { _ in } }
                else { try ItchZip.extract(final, to: root, stripCommonFolder: true) { _ in } }
                // Some builds are a zip that holds the game's real .7z, .rar or .zip: unpack those where they lie.
                let inner = try ItchSevenZip.unpackInner(in: root)
                if inner > 0 { LogStore.shared.log("[itch-install] unpacked \(inner) archive(s) inside the download") }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            let record = try register(game, root: root, folder: folder, installDir: "itch/\(folder)", uploadID: upload.id)
            try? FileManager.default.removeItem(at: dir)
            return .installed(record)
        case "msi":
            return .setup(ItchSetup(file: name, kind: "msi"))
        default:
            if Self.looksLikeInstaller(name) { return .setup(ItchSetup(file: name, kind: "exe")) }
            // A game that is one program: it lives in its own folder.
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: final, to: root.appendingPathComponent(name))
            let record = try register(game, root: root, folder: folder, installDir: "itch/\(folder)", uploadID: upload.id)
            try? FileManager.default.removeItem(at: dir)
            return .installed(record)
        }
    }

    private func register(_ game: ItchGame, root: URL, folder: String, installDir: String, uploadID: Int) throws -> ItchInstalledGame {
        guard let relative = Self.pickProgram(in: root, title: game.title) else {
            throw ItchError.server("The game unpacked, but Porthole could not find its program (.exe). Add it with the + button; its folder is C:\\\(installDir.replacingOccurrences(of: "/", with: "\\")).")
        }
        let windows = "C:\\" + installDir.replacingOccurrences(of: "/", with: "\\") + "\\" + relative.replacingOccurrences(of: "/", with: "\\")
        return ItchInstalledGame(game: game, installDir: installDir, exe: windows, uploadID: uploadID)
    }

    // MARK: Installers

    /// The folders Program Files holds now (so a later look can tell what an installer added).
    func snapshot() -> [String] {
        var names: [String] = []
        for parent in ["Program Files", "Program Files (x86)"] {
            let list = (try? FileManager.default.contentsOfDirectory(atPath: drive.appendingPathComponent(parent).path)) ?? []
            names += list.map { parent + "/" + $0 }
        }
        return names
    }

    func finishInstaller(_ game: ItchGame, before: [String], uploadID: Int) throws -> ItchInstalledGame {
        let known = Set(before)
        for path in snapshot() where !known.contains(path) {
            let root = drive.appendingPathComponent(path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let record = try? register(game, root: root, folder: "", installDir: path, uploadID: uploadID) {
                try? FileManager.default.removeItem(at: downloadDirectory(game.id))
                return record
            }
        }
        throw ItchError.server("The installer ran, but nothing new showed up in Program Files. If it installed somewhere else, add the game with the + button.")
    }

    // MARK: Finding the program

    nonisolated static func looksLikeInstaller(_ filename: String) -> Bool {
        let n = filename.lowercased()
        return n.contains("setup") || n.contains("install")
    }

    private nonisolated static func safeName(_ raw: String) -> String {
        let clean = raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? String($0) : "_" }.joined()
        return clean.isEmpty || clean.hasPrefix(".") ? "download_" + clean : clean
    }

    /// The path (relative to `root`, forward slashes) of the program that starts the game.
    nonisolated static func pickProgram(in root: URL, title: String) -> String? {
        let fm = FileManager.default
        // itch's own manifest, when the developer shipped one: the first action's path.
        if let manifest = try? String(contentsOf: root.appendingPathComponent(".itch.toml"), encoding: .utf8),
           let range = manifest.range(of: "path\\s*=\\s*\"[^\"]+\"", options: .regularExpression) {
            let raw = String(manifest[range]).components(separatedBy: "\"")[1].replacingOccurrences(of: "\\", with: "/")
            if let safe = GogContent.safePath(raw), fm.fileExists(atPath: root.appendingPathComponent(safe).path), safe.lowercased().hasSuffix(".exe") { return safe }
        }
        let skipDirs: Set<String> = ["_commonredist", "redist", "vcredist", "directx", "dotnet", "support", "__macosx", "mono", "monobleedingedge", "crashreporter"]
        let skipNames = ["unins", "uninstall", "crashhandler", "crashreport", "crashpad", "vc_redist", "vcredist", "dxsetup", "dxwebsetup", "dotnet", "ndp4",
                         "setup", "install", "updater", "unitycrash", "oalinst", "physx"]
        let wanted = title.lowercased().filter { $0.isLetter || $0.isNumber }
        var best: (score: Int, size: Int, path: String)?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let depth = relative.split(separator: "/").count - 1
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if depth >= 3 || skipDirs.contains(url.lastPathComponent.lowercased()) { walker.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".exe"), !skipNames.contains(where: { name.contains($0) }) else { continue }
            let stem = String(name.dropLast(4)).filter { $0.isLetter || $0.isNumber }
            var score = -depth * 3
            if depth == 0 { score += 20 }
            if !wanted.isEmpty, stem == wanted { score += 100 }
            else if stem.count >= 3, !wanted.isEmpty, wanted.contains(stem) || stem.contains(wanted) { score += 50 }
            let size = values?.fileSize ?? 0
            if best == nil || score > best!.score || (score == best!.score && size > best!.size) { best = (score, size, relative) }
        }
        return best?.path
    }
}

/// Position and speed of a download, reported from the network's own queue at most four times a second.
private final class ItchMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private let start = Date()
    private var lastReport = Date.distantPast
    init(total: UInt64) { self.total = total }

    func progress(have: UInt64, resumedAt: UInt64) -> SteamDownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.25 else { return nil }
        lastReport = now
        let fetched = have > resumedAt ? have - resumedAt : 0
        return SteamDownloadProgress(doneBytes: have, totalBytes: max(total, have), bytesPerSecond: Double(fetched) / max(0.5, now.timeIntervalSince(start)))
    }
}
