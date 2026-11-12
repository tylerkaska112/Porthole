// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Installing and starting an EA game. EA serves a build as one zip archive on its CDN; EADownloader (Madeira's) reads its table of contents with range requests and
// inflates each file straight into C:\Program Files\EA Games\<folder>, checking every CRC, with a journal so a paused download continues where it stopped. The queue,
// pause, resume, cancel and background handling follow the other stores' installers (Amazon/AmazonInstaller.swift). What a game needs to START is Madeira's recipe
// (docs/EA.md): a licence for this machine, the EA app's registry keys and environment, and a local service on 127.0.0.1:3216 that answers the game's questions.
//
// Nothing here logs a token, a code or a download address; only counts, sizes and states.

import Foundation
import Combine
import UIKit

@MainActor final class EAInstaller: ObservableObject {
    static let shared = EAInstaller()

    enum State: Equatable { case queued, active, paused, failed(String), installed }
    enum Kind: String, Codable { case install, update, repair }
    struct Install: Equatable {
        var state: State
        var kind: Kind = .install
        var progress = SteamDownloadProgress()
        /// While preparing: what is being fetched from EA ("Reading the build's file list").
        var step: String?
        var isDownload: Bool { switch state { case .queued, .active, .paused, .failed: return true; default: return false } }
    }
    /// A download that has not finished: kept so a paused one is still there after the app was closed.
    struct Pending: Codable, Equatable {
        var title: String
        var kind: Kind
    }
    struct Store: Codable {
        var installed: [String: EAInstalledGame] = [:]
        var pending: [String: Pending] = [:]
    }

    @Published private(set) var installs: [String: Install] = [:]
    @Published private(set) var installed: [String: EAInstalledGame] = [:]
    @Published private(set) var ready = false
    @Published var error: String?

    static let installRoot = "Program Files/EA Games"

    private var pending: [String: Pending] = [:]
    private var queue: [String] = []
    private var active: (id: String, task: Task<Void, Never>)?
    private var removing = Set<String>()
    private var backgroundPaused = Set<String>()
    private var saving: Task<Void, Never>?
    private var lastProgressPublish = Date.distantPast
    private let downloader = EADownloader()
    private let background = EpicBackground(store: "ea", label: "EA app")
    /// The game whose launch was prepared (its environment and local service), until its session ends.
    private var launched: String?

    private init() {
        let store = Self.load()
        installed = store.installed; pending = store.pending
        for (id, record) in installed {
            if AppModel.unixURL(forWindows: record.windowsProgram).map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                installs[id] = Install(state: .installed)
                register(record)
            } else { installed.removeValue(forKey: id) }
        }
        for (id, item) in pending where installs[id] == nil || installed[id] != nil {
            installs[id] = Install(state: .paused, kind: item.kind)
        }
        background.attach(active: { [weak self] in self?.active != nil || self?.queue.isEmpty == false },
                          pause: { [weak self] in self?.pauseForBackground() },
                          resume: { [weak self] in self?.resumeAfterBackground() })
        background.anyPaused = { [weak self] in self?.installs.values.contains { $0.state == .paused } == true }
        ready = true
    }

    // MARK: Files

    private static var drive: URL { AppModel.driveC }
    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EA", isDirectory: true) }
    private static var storeURL: URL { support.appendingPathComponent("ea-installs.json") }
    /// The installed build's file list, so an update keeps unchanged files without reading them.
    private static func filesURL(_ id: String) -> URL { support.appendingPathComponent("manifests", isDirectory: true).appendingPathComponent(safeName(id) + ".json") }
    private static func journalURL(_ id: String) -> URL { support.appendingPathComponent("downloads", isDirectory: true).appendingPathComponent(safeName(id) + ".journal") }
    private static func folderNoteURL(_ id: String) -> URL { journalURL(id).deletingPathExtension().appendingPathExtension("folder") }

    /// A file or folder name made from EA's text: no separators, no dots at the ends.
    nonisolated static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }

    private static func load() -> Store {
        guard let data = try? Data(contentsOf: storeURL), let store = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return store
    }

    private func persist() {
        let store = Store(installed: installed, pending: pending), previous = saving
        saving = Task {
            await previous?.value
            do {
                try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
                try JSONEncoder().encode(store).write(to: Self.storeURL, options: .atomic)
            } catch { self.error = "Could not save EA installs: " + ErrorText.plain(error) }
        }
    }

    // MARK: Asking

    func isInstalled(_ id: String) -> Bool { installed[id] != nil }
    var activeID: String? { active?.id }
    /// The games waiting, in the order they will start (the shared Downloads page shows them).
    var queueOrder: [String] { queue }
    func record(_ id: String) -> EAInstalledGame? { installed[id] }
    func title(for id: String) -> String? { installed[id]?.title ?? pending[id]?.title ?? EALibrary.shared.game(id)?.title }
    func art(for id: String) -> URL? { EALibrary.shared.game(id)?.art ?? installed[id]?.cover }
    /// The game as the library holds it once installed (reports and settings are about that program).
    func entry(_ id: String) -> Game? { installed[id] == nil ? nil : AppModel.shared.games.first { $0.eaOfferID == id } }
    func updateAvailable(_ id: String) -> Bool {
        guard let record = installed[id], let latest = EALibrary.shared.latestBuild[id] else { return false }
        return latest != record.buildID
    }
    /// A first install was paused or failed: its journal is on disk.
    func hasPartialDownload(_ id: String) -> Bool { FileManager.default.fileExists(atPath: Self.journalURL(id).path) }

    private func register(_ record: EAInstalledGame) {
        AppModel.shared.upsertEA(offerID: record.offerID, title: record.title, exe: record.windowsProgram, args: record.arguments, art: record.cover)
    }

    // MARK: Actions

    func install(_ id: String) { enqueue(id, kind: installed[id] == nil ? .install : .update) }
    func repair(_ id: String) { enqueue(id, kind: .repair) }

    private func enqueue(_ id: String, kind: Kind) {
        guard ready, !removing.contains(id) else { return }
        guard EAAuth.shared.signedIn else { error = EAAPIError.signedOut.localizedDescription; return }
        if installs[id]?.state == .active || installs[id]?.state == .queued { return }
        guard let title = title(for: id) else { error = EAAPIError.invalid("unknown-game").localizedDescription; return }
        pending[id] = Pending(title: title, kind: kind)
        installs[id] = Install(state: .queued, kind: kind, progress: installs[id]?.progress ?? SteamDownloadProgress())
        error = nil
        queue.append(id); persist(); startNext()
    }

    func pause(_ id: String) {
        backgroundPaused.remove(id)
        queue.removeAll { $0 == id }
        if active?.id == id { active?.task.cancel() }
        if installs[id]?.state == .queued || installs[id]?.state == .active { installs[id]?.state = .paused }
        persist()
    }
    func pauseAll() { for id in queue + (active.map { [$0.id] } ?? []) { pause(id) } }
    func resume(_ id: String) { enqueue(id, kind: pending[id]?.kind ?? (installed[id] == nil ? .install : .update)) }
    func resumeAll() { for (id, install) in installs where install.state == .paused { resume(id) } }

    /// Puts a waiting download first: the one running now is stopped, goes back behind it, and carries on afterwards.
    func startNow(_ id: String) {
        guard ready, pending[id] != nil, active?.id != id else { return }
        let displaced = active?.id
        queue.removeAll { $0 == id }
        queue.insert(id, at: 0)
        installs[id]?.state = .queued
        if let displaced {
            backgroundPaused.remove(displaced)
            active?.task.cancel()
            installs[displaced]?.state = .queued
            queue.insert(displaced, at: 1)
        } else { startNext() }
        persist()
    }

    func cancelCurrent() {
        if let id = activeID ?? queue.first ?? installs.first(where: { $0.value.isDownload })?.key { cancel(id) }
    }

    private func pauseForBackground() {
        for id in queue + (active.map { [$0.id] } ?? []) { pause(id); backgroundPaused.insert(id) }
    }
    private func resumeAfterBackground() {
        let ids = backgroundPaused; backgroundPaused.removeAll()
        for id in ids { resume(id) }
    }

    /// Stops a download. A first install's partial files are removed; an update or repair only stops, and the game stays as it was.
    func cancel(_ id: String) {
        guard ready, !removing.contains(id) else { return }
        let firstInstall = installed[id] == nil
        removing.insert(id); pause(id)
        let task = active?.id == id ? active?.task : nil
        Task {
            await task?.value
            if firstInstall { Self.removePartial(id) }
            pending.removeValue(forKey: id)
            installs[id] = installed[id] == nil ? nil : Install(state: .installed)
            persist(); removing.remove(id)
            LogStore.shared.log("[ea-download] cancelled id=\(id) first-install=\(firstInstall)")
        }
    }

    private static func removePartial(_ id: String) {
        let sidecar = folderNoteURL(id)
        if let folder = try? String(contentsOf: sidecar, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty,
           folder.hasPrefix(installRoot + "/"), !folder.contains("..") {
            try? FileManager.default.removeItem(at: drive.appendingPathComponent(folder, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: sidecar)
        try? FileManager.default.removeItem(at: journalURL(id))
    }

    /// Deletes the game's files and records; its library entry goes with them.
    func uninstall(_ id: String) {
        guard ready, !removing.contains(id) else { return }
        if AppModel.shared.session.isActive, AppModel.shared.session.game?.eaOfferID == id {
            error = "End the game session before uninstalling."; return
        }
        removing.insert(id); pause(id)
        let task = active?.id == id ? active?.task : nil
        let record = installed[id]
        Task {
            await task?.value
            if let record, record.folder.hasPrefix(Self.installRoot + "/"), !record.folder.contains("..") {
                try? FileManager.default.removeItem(at: Self.drive.appendingPathComponent(record.folder, isDirectory: true))
            }
            try? FileManager.default.removeItem(at: Self.filesURL(id))
            Self.removePartial(id)
            pending.removeValue(forKey: id)
            installed.removeValue(forKey: id)
            installs.removeValue(forKey: id)
            AppModel.shared.removeEA(offerID: id)
            persist(); removing.remove(id)
            LogStore.shared.log("[ea-library] uninstalled id=\(id)")
        }
    }

    // MARK: The queue

    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let item = pending[id], !removing.contains(id) else { startNext(); return }
        installs[id]?.state = .active
        background.downloadStarted(name: item.title)
        let task = Task(priority: .userInitiated) { @MainActor in
            var outcome = EpicBackground.Outcome.paused
            do {
                try await run(id, kind: item.kind, title: item.title)
                try Task.checkCancellation()
                outcome = .completed
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    if installs[id]?.state != .queued { installs[id]?.state = .paused }
                    LogStore.shared.log("[ea-download] paused id=\(id)")
                } else {
                    let message = ErrorText.plain(error)
                    installs[id]?.state = .failed(message)
                    outcome = .failed(message)
                    EALibrary.note(error, context: "download id=\(id)")
                }
            }
            active = nil
            background.downloadEnded(name: item.title, outcome: outcome, queueEmpty: queue.isEmpty)
            startNext()
        }
        active = (id, task)
    }

    private func publish(_ id: String, _ progress: EADownloadProgress) {
        guard active?.id == id, installs[id]?.state == .active else { return }
        let mapped = SteamDownloadProgress(doneBytes: progress.doneBytes, totalBytes: progress.totalBytes, bytesPerSecond: progress.bytesPerSecond)
        var shown = mapped
        shown.phase = progress.phase == .downloading ? .downloading : progress.phase == .finishing ? .finishing : .preparing
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= 0.5 || installs[id]?.progress.phase != shown.phase else { return }
        lastProgressPublish = now
        installs[id]?.progress = shown
        installs[id]?.step = progress.step
        background.progress(shown, waiting: queue.count)
    }

    private func run(_ id: String, kind: Kind, title: String) async throws {
        let api = EAAPI.shared
        let game = EALibrary.shared.game(id)
        func step(_ text: String) {
            installs[id]?.step = text
            LogStore.shared.log("[ea-download] prepare id=\(id) step=\"\(text)\"")
        }
        step("Finding the newest build")
        let build = try await api.liveBuild(offerID: id)
        step("Getting the download address")
        let url = try await api.downloadURL(offerID: id, buildID: build.buildID)
        step("Reading the build's file list")
        let archive = try await downloader.archive(url)
        let record = installed[id]
        let folder = record?.folder ?? (Self.installRoot + "/" + Self.safeName(game?.installFolder ?? title))
        try? FileManager.default.createDirectory(at: Self.journalURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? folder.write(to: Self.folderNoteURL(id), atomically: true, encoding: .utf8)
        let previous = (try? Data(contentsOf: Self.filesURL(id))).flatMap { try? JSONDecoder().decode([EAZipEntry].self, from: $0) }
        LogStore.shared.log("[ea-download] start id=\(id) kind=\(kind.rawValue) build=\(build.buildID) files=\(archive.files.count) bytes=\(archive.compressedBytes)")
        let target = Self.drive.appendingPathComponent(folder, isDirectory: true)
        let result = try await downloader.install(archive: archive, folder: target, previous: kind == .repair ? nil : previous, verifyAll: kind == .repair,
                                                  journal: Self.journalURL(id)) { progress in
            Task { @MainActor in EAInstaller.shared.publish(id, progress) }
        }
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: Self.filesURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(archive.entries).write(to: Self.filesURL(id), options: .atomic)
        try? FileManager.default.removeItem(at: Self.folderNoteURL(id))
        let launch = try Self.launch(folder: target, catalogPath: game?.executePath)
        let finished = EAInstalledGame(
            offerID: id, title: title, folder: folder, buildID: build.buildID, version: launch.version ?? build.version,
            contentID: game?.contentID ?? launch.contentID ?? record?.contentID ?? "", multiplayerID: game?.multiplayerID ?? record?.multiplayerID ?? "",
            launchExe: launch.exe, arguments: launch.arguments, installBytes: result.installBytes,
            registryKey: launch.registryKey, registryValue: launch.registryValue, cover: game?.art ?? record?.cover)
        if finished.contentID.isEmpty { LogStore.shared.log("[ea-download] id=\(id): no content id (licence requests will not work)", level: .error) }
        installed[id] = finished
        pending.removeValue(forKey: id)
        installs[id] = Install(state: .installed)
        EALibrary.shared.noteLatest(build: build.buildID, for: id)
        register(finished)
        persist()
        Self.writeRegistry(finished)
        LogStore.shared.log("[ea-download] done id=\(id) written=\(result.filesWritten) kept=\(result.filesKept) fetched=\(result.bytesFetched)")
    }

    // MARK: What starts the game

    struct Launch: Equatable {
        var exe: String          // relative to the game's folder, forward slashes
        var arguments: String
        var version: String?
        var contentID: String?
        var registryKey: String?
        var registryValue: String?
    }

    /// How the EA app starts the game: the launcher of `__Installer/installerdata.xml`, else the catalog's program. A path behind a registry key is taken relative to the
    /// game's folder, and the key is remembered for the registry.
    nonisolated static func launch(folder: URL, catalogPath: String?) throws -> Launch {
        var data: EAInstallerData?
        if let installer = EALicense.child(of: folder, named: "__Installer"), let file = EALicense.child(of: installer, named: "installerdata.xml"),
           let bytes = try? Data(contentsOf: file) {
            data = EAInstallerData.parse(bytes)
        }
        guard let text = data?.launcher?.filePath ?? catalogPath else { throw EAAPIError.noLauncher }
        let path = EARegistryPath(text)
        let relative = path.relative.replacingOccurrences(of: "\\", with: "/")
        guard let parts = EAZipDirectory.safeComponents(relative), !parts.isEmpty else { throw EAAPIError.noLauncher }
        let exe = parts.joined(separator: "/")
        guard EALicense.child(of: parts.dropLast().reduce(folder) { $0.appendingPathComponent($1) }, named: parts.last!) != nil else {
            LogStore.shared.log("[ea-library] launcher not found: \(exe)", level: .error)
            throw EAAPIError.noLauncher
        }
        return Launch(exe: exe, arguments: data?.launcher?.parameters ?? "", version: data?.gameVersion, contentID: data?.contentIDs.first,
                      registryKey: path.key, registryValue: path.valueName)
    }

    /// The registry keys an EA game expects: the EA app's install marker and, when the game's manifest named one, its own install folder. Only while no session runs.
    nonisolated static func writeRegistry(_ record: EAInstalledGame) {
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        var values = [
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallSuccessful", data: .string("true"), followsInstall: false),
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\Origin", name: "InstallSuccessful", data: .string("true"), followsInstall: false),
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\Origin", name: "ClientPath",
                              data: .string("C:\\Windows\\System32\\conhost.exe"), followsInstall: false),
        ]
        if let key = record.registryKey, let name = record.registryValue, !key.isEmpty {
            values.append(SteamInstallValue(hive: .machine, key: key, name: name, data: .string(record.windowsInstallPath + "\\"), followsInstall: true))
        }
        do {
            let changed = try SteamInstallRegistry.write(values, prefix: AppModel.prefix)
            LogStore.shared.log("[ea-library] registry values=\(values.count) written=\(changed) game-key=\(record.registryKey == nil ? 0 : 1)")
        } catch {
            LogStore.shared.log("[ea-library] registry write failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: Starting a game

    /// What the EA app gives a game; cleared before every other launch.
    static let environmentNames = ["EAAuthCode", "EAEgsProxyIpcPort", "EAEntitlementSource", "EAExternalSource", "EAFreeTrialGame", "EAGameLocale",
                                   "EAGenericAuthToken", "EALaunchCode", "EALaunchOwner", "EALaunchEAID", "EALaunchEnv", "EALaunchOfflineMode",
                                   "EALsxPort", "EARtPLaunchCode", "EASecureLaunchTokenTemp", "EASteamProxyIpcPort", "OriginSessionKey", "ContentId",
                                   "EAOnErrorExitRetCode", "EAConnectionId", "EALicenseToken", "EALaunchUserAuthToken", "EAAccessTokenJWS"]

    nonisolated static func clearEnvironment() { for name in environmentNames { unsetenv(name) } }

    /// The machine EA sees for a game: the graphics card the game is told it has (Game details > Graphics card the game sees; the device's own otherwise) and its AVX switch.
    private func profile(for game: Game) -> EAHardwareProfile {
        let card = GPUCards.card(game.engine?.gpuCard)
        return EAHardware.profile(drive: Self.drive, gpuVendor: card?.vendor ?? GPUCards.appleVendor, gpuDevice: card?.device ?? 0x0001, avx: game.engine?.avx == true)
    }

    /// Everything an EA game needs before its session starts: a valid sign-in, its licence for this machine, the registry keys, the EA app's environment and the local
    /// service. Throws with a message for the player when something is missing.
    func prepareLaunch(_ game: Game) async throws {
        guard let id = game.eaOfferID, let record = installed[id] else { throw EAAPIError.invalid("not-installed") }
        let api = EAAPI.shared
        let session: EASession
        do { session = try await api.validSession() } catch {
            EALibrary.note(error, context: "launch id=\(id)")
            throw error
        }
        let profile = profile(for: game)
        let folder = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        let activation = EALicense.activation(gameFolder: folder)
        if activation.required {
            guard !record.contentID.isEmpty else { throw EAAPIError.license("the game's content id is unknown") }
            let (hash, _) = profile.machineHash(version: activation.hashVersion)
            let current = EALicense.current(contentID: record.contentID, drive: Self.drive)
            if EALicense.needsRenewal(current, machineHash: hash, userID: session.userID) {
                _ = try await EALicense.renew(api: api, contentID: record.contentID, profile: profile, activation: activation, drive: Self.drive)
            } else {
                LogStore.shared.log("[ea-license] kept content=\(record.contentID) hash-version=\(activation.hashVersion)")
            }
        }
        Self.writeRegistry(record)
        // The short-lived token the EA app hands a game (EALaunchUserAuthToken); a game that never reads it still starts, so a failure here is logged, not fatal.
        var opaque = ""
        do {
            opaque = try await api.exchange(clientID: EAAPI.clientID, responseType: "token",
                                            scopes: ["basic.commerce.cartv2", "service.atom", "dp.client.default", "signin", "social_recommendation_user",
                                                     "basic.optin.write", "basic.commerce.cartv2.write", "basic.billing", "external.social_information_ups_admin"],
                                            tokenFormat: "OPAQUE", expiresIn: 550, profile: profile)
        } catch {
            EALibrary.note(error, context: "launch token id=\(id)")
        }
        let launchID = UUID().uuidString.lowercased()
        let environment: [String: String] = [
            "EAAuthCode": "unavailable", "EAEgsProxyIpcPort": "0", "EAEntitlementSource": "EA", "EAExternalSource": "EA", "EAFreeTrialGame": "false",
            "EAGameLocale": "en_US", "EAGenericAuthToken": session.accessToken, "EALaunchCode": "unavailable", "EALaunchOwner": "EA",
            "EALaunchEAID": session.displayName, "EALaunchEnv": "production", "EALaunchOfflineMode": "false", "EALsxPort": String(EAService.port),
            "EARtPLaunchCode": String(EALSXCrypto.launchCode()), "EASecureLaunchTokenTemp": session.userID, "EASteamProxyIpcPort": "0",
            "OriginSessionKey": launchID, "ContentId": record.contentID, "EAOnErrorExitRetCode": "1", "EAConnectionId": id, "EALicenseToken": id,
            "EALaunchUserAuthToken": opaque, "EAAccessTokenJWS": session.accessToken,
        ]
        Self.clearEnvironment()
        for (name, value) in environment { setenv(name, value, 1) }
        try EAService.shared.start(EAServiceContext(
            offerID: id, contentID: record.contentID, title: record.title, version: record.version, multiplayerID: record.multiplayerID,
            userID: session.userID, personaID: session.personaID, displayName: session.displayName, profile: profile, hashVersion: activation.hashVersion))
        launched = id
        LogStore.shared.log("[ea-launch] id=\(id) content=\(record.contentID) licence=\(activation.required ? "checked" : "none") token=\(opaque.isEmpty ? 0 : 1)")
    }

    /// The session ended (or another game starts): the local service stops and the EA app's environment goes.
    func sessionEnded() {
        guard launched != nil else { return }
        launched = nil
        EAService.shared.stop()
        Self.clearEnvironment()
    }
}
