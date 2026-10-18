// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import LauncherCore

/// What went wrong, in words for the person.
struct SteamFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The signed-in Steam account and the one connection to Steam's servers, as the rest of the app uses them. Everything runs on the main actor, which is
/// where the protocol code expects to be called.
@MainActor
final class SteamService {
    static let shared = SteamService()

    private let api = SteamAPI(transport: URLSessionSteamTransport())
    private let account: SteamAccount
    private var backend: SteamCMBackend?
    /// While Valve's own client is signed in for a Dock launch this connection must stay closed: one sign-in of the account at a time.
    private var suspended = false

    init() {
        // The Steam code reports into the app's log (from any thread).
        SteamLog.sink = { text in DispatchQueue.main.async { LogStore.shared.log(text) } }
        account = SteamAccount(api: api, store: KeychainSteamSessionStore(service: BuildIdentity.keychainService + ".steam"))
    }

    // MARK: Who is signed in

    var isSignedIn: Bool { account.isSignedIn }
    var accountName: String? { account.displayName }
    func makeAuthenticator() -> SteamAuthenticator { SteamAuthenticator(api: api) }

    /// Keeps a finished sign-in.
    func adopt(_ session: SteamAccountSession) {
        closeConnection()
        account.adopt(session)
        suspended = false
        NotificationCenter.default.post(name: SteamSignIn.didChange, object: nil)
    }

    func signOut() {
        closeConnection()
        account.signOut()
        NotificationCenter.default.post(name: SteamSignIn.didChange, object: nil)
    }


    /// What Valve's client needs to sign in the same account for a Dock launch.
    func credentialsForDock() -> (accountName: String, refreshToken: String)? {
        guard let session = account.session, !session.refreshToken.isEmpty else { return nil }
        return (session.accountName, session.refreshToken)
    }

    // MARK: The connection

    private func connection() throws -> SteamCMBackend {
        guard !suspended else { throw SteamFailure(message: "Steam is being used by the game right now. Try again when it has closed.") }
        if let backend { return backend }
        guard let session = account.session, !session.refreshToken.isEmpty else { throw SteamFailure(message: "Sign in to Steam first.") }
        let made = SteamCMBackend(logOn: .account(name: session.accountName, refreshToken: session.refreshToken, steamID: session.steamID))
        backend = made
        return made
    }

    private func closeConnection() { backend?.close(); backend = nil }

    /// Steam no longer accepts the saved sign-in (the password changed, the session was revoked): sign out so the person signs in again.
    private func checkSessionOver(_ error: Error) {
        let text = (error as? SteamContentError)?.message ?? ""
        if text.contains("Sign in for downloads again") || text.contains("sign-in for downloads has expired") { signOut() }
    }

    /// Games and downloads leave Steam's servers alone while a Dock launch has Valve's client signed in.
    /// A game is running in Steam's client, which holds the account's one online sign-in: this app's own connection is closed until it ends.
    var connectionHeld: Bool { suspended }
    func suspend() async { suspended = true; closeConnection() }
    func resume() { suspended = false }
    func logoff() { closeConnection() }

    // MARK: Library

    func ownedApps() async throws -> [SteamAppInfo] {
        let backend = try connection()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                backend.ownedApps { continuation.resume(with: $0.mapError { $0 as Error }) }
            }
        } catch { checkSessionOver(error); throw error }
    }

    func appInfo(_ appID: Int) async throws -> SteamAppInfo {
        let backend = try connection()
        return try await withCheckedThrowingContinuation { continuation in
            backend.appInfo(appID) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    // MARK: Versions and DLC

    /// What the account can choose for a game: its versions (branches) and the DLC that has files of its own, with whether the account owns each.
    func gameDetails(appID: Int) async throws -> SteamGameDetails {
        let backend = try connection()
        let info: SteamAppInfo = try await withCheckedThrowingContinuation { continuation in
            backend.appInfo(appID) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
        var dlc: [SteamDLC] = []
        for dlcApp in info.dlcApps {
            let depots = info.depots.filter { $0.dlcApp == dlcApp }
            guard !depots.isEmpty else { continue }
            let name: String = (try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SteamAppInfo, Error>) in
                backend.appInfo(dlcApp) { continuation.resume(with: $0.mapError { $0 as Error }) }
            })?.name ?? "DLC \(dlcApp)"
            // Owning the DLC shows as Steam handing out the key of its first depot.
            var owned: Bool?
            if let first = depots.first {
                owned = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                    backend.depotKey(app: appID, depot: first.id) { result in
                        switch result {
                        case .success: continuation.resume(returning: true)
                        case .failure(let error): continuation.resume(returning: error.notOwned ? false : nil)
                        }
                    }
                }
            }
            let sizes = SteamDepotPlanner.sizes(app: SteamAppInfo(appid: appID, name: info.name, installDirectory: nil, buildID: nil, depots: depots),
                                                selection: SteamInstallSelection(dlc: .all))
            dlc.append(SteamDLC(appid: dlcApp, name: name, owned: owned, downloadBytes: sizes.download, diskBytes: sizes.disk))
        }
        return SteamGameDetails(info: info, dlc: dlc.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    /// Asks Steam what a beta password opens. Throws with Steam's reason when it opens nothing.
    func betaPassword(appID: Int, password: String) async throws -> [SteamBetaPassword] {
        let backend = try connection()
        return try await withCheckedThrowingContinuation { continuation in
            backend.checkBetaPassword(app: appID, password: password) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    // MARK: Achievements

    /// The game's achievements with this account's unlock times, plus how common each is when Steam's public numbers can be reached.
    func achievements(appID: Int) async throws -> [SteamAchievement] {
        let backend = try connection()
        guard let steamID = account.session.flatMap({ UInt64($0.steamID) }) else { throw SteamFailure(message: "Sign in to Steam first.") }
        let reply: SteamUserStatsReply = try await withCheckedThrowingContinuation { continuation in
            backend.userStats(app: appID, steamID: steamID) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
        var list = SteamAchievementParser.achievements(schema: reply.schema, blocks: reply.blocks)
        if let first = list.first { SteamLog.event("achievements: app \(appID) has \(list.count); first picture '\(first.icon ?? "-")' / '\(first.iconGray ?? "-")' -> \(first.iconURL(app: appID)?.absoluteString ?? "none")") }
        else { SteamLog.event("achievements: app \(appID) schema \(reply.schema.count) bytes, \(reply.blocks.count) block(s), none read") }
        if !list.isEmpty, let url = URL(string: "\(SteamAPI.host)/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/?gameid=\(appID)&format=json") {
            let data: Data? = await withCheckedContinuation { continuation in
                backend.fetch(url) { continuation.resume(returning: try? $0.get()) }
            }
            let shares = data.map(SteamAchievementParser.percentages) ?? [:]
            for index in list.indices { list[index].percent = shares[list[index].apiName] }
        }
        return list
    }

    // MARK: Friends

    /// The signed-in person's friends with their state (read only). `hasState` is false when only names and pictures could be had.
    func friends() async throws -> (friends: [SteamFriend], hasState: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            account.loadFriends { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    // MARK: Workshop

    /// The account number inside the signed-in Steam id, as Steam's records write it.
    var accountNumber: String { account.session.flatMap { UInt64($0.steamID) }.map { String($0 & 0xFFFFFFFF) } ?? "0" }

    /// A page of a game's Workshop items (ranked, or a text search).
    func workshopBrowse(appID: Int, sort: SteamWorkshopSort, search: String, page: Int) async throws -> (items: [SteamWorkshopItem], total: Int) {
        try await withCheckedThrowingContinuation { continuation in
            account.workshopQuery(appID: appID, sort: sort, search: search, page: page) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    /// The items this account is subscribed to for a game, with the manifest of each (Steam's own client asks the same question).
    func workshopSubscribed(appID: Int) async throws -> [SteamSubscribedFile] {
        let backend = try connection()
        return try await withCheckedThrowingContinuation { continuation in
            backend.subscribedWorkshop(app: appID) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    func workshopItems(ids: [UInt64], appID: Int) async throws -> [SteamWorkshopItem] {
        var found: [SteamWorkshopItem] = []
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            found += try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SteamWorkshopItem], Error>) in
                account.workshopDetails(ids: chunk, appID: appID) { continuation.resume(with: $0.mapError { $0 as Error }) }
            }
        }
        return found
    }

    func workshopSubscribe(id: UInt64, appID: Int, subscribe: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            account.workshopSubscribe(id: id, appID: appID, subscribe: subscribe) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    /// The depot a game keeps its Workshop items in.
    func workshopDepot(appID: Int) async throws -> Int {
        let backend = try connection()
        let info: SteamAppInfo = try await withCheckedThrowingContinuation { continuation in
            backend.appInfo(appID) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
        return info.workshopDepot ?? appID
    }

    /// Downloads one Workshop item into the game's `steamapps/workshop` folder and records it there. Cancelling the task stops the transfer.
    func installWorkshopItem(appID: Int, name: String, depot: Int, item: UInt64, manifest: UInt64, updated: Date?, steamApps: URL,
                             progress: @escaping @MainActor (SteamDownloadProgress) -> Void) async throws {
        let backend = try connection()
        let installer = SteamInstaller(appid: appID, name: name, steamApps: steamApps, backend: backend)
        installer.ownerSteamID = account.session?.steamID
        installer.workshop = SteamInstaller.WorkshopTarget(item: item, depot: depot, manifest: manifest, updated: updated)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false
                func finish(_ result: Result<Void, Error>) {
                    guard !finished else { return }
                    finished = true
                    installer.onState = nil
                    continuation.resume(with: result)
                }
                installer.onState = { state in
                    switch state {
                    case .idle: break
                    case .preparing: progress(SteamDownloadProgress())
                    case .downloading(let p): progress(p)
                    case .finished: finish(.success(()))
                    case .failed(let message): finish(.failure(SteamFailure(message: message)))
                    case .cancelled: finish(.failure(CancellationError()))
                    }
                }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                installer.start()
            }
        } onCancel: {
            Task { @MainActor in installer.cancel() }
        }
    }

    /// Steam serves user content from two names for the same files; some networks drop connections to one of them. Tries each name a couple of times.
    static func downloadUGC(_ url: URL) async throws -> (URL, URLResponse) {
        var names = [url]
        if url.host == "cdn.steamusercontent.com", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.host = "steamusercontent-a.akamaihd.net"
            if let other = parts.url { names.append(other) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var lastError: Error = SteamFailure(message: "The item's file could not be downloaded.")
        for attempt in 0..<8 {
            let name = names[attempt % names.count]
            do {
                let result = try await session.download(from: name, delegate: UGCMetricsLogger())
                if (result.1 as? HTTPURLResponse)?.statusCode == 200 || attempt == 7 { return result }
                lastError = SteamFailure(message: "The item's file could not be downloaded (HTTP \((result.1 as? HTTPURLResponse)?.statusCode ?? 0)).")
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                SteamLog.event("[workshop] download from \(name.host ?? "?") failed (\(SteamSignIn.reason(error))), attempt \(attempt + 1) of 8")
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        throw lastError
    }

    /// An item that is one plain file served from a web address: downloaded into its folder under the name the item gives it.
    func installWorkshopFile(appID: Int, item: UInt64, url: URL, filename: String?, updated: Date?, steamApps: URL, content: UInt64 = 0,
                             creator: UInt64? = nil, creatorApp: Int? = nil, steamRoot: URL? = nil) async throws {
        let (temporary, response) = try await Self.downloadUGC(url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw SteamFailure(message: "The item's file could not be downloaded (HTTP \(status)).") }
        let folder = SteamWorkshopFiles.itemFolder(appID: appID, item: item, steamApps: steamApps)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parts = (filename ?? url.lastPathComponent).split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        let target = parts.isEmpty ? folder.appendingPathComponent("item") : parts.reduce(folder) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        let account = (account.session.flatMap { UInt64($0.steamID) }).map { String($0 & 0xFFFFFFFF) } ?? "0"
        SteamWorkshopFiles.record(.init(id: item, size: SteamWorkshopFiles.folderSize(folder), manifest: content, updated: updated, ugcHandle: content), appID: appID, steamApps: steamApps, subscribedBy: account)
        // Also where Valve's client keeps a finished download, so the game finds the map even when the client cannot reach the content server itself.
        if let steamRoot, let creator, content != 0, case let relative = parts.isEmpty ? "item" : parts.joined(separator: "/") {
            let ok = SteamWorkshopFiles.seedReferenced(file: target, filename: relative, handle: content, appID: creatorApp ?? appID, creator: creator, steamRoot: steamRoot, account: account)
            SteamLog.event("[workshop] item \(item): Valve's finished-download cache " + (ok ? "filled" : "not filled"))
        }
    }

    // MARK: Steam Cloud (download only)

    /// Before a game is started through Steam: brings this account's cloud files for it onto the device (see SteamCloud.swift). Reads from Steam only.
    func cloudDownload(appID: Int, driveC: URL, installFolder: URL?, progress: ((Int, Int, String) -> Void)? = nil) async throws -> SteamCloudReport {
        let backend = try connection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backend.start { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
        return try await SteamCloudSync.downloadMissing(appID: appID, transport: SteamCMCloudTransport(cm: backend.cm), driveC: driveC, installFolder: installFolder, progress: progress)
    }

    // MARK: Downloads

    /// Downloads and records one game. Cancelling the task stops the transfer and keeps what is done, so the next try continues.
    func install(appID: Int, name: String, steamApps: URL, selection: SteamInstallSelection = SteamInstallSelection(),
                 progress: @escaping @MainActor (SteamDownloadProgress) -> Void) async throws -> (folder: URL, info: SteamAppInfo) {
        let backend = try connection()
        let installer = SteamInstaller(appid: appID, name: name, steamApps: steamApps, backend: backend)
        installer.ownerSteamID = account.session?.steamID
        installer.selection = selection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, SteamAppInfo), Error>) in
                var finished = false
                func finish(_ result: Result<(URL, SteamAppInfo), Error>) {
                    guard !finished else { return }
                    finished = true
                    installer.onState = nil
                    continuation.resume(with: result)
                }
                installer.onState = { state in
                    switch state {
                    case .idle: break
                    case .preparing: progress(SteamDownloadProgress())
                    case .downloading(let p): progress(p)
                    case .finished:
                        if let info = installer.installInfo { finish(.success((installer.gameFolder, info))) }
                        else { finish(.failure(SteamFailure(message: "The download finished but Steam's information about the game was lost."))) }
                    case .failed(let message): finish(.failure(SteamFailure(message: message)))
                    case .cancelled: finish(.failure(CancellationError()))
                    }
                }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                installer.start()
            }
        } onCancel: {
            Task { @MainActor in installer.cancel() }
        }
    }
}

/// Writes where a user-content download actually went (address family, protocol, how long each step took), so a network that drops it can be told apart from a bug.
private final class UGCMetricsLogger: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for t in metrics.transactionMetrics {
            func ms(_ a: Date?, _ b: Date?) -> String { a != nil && b != nil ? String(format: "%.0f", b!.timeIntervalSince(a!) * 1000) : "-" }
            let remote = t.remoteAddress.map { "\($0):\(t.remotePort ?? 0)" } ?? "?"
            SteamLog.event("[workshop-net] \(t.request.url?.host ?? "?") -> \(remote) \(t.networkProtocolName ?? "?") cellular=\(t.isCellular) vpn-or-proxy=\(t.isProxyConnection) reused=\(t.isReusedConnection) "
                           + "dns \(ms(t.domainLookupStartDate, t.domainLookupEndDate)) ms, connect \(ms(t.connectStartDate, t.connectEndDate)) ms, tls \(ms(t.secureConnectionStartDate, t.secureConnectionEndDate)) ms, "
                           + "first byte \(ms(t.requestStartDate, t.responseStartDate)) ms, body \(ms(t.responseStartDate, t.responseEndDate)) ms, bytes \(t.countOfResponseBodyBytesReceived)")
        }
    }
}

/// One piece of DLC with files of its own.
struct SteamDLC: Identifiable, Equatable {
    var appid: Int
    var name: String
    /// nil when Steam did not say (the question failed for another reason).
    var owned: Bool?
    var downloadBytes: UInt64
    var diskBytes: UInt64
    var id: Int { appid }
}

/// What a game's page needs to offer versions and DLC.
struct SteamGameDetails: Equatable {
    var info: SteamAppInfo
    var dlc: [SteamDLC]
}
