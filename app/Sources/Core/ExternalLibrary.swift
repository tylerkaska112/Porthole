// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Adapted from SteamStorageModel.swift of willfaust/Madeira pull request 235 (Copyright 2026 David Brookes, GPL-3.0-or-later, with Madeira's converter
// exception): the catalog, the scoped access and the session mapping are his design; the screens and the way a download picks its folder are Porthole's.
import Foundation
import SwiftUI
import UIKit

/// One game library on an external SSD, next to the iPad's own. Owns only internal metadata: a library UUID, the folder's bookmark and where each game lives.
/// Native SSD paths are obtained for one operation and are never saved. A game keeps the library it was first installed to.
@MainActor final class ExternalLibrary: ObservableObject {
    static let shared = ExternalLibrary()

    /// Posted when the SSD was reachable again (after Check, or a picked folder), so lists that showed it as missing can ask again.
    static let reconnected = Notification.Name("PortholeExternalLibraryReconnected")
    /// New Steam downloads go to the SSD (when one is registered); an installed game stays where it is.
    static let newDownloadsKey = "f4.newDownloadsExternal"
    /// Ask where a new download goes, every time, while the SSD is connected (on unless switched off).
    static let askWhereKey = "f4.askWhereToDownload"

    @Published private(set) var catalog = SteamStorageCatalog()
    @Published private(set) var availability: SteamStorageAvailability = .disconnected
    @Published private(set) var problem: String?
    @Published private(set) var checking = false
    private var loadFailure: Error?
    private weak var liveAccess: SteamExternalLease?
    private var opening: Task<SteamExternalLease, Error>?
    private(set) var sessionAccess: SteamExternalLease?
    private var sessionTimer: Timer?
    private var sawSession = false

    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("steam-storage.json")
    }

    private init() {
        do { catalog = try SteamStorageCatalog.load(from: Self.file) }
        catch { loadFailure = error; problem = "The storage catalog could not be read. Your files have been kept." }
    }

    var external: SteamStorageLibrary? { catalog.external }
    var asksWhereToDownload: Bool { UserDefaults.standard.object(forKey: Self.askWhereKey) as? Bool ?? true }
    var newDownloadsGoExternal: Bool {
        external != nil && UserDefaults.standard.bool(forKey: Self.newDownloadsKey)
    }

    func library(_ id: String) throws -> SteamStorageLibrary {
        if let loadFailure { throw loadFailure }
        return try catalog.library(id)
    }

    // MARK: Registration and the catalog

    /// Registers (or, for the same folder again, renews access to) the picked folder.
    func register(_ url: URL) async throws {
        if let loadFailure { throw loadFailure }
        let previous = catalog.external
        let registration = try await Task.detached(priority: .utility) {
            try SteamExternalAccess.register(url, replacing: previous, refuseDeviceStorage: true)
        }.value
        try catalog.transaction(file: Self.file) { try $0.register(registration) }
        liveAccess = nil
        availability = .available
        problem = nil
        NotificationCenter.default.post(name: Self.reconnected, object: registration.id)
    }

    /// How many games are recorded as living on the registered folder.
    var gamesOnExternal: Int {
        guard let id = external?.id else { return 0 }
        return catalog.assignments.values.filter { $0.location.libraryID == id }.count
    }

    private static func writeSpeedKey(_ libraryID: String) -> String { "porthole.drive-write-speed.\(libraryID)" }

    /// How a download to this game's library drive should be written. A drive measured within the last three days is not measured again; otherwise a short write test
    /// runs first (a second or two on a slow drive). If the test cannot run, the gentle way is used: it costs a fast drive little and saves a slow one.
    func writeMode(for appID: Int) async -> DriveWriteMode {
        let id = libraryID(for: appID)
        guard id != SteamStorageLibrary.internalID else { return .normal }
        let key = Self.writeSpeedKey(id)
        if let saved = UserDefaults.standard.dictionary(forKey: key), let mbps = saved["mbps"] as? Double, let at = saved["at"] as? Date,
           Date().timeIntervalSince(at) < 3 * 24 * 3600 {
            return DriveWriteMode.mode(forWriteMBps: mbps)
        }
        do {
            guard let access = try await accessForOperation(libraryID: id, write: true) else { return .gentle }
            defer { access.keepAlive() }
            let root = access.root
            let mbps = try await Task.detached(priority: .utility) { try DriveSpeedTest.quickWriteMBps(in: root) }.value
            UserDefaults.standard.set(["mbps": mbps, "at": Date()], forKey: key)
            SteamLog.event(String(format: "[steam-storage] write test before the download: %.0f MB/s, writing %@", mbps, DriveWriteMode.mode(forWriteMBps: mbps).rawValue))
            return DriveWriteMode.mode(forWriteMBps: mbps)
        } catch {
            SteamLog.event("[steam-storage] write test before the download failed (\(ErrorText.plain(error))): writing gently")
            return .gentle
        }
    }

    /// Measures the registered folder the way Porthole uses it (see DriveSpeedTest).
    func measureSpeed() async throws -> DriveSpeed {
        guard let external = catalog.external else { throw SteamStorageError.invalidRecord }
        guard let access = try await accessForOperation(libraryID: external.id, write: true) else { throw SteamStorageError.invalidRecord }
        defer { access.keepAlive() }
        let root = access.root
        let speed = try await Task.detached(priority: .utility) { try DriveSpeedTest.run(in: root) }.value
        UserDefaults.standard.set(["mbps": speed.writeMBps, "at": Date()], forKey: Self.writeSpeedKey(external.id))
        return speed
    }

    /// Stops using the registered folder so another can be chosen. The files on the drive are not deleted or touched.
    func forgetExternal() throws {
        if let loadFailure { throw loadFailure }
        try catalog.transaction(file: Self.file) { $0.forgetExternal() }
        // The drive's links and owner record in the Wine prefix belonged to the folder just forgotten (only while no game runs: Wine has them open).
        if wine_process_is_running() == 0, wineserver_is_running() == 0 {
            let fm = FileManager.default
            let links = [MadeiraDock.prefix.appendingPathComponent("dosdevices/e:"), MadeiraDock.drive.appendingPathComponent(SteamStoragePath.externalAlias)]
            for link in links where (try? fm.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType == .typeSymbolicLink { try? fm.removeItem(at: link) }
            if let owner = try? SteamStoragePath.native("madeira-external-owner", root: MadeiraDock.prefix) { try? fm.removeItem(at: owner) }
        }
        liveAccess = nil
        availability = .disconnected
        problem = nil
    }

    func assignment(for appID: Int) -> SteamStorageAssignment? { catalog.assignments[appID] }
    func libraryID(for appID: Int) -> String { catalog.assignments[appID]?.location.libraryID ?? SteamStorageLibrary.internalID }
    func isExternal(_ appID: Int) -> Bool { libraryID(for: appID) != SteamStorageLibrary.internalID }

    /// Asked before a download is queued or resumed. A game that already has files keeps its library; the choice only matters for a new one.
    func assign(appID: Int, name: String, folder: String, libraryID: String) throws -> SteamStorageAssignment {
        if let loadFailure { throw loadFailure }
        if var assigned = catalog.assignments[appID] {
            assigned.pending = true
            try catalog.transaction(file: Self.file) { try $0.assign(assigned) }
            return assigned
        }
        let selected = try library(libraryID)
        let relative = selected.id == SteamStorageLibrary.internalID ? SteamInstallPaths.libraryRelative : "steamapps"
        var value = SteamStorageAssignment(appID: appID, location: try SteamStorageLocation(libraryID: selected.id, relativePath: relative + "/common/" + folder),
                                           name: name, installed: false)
        value.pending = true
        try catalog.transaction(file: Self.file) { try $0.assign(value) }
        return value
    }

    func record(_ value: SteamStorageAssignment) throws {
        if let loadFailure { throw loadFailure }
        try catalog.transaction(file: Self.file) { try $0.assign(value) }
    }

    func removed(appID: Int) throws {
        if let loadFailure { throw loadFailure }
        try catalog.transaction(file: Self.file) { next in
            let location = next.assignments[appID]?.location
            let shared = next.assignments.values.filter { $0.appID == appID || (location != nil && $0.location == location) }.map(\.appID)
            for id in shared { next.remove(appID: id) }
        }
    }

    /// What the SSD's games are, without touching the disk: they stay listed when the drive is not there.
    var rememberedGames: [DockGame] {
        catalog.assignments.values.filter { $0.location.libraryID != SteamStorageLibrary.internalID }.compactMap { record in
            let parts = record.location.relativePath.split(separator: "/")
            guard parts.count >= 3, parts[parts.count - 2] == "common" else { return nil }
            return DockGame(id: record.appID, name: record.name, installDir: String(parts.last!),
                            library: parts.dropLast(2).joined(separator: "/"), installed: record.installed,
                            customExecutables: false, storageID: record.location.libraryID, storageAvailable: false)
        }
    }

    /// The remembered record of one external game, or nil.
    func dockGame(appID: Int) -> DockGame? { rememberedGames.first { $0.id == appID } }

    /// Reads the SSD's own app records and brings the catalog up to date (a game copied or deleted on the drive shows up). A failed scan keeps the old snapshot.
    func scan() async {
        guard let external = catalog.external, availability == .available || availability == .readOnly else { return }
        do {
            let records = try await perform(libraryID: external.id, write: false) { root -> [(DockGame, Int?, Int64?)] in
                let apps = try SteamStoragePath.native("steamapps", root: root)
                return try MadeiraDock.games(library: external, root: root).map { game in
                    (game, SteamInstallFiles.buildID(appID: game.id, steamApps: apps), SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: apps))
                }
            }
            for (game, build, bytes) in records {
                let location = try SteamStorageLocation(libraryID: game.storageID, relativePath: game.library + "/common/" + game.installDir)
                if let assigned = catalog.assignments[game.id], assigned.location != location { continue }   // one install per app
                var value = SteamStorageAssignment(appID: game.id, location: location, name: game.name, installed: game.installed, buildID: build, bytes: bytes)
                value.pending = catalog.assignments[game.id]?.pending
                if value.pending == true, game.installed { value.pending = false }
                if catalog.assignments[game.id] != value { try record(value) }
            }
        } catch { SteamLog.event("[steam-storage] scan failed: \(ErrorText.plain(error))") }
    }

    // MARK: Scoped access

    /// Runs `operation` with the SSD's root while its security scope and coordination are held; a failed volume check changes the availability, a network error does not.
    func perform<Value: Sendable>(libraryID: String, write: Bool, _ operation: @escaping @Sendable (URL) async throws -> Value) async throws -> Value {
        _ = try library(libraryID)
        guard libraryID != SteamStorageLibrary.internalID else { return try await operation(MadeiraDock.drive) }
        guard let access = try await accessForOperation(libraryID: libraryID, write: write) else { throw SteamStorageError.invalidRecord }
        defer { access.keepAlive() }
        return try await SteamStorageOperation.run({ try await operation(access.root) }) {
            do {
                try await Task.detached(priority: .utility) { try access.validate() }.value
                availability = access.writable ? .available : .readOnly
                problem = access.writable ? nil : SteamStorageError.unavailable(.readOnly).localizedDescription
            } catch {
                liveAccess = nil
                availability = SteamExternalAccess.availability(for: error)
                problem = SteamStorageError.unavailable(availability).localizedDescription
                throw SteamStorageError.unavailable(availability)
            }
        }
    }

    private func acquire(libraryID: String, write: Bool) async throws -> SteamExternalLease {
        let registration = try library(libraryID)
        let access: SteamExternalLease
        if let current = liveAccess {
            access = current
        } else {
            if opening == nil { opening = Task { try await SteamExternalLease.open(registration) } }
            do {
                access = try await opening!.value
                liveAccess = access
                opening = nil
            } catch { opening = nil; throw error }
        }
        guard access.library.id == libraryID else { throw SteamStorageError.unavailable(.identityMismatch) }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try access.validate()
            if write {
                let readOnly = try access.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
                guard access.writable, readOnly != true else { throw SteamStorageError.unavailable(.readOnly) }
            }
        }.value
        try Task.checkCancellation()
        if access.library != catalog.external { try catalog.transaction(file: Self.file) { try $0.register(access.library) } }
        return access
    }

    /// The lease for one operation (nil for the iPad's own library). Keep it alive (`keepAlive()` in a defer) across every await that uses its root.
    func accessForOperation(libraryID: String, write: Bool) async throws -> SteamExternalLease? {
        _ = try library(libraryID)
        if libraryID == SteamStorageLibrary.internalID { return nil }
        do {
            let access = try await acquire(libraryID: libraryID, write: write)
            availability = access.writable ? .available : .readOnly
            problem = nil
            return access
        } catch {
            if error is CancellationError { throw error }
            liveAccess = nil
            availability = SteamExternalAccess.availability(for: error)
            problem = SteamStorageError.unavailable(availability).localizedDescription
            throw SteamStorageError.unavailable(availability)
        }
    }

    // MARK: A Wine session on the SSD

    /// Taken before any E: mapping or launch check and kept until every Wine process has stopped.
    func holdSession(libraryID: String) async throws {
        if libraryID == SteamStorageLibrary.internalID { return }
        sessionAccess = try await acquire(libraryID: libraryID, write: true)
        if sessionTimer == nil {
            sawSession = false
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if wine_process_is_running() != 0 || wineserver_is_running() != 0 { self.sawSession = true }
                    else if self.sawSession { self.releaseSession() }
                }
            }
        }
    }

    /// Maps the SSD for the next session: `dosdevices/e:` and `drive_c/MadeiraExternalLibrary` both point at the folder (Valve's client rejects E: as unmounted,
    /// C: works), the folder is registered as a Steam library in `libraryfolders.vdf`, and the native bridge learns the library's identity.
    func prepareSession(libraryID: String) async throws {
        guard libraryID != SteamStorageLibrary.internalID else { return }
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
            LogStore.shared.log("[storage] the SSD cannot be mapped: Wine or its server is still running", level: .error)
            throw SteamStorageError.sessionRunning
        }
        /// Says which step failed, since several of them end in the same message.
        func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
            do { return try body() }
            catch { LogStore.shared.log("[storage] mapping step \u{201C}\(name)\u{201D} failed: \(ErrorText.plain(error))", level: .error); throw error }
        }
        try await holdSession(libraryID: libraryID)
        do {
            guard let access = sessionAccess else { throw SteamStorageError.invalidRecord }
            try access.validate()
            let fm = FileManager.default, prefix = MadeiraDock.prefix
            madeira_seed_prefix_if_needed(prefix.path)
            let owner = try SteamStoragePath.native("madeira-external-owner", root: prefix)
            let recordedOwner = try? String(contentsOf: owner, encoding: .utf8)
            let devices = try SteamStoragePath.native("dosdevices", root: prefix)
            try fm.createDirectory(at: devices, withIntermediateDirectories: true)
            try step("E: link") {
                try SteamStorageMapping.replace(devices.appendingPathComponent("e:"), root: access.root, libraryID: libraryID, ownerID: recordedOwner, claimsExistingSymlink: true)
            }
            try step("C:\\MadeiraExternalLibrary link") {
                try SteamStorageMapping.replace(MadeiraDock.drive.appendingPathComponent(SteamStoragePath.externalAlias), root: access.root,
                                                libraryID: libraryID, ownerID: recordedOwner, claimsExistingSymlink: true)
            }
            let apps = Dictionary(uniqueKeysWithValues: catalog.assignments.values.filter { $0.location.libraryID == libraryID && $0.installed }
                .map { ($0.appID, $0.bytes ?? 0) })
            try step("Steam library list") {
                try SteamLibraryFolders.register(externalID: libraryID, name: access.library.name, apps: apps, drive: MadeiraDock.drive, verifiedAliasOwnerID: recordedOwner)
            }
            try Data(libraryID.utf8).write(to: owner, options: .atomic)
            setenv("MADEIRA_EXTERNAL_LIBRARY_ID", libraryID, 1)
            LogStore.shared.log("[storage] SSD library \(access.library.name) mapped for this session")
        } catch {
            releaseSession(force: true)
            throw error
        }
    }

    /// The C:\MadeiraExternalLibrary alias, made right after a download while its lease is held, so the library entry of a new game (a C:\ path through that alias)
    /// resolves before the first session. A conflicting link or folder is left alone (the session's own mapping refuses it with a message).
    func ensureAlias(for access: SteamExternalLease) {
        let ownerFile = try? SteamStoragePath.native("madeira-external-owner", root: MadeiraDock.prefix)
        let owner = ownerFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        do {
            try SteamStorageMapping.replace(MadeiraDock.drive.appendingPathComponent(SteamStoragePath.externalAlias), root: access.root,
                                            libraryID: access.library.id, ownerID: owner, claimsExistingSymlink: true)
            if let ownerFile { try? Data(access.library.id.utf8).write(to: ownerFile, options: .atomic) }    // so the next session knows the link is this library's
        } catch { SteamLog.event("[steam-storage] alias not created: \(ErrorText.plain(error))") }
    }

    func releaseSession(force: Bool = false) {
        if !force, wine_process_is_running() != 0 || wineserver_is_running() != 0 { return }
        sessionAccess = nil
        sessionTimer?.invalidate(); sessionTimer = nil
        unsetenv("MADEIRA_EXTERNAL_LIBRARY_ID")
    }

    // MARK: Is it there

    /// Writes nothing; says whether the registered folder can be reached now, and brings the games list up to date when it can.
    func check() async {
        guard !checking, let external = catalog.external else { return }
        checking = true
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            checking = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            SteamLog.event("[steam-storage] check state=\(availability.rawValue) elapsed-ms=\(elapsed)")
        }
        do {
            _ = try await perform(libraryID: external.id, write: true) { _ in true }
            await scan()
            NotificationCenter.default.post(name: Self.reconnected, object: external.id)
        } catch { }
    }

    /// Unavailable text for a game's page and for Play.
    func unavailableText() -> String {
        problem ?? SteamStorageError.unavailable(availability == .available ? .disconnected : availability).localizedDescription
    }
}

/// In-place folder selection. Only the selected directory receives scoped access.
struct ExternalFolderPicker: UIViewControllerRepresentable {
    let completion: (Result<URL, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        SteamLog.event("[steam-storage] folder picker opened")
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.presentationController?.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(_ completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            SteamLog.event("[steam-storage] folder picker answered with \(urls.count) item(s)")
            if let url = urls.first { completion(.success(url)) } else { completion(.failure(CancellationError())) }
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
            SteamLog.event("[steam-storage] folder picker answered (single-item form)")
            completion(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            SteamLog.event("[steam-storage] folder picker cancelled")
            completion(.failure(CancellationError()))
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            SteamLog.event("[steam-storage] folder picker dismissed by swipe")
        }
    }
}


/// Opens the system folder picker straight from UIKit, on top of whatever is showing, and keeps its delegate alive itself. The picker shown inside a SwiftUI `.sheet` never answered when Open
/// was pressed on an external drive (the log said "folder picker opened" and nothing more); this presents it the way UIKit means it to be (whether that fixes it is read from the log: \"answered with 1 item(s)\").
@MainActor
enum ExternalFolderPresenter {
    private static var handler: Handler?

    static func present(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard handler == nil else { SteamLog.event("[steam-storage] folder picker is already open"); return }
        guard let top = topController() else {
            SteamLog.event("[steam-storage] folder picker could not be opened: no screen to show it on")
            completion(.failure(CancellationError()))
            return
        }
        let delegate = Handler { result in
            ExternalFolderPresenter.handler = nil
            completion(result)
        }
        handler = delegate
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = delegate
        picker.presentationController?.delegate = delegate
        SteamLog.event("[steam-storage] folder picker opened (from UIKit, over \(String(describing: type(of: top))))")
        top.present(picker, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        let windows = scenes.flatMap(\.windows).filter { !$0.isHidden && !($0 is PassthroughWindow) }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first, var top = window.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private final class Handler: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(_ completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            SteamLog.event("[steam-storage] folder picker answered with \(urls.count) item(s)")
            if let url = urls.first { completion(.success(url)) } else { completion(.failure(CancellationError())) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            SteamLog.event("[steam-storage] folder picker cancelled")
            completion(.failure(CancellationError()))
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            SteamLog.event("[steam-storage] folder picker dismissed by swipe")
            completion(.failure(CancellationError()))
        }
    }
}
