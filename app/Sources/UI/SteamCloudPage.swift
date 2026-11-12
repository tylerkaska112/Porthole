// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The page a game's "Steam Cloud" door opens: bring this game's saves down from Steam, or send the ones changed on this device up. Both only run when the person taps, and only
/// while no game is running (the game's Steam client holds the account's one online sign-in then).
@MainActor
final class SteamCloudActions: ObservableObject {
    private static var all: [Int: SteamCloudActions] = [:]
    /// One per game, so the card on the game's page and the page it opens show the same state.
    static func forApp(_ appID: Int) -> SteamCloudActions {
        if let existing = all[appID] { return existing }
        let made = SteamCloudActions(); all[appID] = made; return made
    }

    @Published var preview: SteamCloudPreview?
    @Published var checking = false
    @Published var checkFailure: String?
    private var checkedAt = Date.distantPast
    @Published var busy = false
    @Published var progress = ""
    @Published var lines: [String] = []
    @Published var failure: String?

    /// The folder the game lives in, when it is on the device itself (a game on an SSD is not reachable from here; its "game folder" files are skipped).
    static func installFolder(appID: Int) -> URL? {
        guard let game = MadeiraDock.games(drive: AppModel.driveC).first(where: { $0.id == appID }), game.storageID == SteamStorageLibrary.internalID else { return nil }
        return SteamInstallPaths.common(drive: AppModel.driveC).appendingPathComponent(game.installDir, isDirectory: true)
    }

    /// Looks at both sides and lists what Upload and Download would do. Sends and writes nothing. `maxAge` skips the look when one was made that recently.
    func refresh(appID: Int, maxAge: TimeInterval = 0) {
        guard !busy, !checking, Date().timeIntervalSince(checkedAt) > maxAge, !SteamService.shared.connectionHeld else { return }
        checking = true; checkFailure = nil
        Task {
            do {
                preview = try await SteamService.shared.cloudPreview(appID: appID, driveC: AppModel.driveC, installFolder: Self.installFolder(appID: appID))
                checkedAt = Date()
            } catch { checkFailure = (error as? SteamContentError)?.message ?? SteamSignIn.message(error) }
            checking = false
        }
    }

    /// How many files wait, for the card's right edge; nil when nothing does.
    var cardCount: String? {
        guard let preview, !preview.isInStep else { return nil }
        return String(preview.toUpload.count + preview.toDownload.count + preview.conflicts.count)
    }

    /// The short line the card on the game's page shows.
    var cardLine: String {
        if checking && preview == nil { return "Checking your saves\u{2026}" }
        if let preview { return preview.summary }
        return checkFailure == nil ? "Compare this device with Steam" : "Tap to try again"
    }

    func download(appID: Int) {
        run(appID, "Looking at your saves on Steam\u{2026}") { [self] in
            let report = try await SteamService.shared.cloudDownload(appID: appID, driveC: AppModel.driveC, installFolder: Self.installFolder(appID: appID)) { done, total, name in
                Task { @MainActor in self.progress = "\(name) (\(done) of \(total))" }
            }
            var out: [String] = []
            out.append(report.downloaded.isEmpty ? "Nothing new to download." : "Downloaded \(report.downloaded.count) file\(report.downloaded.count == 1 ? "" : "s").")
            if report.upToDate > 0 { out.append("\(report.upToDate) already the same here.") }
            if !report.keptNewerLocal.isEmpty { out.append("\(report.keptNewerLocal.count) file\(report.keptNewerLocal.count == 1 ? " is" : "s are") newer on this device and were kept. Upload sends them.") }
            if !report.conflicts.isEmpty { out.append("\(report.conflicts.count) file\(report.conflicts.count == 1 ? " was" : "s were") changed on this device and on Steam since the last sync, and were left as they are.") }
            if !report.failed.isEmpty { out.append("\(report.failed.count) could not be downloaded.") }
            return out
        }
    }

    func upload(appID: Int) {
        run(appID, "Looking at your saves on this device\u{2026}") { [self] in
            let report = try await SteamService.shared.cloudUpload(appID: appID, driveC: AppModel.driveC, installFolder: Self.installFolder(appID: appID), machineName: "Porthole (\(UIDevice.current.model))") { done, total, name in
                Task { @MainActor in self.progress = "\(name) (\(done) of \(total))" }
            }
            var out: [String] = []
            if !report.uploaded.isEmpty { out.append("Uploaded \(report.uploaded.count) file\(report.uploaded.count == 1 ? "" : "s") to Steam Cloud.") }
            else if report.failed.isEmpty && report.conflicts.isEmpty { out.append("Nothing to upload: Steam already has what is on this device.") }
            if !report.cloudNewer.isEmpty { out.append("\(report.cloudNewer.count) file\(report.cloudNewer.count == 1 ? " is" : "s are") newer on Steam. Download brings \(report.cloudNewer.count == 1 ? "it" : "them") here.") }
            if !report.conflicts.isEmpty { out.append("\(report.conflicts.count) file\(report.conflicts.count == 1 ? " was" : "s were") changed here and on Steam since the last sync. Nothing was sent or replaced for \(report.conflicts.count == 1 ? "it" : "them"); both copies are as they were.") }
            if !report.failed.isEmpty { out.append("\(report.failed.count) could not be uploaded. Try again in a moment.") }
            return out
        }
    }

    private func run(_ appID: Int, _ start: String, _ work: @escaping () async throws -> [String]) {
        guard !busy else { return }
        busy = true; failure = nil; lines = []; progress = start
        Task {
            do { lines = try await work() }
            catch { failure = (error as? SteamContentError)?.message ?? SteamSignIn.message(error) }
            busy = false; progress = ""
            refresh(appID: appID)
        }
    }
}

/// The row on a game's page that opens the Steam Cloud page. It shows what a sync would do, so the state of the saves is visible without opening anything.
struct SteamCloudCard: View {
    let appID: Int
    @ObservedObject var store: SteamStore
    let open: () -> Void
    @ObservedObject private var actions: SteamCloudActions

    init(appID: Int, store: SteamStore, open: @escaping () -> Void) {
        self.appID = appID; self.store = store; self.open = open
        _actions = ObservedObject(wrappedValue: SteamCloudActions.forApp(appID))
    }

    var body: some View {
        SettingsGroup(title: "Saves") {
            ActionRow(id: "gp-cloud", symbol: "icloud.fill", title: "Steam Cloud",
                      subtitle: actions.cardLine, detail: actions.cardCount,
                      info: "Keeps this game\u{2019}s saves the same here and in Steam Cloud, so your other devices see them too. Opens a page that lists what is waiting to be uploaded or downloaded.") { open() }
        }
        .task(id: store.signedIn) { if store.signedIn { actions.refresh(appID: appID, maxAge: 20) } }
    }
}

struct SteamCloudContent: View {
    let appID: Int
    let name: String
    @ObservedObject var store: SteamStore
    @ObservedObject private var actions: SteamCloudActions

    init(appID: Int, name: String, store: SteamStore) {
        self.appID = appID; self.name = name; self.store = store
        _actions = ObservedObject(wrappedValue: SteamCloudActions.forApp(appID))
    }

    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    @ViewBuilder private func fileList(_ title: String, _ items: [SteamCloudPreviewItem], note: String? = nil) -> some View {
        if !items.isEmpty {
            SettingsGroup(title: "\(title) (\(items.count))", note: note) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.prefix(25)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.display).font(.footnote).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Self.size(item.size)).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    if items.count > 25 { Text("and \(items.count - 25) more").font(.footnote).foregroundStyle(Theme.textDim) }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    var body: some View {
        let held = SteamService.shared.connectionHeld
        let preview = actions.preview
        let idle = !(actions.busy || actions.checking || held || !store.signedIn)
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Steam Cloud", note: "Compares \(name)\u{2019}s saves on this device with the ones in Steam Cloud. Nothing here runs by itself.") {
                if actions.checking && preview == nil {
                    HStack(spacing: 10) { ProgressView().tint(Theme.accent); Text("Checking your saves\u{2026}").font(.footnote).foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
                } else if let preview {
                    Text(preview.summary).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(preview.isInStep ? Theme.text : Theme.accent).padding(.horizontal, 6)
                }
                if let message = actions.checkFailure { Text(message).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            }
            fileList("To upload", preview?.toUpload ?? [], note: "On this device and not on Steam yet, or changed here.")
            fileList("To download", preview?.toDownload ?? [], note: "On Steam and missing or older here.")
            fileList("Changed on both sides", preview?.conflicts ?? [], note: "Changed here and on Steam since the last sync. Neither button touches these.")
            SettingsGroup {
                ActionRow(id: "cloud-up", symbol: "icloud.and.arrow.up", title: preview.map { $0.toUpload.isEmpty ? "Upload saves to Steam" : "Upload \($0.toUpload.count) file\($0.toUpload.count == 1 ? "" : "s") to Steam" } ?? "Upload saves to Steam",
                          subtitle: "Send what changed on this device",
                          info: "Sends this game\u{2019}s save files that changed on this device to your Steam Cloud, so your other devices can download them. Files that are the same are skipped, nothing on Steam is deleted, and a save that changed both here and on Steam since the last sync is left alone and reported.",
                          chevron: false) { actions.upload(appID: appID) }
                    .disabled(!idle || preview?.toUpload.isEmpty == true)
                ActionRow(id: "cloud-down", symbol: "icloud.and.arrow.down", title: preview.map { $0.toDownload.isEmpty ? "Download saves from Steam" : "Download \($0.toDownload.count) file\($0.toDownload.count == 1 ? "" : "s") from Steam" } ?? "Download saves from Steam",
                          subtitle: "Bring Steam\u{2019}s copies here",
                          info: "Downloads this game\u{2019}s saves from your Steam Cloud. A save that is newer on this device is kept. A different, older one is replaced and the old copy is kept next to it as .porthole-backup. This also happens by itself each time the game starts through Steam.",
                          chevron: false) { actions.download(appID: appID) }
                    .disabled(!idle || preview?.toDownload.isEmpty == true)
                ActionRow(id: "cloud-check", symbol: "arrow.clockwise", title: "Check again", subtitle: "Compare this device with Steam", chevron: false) { actions.refresh(appID: appID) }
                    .disabled(!idle)
            }
            if actions.busy {
                HStack(spacing: 10) { ProgressView().tint(Theme.accent); Text(actions.progress).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(2) }.padding(.horizontal, 6)
            }
            if let failure = actions.failure { Text(failure).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            ForEach(actions.lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            if held { Text("A game is running and holds your Steam sign-in. Close the game, then come back here.").font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            if !store.signedIn { Text("Sign in to Steam first (Stores).").font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            Text("Make sure the game has been closed first, so its last save is on disk.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        }
        .task { if store.signedIn { actions.refresh(appID: appID, maxAge: 5) } }
    }
}
