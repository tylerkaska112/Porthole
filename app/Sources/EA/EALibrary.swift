// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// The EA app's library in Porthole: the signed-in account and the PC games it owns. The protocol (sign-in with EA's own login page, the account's games, builds, download
// addresses, licences) is Madeira's SwiftEA code from willfaust/Madeira (GPL-3.0-or-later, Madeira Converter Exception), which follows Maxima (GPL-3.0); this file, the
// installer, the screens and the launch hooks are written for Porthole after Madeira's EALibrary.swift and EAGames.swift. Nothing here logs a token or a code.

import Foundation
import Combine
import CryptoKit

/// An installed EA game, as recorded by Porthole.
struct EAInstalledGame: Codable, Sendable {
    var offerID: String
    var title: String
    /// Relative to drive_c, forward slashes: "Program Files/EA Games/Mass Effect".
    var folder: String
    var buildID: String
    var version: String
    /// The id a licence names; empty when neither the catalog nor the build said.
    var contentID: String
    var multiplayerID: String
    /// The program, relative to `folder`, forward slashes.
    var launchExe: String
    var arguments: String
    var installBytes: Int64
    /// The registry key (under HKLM, backslashes) and value the game's manifest named for its install folder, which Porthole writes so the game finds its files.
    var registryKey: String?
    var registryValue: String?
    /// The cover the game had when it was installed.
    var cover: URL?

    var programPath: String { folder + "/" + launchExe }
    var windowsInstallPath: String { "C:\\" + folder.replacingOccurrences(of: "/", with: "\\") }
    var windowsProgram: String { "C:\\" + programPath.replacingOccurrences(of: "/", with: "\\") }
}

extension EAOwnedGame {
    /// The picture for a card: the wide image when EA has one.
    var art: URL? { wide ?? cover }
}

/// The signed-in EA account (the tokens are EAAPI's, in a device-only Keychain item).
@MainActor final class EAAuth: ObservableObject {
    static let shared = EAAuth()

    @Published private(set) var signedIn = false
    @Published private(set) var accountName: String?

    private init() { reload() }

    /// Reads the stored account (no network).
    func reload() {
        if let session = EAAPI.shared.account() {
            signedIn = true
            accountName = session.displayName.isEmpty ? "EA account" : session.displayName
        } else {
            signedIn = false; accountName = nil
        }
    }

    /// EA's login page for this device (a fresh challenge each time): the device's own graphics card, no AVX.
    func loginURL() -> URL {
        EAAPI.shared.loginURL(profile: EAHardware.profile(drive: AppModel.driveC, gpuVendor: 0x106b, gpuDevice: 0x0001, avx: false))
    }

    /// Trades the code of EA's login page for the account's tokens, then loads the library.
    func signIn(code: String) async throws {
        _ = try await EAAPI.shared.signIn(authorizationCode: code)
        reload()
        EALibrary.shared.clear()
        EALibrary.shared.refresh()
    }

    /// Removes the tokens and the cached list. Installed games stay, but an EA game needs the sign-in to start: its licence and the EA app's environment come from the account.
    func signOut() {
        EAInstaller.shared.pauseAll()
        EAAPI.shared.signOut()
        EALibrary.shared.clear()
        reload()
    }

    /// EA refused the saved tokens: the person has to sign in again.
    func tokensRejected() { signedIn = false; accountName = nil }
}

/// The games the account owns, with their pictures, kept on disk so the list shows at once.
@MainActor final class EALibrary: ObservableObject {
    static let shared = EALibrary()

    @Published private(set) var games: [EAOwnedGame] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    /// A game's download and installed size (the live build's archive), or why EA gave none.
    enum Size: Equatable { case known(download: Int64, install: Int64), unavailable(String) }
    @Published private(set) var sizes: [String: Size] = [:]
    /// The newest build seen for each installed game (checked when its sheet opens).
    @Published private(set) var latestBuild: [String: String] = [:]

    private var lastRefresh: Date?
    private let downloader = EADownloader()

    private struct Cache: Codable { var version: Int; var account: String; var games: [EAOwnedGame] }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ea-library.json")
    }
    private static func accountKey(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }

    private init() {
        if let session = EAAPI.shared.account(), let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == 1, cache.account == Self.accountKey(session.userID) {
            games = cache.games
        }
    }

    func game(_ id: String) -> EAOwnedGame? { games.first { $0.id == id } }

    func refreshIfStale() {
        guard EAAuth.shared.signedIn else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        refresh()
    }

    func clear() {
        games = []; error = nil; lastRefresh = nil; sizes = [:]; latestBuild = [:]
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    func refresh() {
        guard !isLoading, EAAuth.shared.signedIn else { return }
        guard NetworkStatus.shared.isOnline else { LogStore.shared.log("[ea-library] offline: keeping the saved list"); return }
        isLoading = true
        lastRefresh = Date()
        error = nil
        Task {
            do {
                var list = try await EAAPI.shared.ownedGames()
                let known = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                // Artwork for games not seen before; at most eight lookups at once.
                let wanted = list.indices.filter { known[list[$0].id]?.cover == nil }
                var art: [String: (URL?, URL?)] = [:]
                await withTaskGroup(of: (String, (URL?, URL?)).self) { group in
                    var next = 0
                    func add() {
                        guard next < wanted.count else { return }
                        let game = list[wanted[next]]; next += 1
                        group.addTask { (game.id, await EAAPI.shared.images(slug: game.slug)) }
                    }
                    for _ in 0..<8 { add() }
                    while let (id, images) = await group.next() { art[id] = images; add() }
                }
                for index in list.indices {
                    let id = list[index].id
                    list[index].cover = art[id]?.0 ?? known[id]?.cover
                    list[index].wide = art[id]?.1 ?? known[id]?.wide
                }
                games = list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                if let account = EAAPI.shared.account() {
                    let cache = Cache(version: 1, account: Self.accountKey(account.userID), games: games)
                    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? JSONEncoder().encode(cache).write(to: Self.cacheURL, options: .atomic)
                }
                LogStore.shared.log("[ea-library] owned games=\(games.count)")
            } catch {
                Self.note(error, context: "library")
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Logs a failure by its reason only (never a token) and notices a rejected sign-in.
    nonisolated static func note(_ error: Error, context: String) {
        let reason = (error as? EAAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        Task { @MainActor in
            if case EAAPIError.signedOut = error { EAAuth.shared.tokensRejected() }
            LogStore.shared.log("[ea-library] \(context) failed reason=\(reason)", level: .error)
        }
    }

    /// A game's sizes from its live build's archive (the sheet shows them before an install); once per app run.
    func loadSize(_ id: String) async {
        guard EAAuth.shared.signedIn, sizes[id] == nil else { return }
        do {
            let build = try await EAAPI.shared.liveBuild(offerID: id)
            let url = try await EAAPI.shared.downloadURL(offerID: id, buildID: build.buildID)
            let archive = try await downloader.archive(url)
            sizes[id] = .known(download: archive.compressedBytes, install: archive.installBytes)
        } catch {
            sizes[id] = .unavailable((error as? EAAPIError)?.errorDescription ?? "EA did not say how large this game is.")
            Self.note(error, context: "size id=\(id)")
        }
    }

    /// Notes the newest build, so the sheet of an installed game can offer Update when it differs.
    func checkForUpdate(_ id: String) async {
        guard EAAuth.shared.signedIn, EAInstaller.shared.installed[id] != nil, latestBuild[id] == nil else { return }
        if let build = try? await EAAPI.shared.liveBuild(offerID: id) { latestBuild[id] = build.buildID }
    }

    func noteLatest(build: String, for id: String) { latestBuild[id] = build }
}
