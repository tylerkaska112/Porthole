// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import SwiftUI

/// Notices an external drive and offers to look for Steam games on it; says what a scan found.
///
/// iOS never lets an app browse a drive on its own: the person picks the folder once in the Files picker, and that pick is what gives access. So the flow is: a drive appears,
/// Porthole asks, the person agrees, the picker opens, the games found are added. A drive already picked earlier is simply read again whenever the app comes forward,
/// and games that appeared on it are announced. Whether iOS lists a new drive to an app at all is not known (it is logged as `[drive]` lines to find out).
@MainActor final class DriveWatcher: ObservableObject {
    static let shared = DriveWatcher()

    struct Offer: Equatable { let name: String; let key: String }
    struct Report: Equatable { let title: String; let message: String }

    /// A drive Porthole noticed and has not been told about yet.
    @Published var offer: Offer?
    /// The result of a scan, shown until dismissed.
    @Published var report: Report?
    /// The Home library the games are put in (set when the app starts).
    weak var model: AppModel?
    private var working = false
    private var pollTask: Task<Void, Never>?
    private var lastVolumeLog = ""
    private static let declinedKey = "f4.driveOfferDeclined"

    private var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.declinedKey) }
    }

    /// Called when the app opens and every time it comes back to the front.
    func foreground() async {
        guard !working, MadeiraDock.enabled else { return }
        let storage = ExternalLibrary.shared
        if storage.external != nil {
            // The drive picked before: read it again, and put games that have no tile in the library yet there.
            await storage.check()
            if let name = storage.external?.name {
                let made = await putInLibrary()
                if made.added > 0 { report = Self.report(driveName: name, installed: storage.installedExternalIDs.count, made: made) }
            }
            return
        }
        guard offer == nil, report == nil else { return }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeUUIDStringKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var candidates: [Offer] = []
        var seen: [String] = []
        for url in volumes {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = v?.volumeName ?? url.lastPathComponent
            seen.append("\"\(name)\" internal=\(v?.volumeIsInternal.map(String.init(describing:)) ?? "?") root=\(v?.volumeIsRootFileSystem.map(String.init(describing:)) ?? "?") local=\(v?.volumeIsLocal.map(String.init(describing:)) ?? "?")")
            guard v?.volumeIsInternal == false, v?.volumeIsRootFileSystem != true, v?.volumeIsLocal != false else { continue }
            let key = v?.volumeUUIDString ?? name
            if !declined.contains(key) { candidates.append(Offer(name: name, key: key)) }
        }
        // Logged when the list changes, not on every look.
        let signature = seen.joined(separator: "; ")
        if signature != lastVolumeLog { lastVolumeLog = signature; SteamLog.event("[drive] volumes: \(signature.isEmpty ? "none" : signature)") }
        if let first = candidates.first { offer = first }
    }

    /// While the app is in front, looks at the drive every few seconds, so plugging it in or pulling it out shows in the library at once instead of at the next start.
    /// Does nothing while a game runs (the drive is in use and a popup would be in the way).
    func setActive(_ active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard active else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                await self?.poll()
            }
        }
    }

    private func poll() async {
        guard !working, MadeiraDock.enabled, wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        let storage = ExternalLibrary.shared
        guard storage.external != nil else { await foreground(); return }       // no drive picked yet: a newly connected one is offered
        guard !storage.checking else { return }
        func reachable() -> Bool { storage.availability == .available || storage.availability == .readOnly }
        let was = reachable()
        await storage.probe()
        if !was, reachable() { await foreground() }      // the drive came back: read it again and put what is new in the library
    }

    /// The person said yes: open the picker (iOS needs it to give access), then add what is found.
    func accept() {
        let drive = offer
        offer = nil
        guard !working else { return }
        ExternalFolderPresenter.present { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url): Task { await self.adopt(url, offerKey: drive?.key) }
            case .failure(let failure):
                if !(failure is CancellationError) { self.report = Report(title: "The drive could not be opened", message: ErrorText.plain(failure)) }
            }
        }
    }

    /// The person said not now: this drive is not offered again.
    func decline() {
        if let offer { declined.insert(offer.key) }
        offer = nil
    }

    /// Registers the picked folder, reads its games and shows what happened.
    func adopt(_ url: URL, offerKey: String? = nil) async {
        working = true
        defer { working = false }
        do {
            let result = try await ExternalLibrary.shared.adopt(picked: url)
            if let offerKey { declined.insert(offerKey) }
            let made = await putInLibrary()
            report = Self.report(driveName: result.driveName, installed: result.installed, made: made)
        } catch {
            SteamLog.event("[steam-storage] folder refused: \(ErrorText.plain(error))")
            report = Report(title: "The drive could not be used", message: ErrorText.plain(error))
        }
    }

    /// The popup text: what was found and what actually reached the library.
    private static func report(driveName: String, installed: Int, made: (added: Int, missing: Int)) -> Report {
        if made.added == 0, made.missing > 0 {
            return Report(title: "Found \(made.missing == 1 ? "1 game" : "\(made.missing) games") on \(driveName)",
                          message: "No program to run was found in its files, so nothing was added to your library. Use Add a game to pick the program yourself.")
        }
        let text = SteamLibraryFinder.summary(driveName: driveName, installed: installed, added: made.added)
        let extra = made.missing > 0 ? " \(made.missing == 1 ? "1 more has" : "\(made.missing) more have") no program to run; use Add a game for \(made.missing == 1 ? "it" : "them")." : ""
        return Report(title: text.title, message: text.message + extra)
    }

    private static let handledKey = "f4.driveGamesHandled"
    /// Games on the drive that already went through the library once (given a tile, or found to have one). A game whose tile the person removed is not put back.
    private var handled: Set<Int> {
        get { Set((UserDefaults.standard.array(forKey: Self.handledKey) as? [Int]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.handledKey) }
    }

    /// Puts the games installed on the drive in the Home library, as a finished download does (a scan only fills the storage catalog). A game that already has a tile, or
    /// had one put here before, is left alone. Returns how many got a tile, and how many had no program to run (those are tried again next time).
    private func putInLibrary() async -> (added: Int, missing: Int) {
        let storage = ExternalLibrary.shared
        guard let external = storage.external else { return (0, 0) }
        let ids = storage.installedExternalIDs.subtracting(handled).sorted()
        guard !ids.isEmpty else { return (0, 0) }
        var added = 0, missing = 0
        var done = handled
        let owned = SteamStore.shared.owned
        for id in ids {
            if let model, model.games.contains(where: { $0.dockAppID == id || $0.steamAppID == id }) { done.insert(id); continue }
            guard let record = storage.assignment(for: id), let folder = record.location.relativePath.split(separator: "/").last.map(String.init) else { continue }
            let game = owned.first { $0.id == id } ?? SteamStore.Owned(id: id, name: record.name, installDir: folder, buildID: record.buildID ?? 0, sizeBytes: 0, launches: [])
            let exe: String? = (try? await storage.perform(libraryID: external.id, write: false) { root -> String? in
                let dir = try SteamStoragePath.native("steamapps/common/" + folder, root: root)
                return SteamStore.windowsExecutable(for: game, folder: dir, external: true)
            }) ?? nil
            if let exe {
                SteamStore.shared.onInstalled?(game, exe)
                done.insert(id)
                added += 1
            } else {
                SteamLog.event("[steam-storage] no program found for app \(id) (\(record.name))")
                missing += 1
            }
        }
        handled = done
        SteamStore.shared.invalidateBuilds()
        SteamStore.shared.objectWillChange.send()
        SteamLog.event("[steam-storage] library: \(added) game(s) added, \(missing) without a program")
        return (added, missing)
    }
}
