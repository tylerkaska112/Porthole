// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Adapted from Madeira's SwiftGOG/GOGGalaxy.swift (GPL-3.0-or-later, Copyright 2026 Madeira contributors; the Galaxy service itself is Playport's, see Galaxy/).
import Foundation

/// GOG Galaxy's game services for a GOG game's play: a game built with GOG's Galaxy SDK talks to GOG's client on 127.0.0.1:9977 for its sign-in, achievements, stats, leaderboards and
/// play time. While a GOG game runs, Porthole answers there itself (Galaxy/GalaxyListener and GalaxyService), with a token GOG mints for that game from Porthole's GOG sign-in. Some SDK
/// versions first ask Windows to start the "GalaxyCommunication" service, so the prefix gets a do-nothing service of that name (the bundled madeira-galaxy-service.exe).
/// Without a sign-in, without the game's Galaxy client, or when the port is taken, the game simply runs offline, as a GOG game does without GOG's client.
/// Settings > Stores > GOG turns it off, and so does `env.MADEIRA_GOG_GALAXY = 0` in a game's own engine lines. Log tag: [galaxy] (request names and statuses only; never a token or secret).
enum GogGalaxyConstants {
    static let userAgent = "Porthole (GOG content system client)"
    /// GOG's desktop client's own id: the service refuses a game that claims it.
    static let hostClientID = "46899977096215655"
}

/// The game's token comes from Porthole's own GOG sign-in: the same refresh-token grant GOG's other clients make, at the game's own client, `without_new_session=1`, so the signed-in
/// session's kept tokens are neither used up nor replaced.
struct GogGalaxyTokens: GalaxyTokenSource {
    func gameToken(for client: GOGGalaxyClient) async throws -> GOGGameToken {
        let refresh: String
        do { refresh = try await GogAuth.shared.hostRefreshToken() } catch { throw GalaxyError.notLoggedOn }
        return try await Self.grant(GalaxySecret(refresh), client, label: "GOG game token")
    }

    func refreshGameToken(_ refreshToken: GalaxySecret<String>, for client: GOGGalaxyClient) async throws -> GOGGameToken {
        try await Self.grant(refreshToken, client, label: "GOG game token refresh")
    }

    private static func grant(_ refreshToken: GalaxySecret<String>, _ client: GOGGalaxyClient, label: String) async throws -> GOGGameToken {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = [.init(name: "client_id", value: client.clientID), .init(name: "client_secret", value: client.clientSecret.value),
                        .init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: refreshToken.value),
                        .init(name: "without_new_session", value: "1")]
        let (data, response) = try await GalaxyHTTPSession.shared.data(from: c.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GalaxyError.eresult(status, context: label) }
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_in: Double?
            var user_id: String?
        }
        guard data.count <= 1 << 16, let r = try? JSONDecoder().decode(Reply.self, from: data), let user = r.user_id, UInt64(user) != nil else {
            throw GalaxyError.protocolChanged("\(label): unexpected reply")
        }
        return GOGGameToken(accessToken: GalaxySecret(r.access_token), refreshToken: GalaxySecret(r.refresh_token),
                            expiresAt: Date().addingTimeInterval(r.expires_in ?? 3600), userID: user)
    }
}

@MainActor final class GogGalaxy {
    static let shared = GogGalaxy()

    /// Settings > Stores > GOG: on by default.
    static let enabledKey = "f4.gogGalaxy"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Whether this game's play gets the service: its own engine lines win over the setting. Spaces inside the key are ignored ("env. MADEIRA_GOG_GALAXY = 0" counts).
    static func enabled(for game: Game) -> Bool {
        let own = MadeiraConfig.parse(game.engine?.config ?? "")
        if let value = own.first(where: { $0.key.filter { !$0.isWhitespace } == "env.MADEIRA_GOG_GALAXY" })?.value { return value != "0" }
        return enabled
    }

    /// Where GOG's own client and Heroic's comet put the service's program, and its key (Wine keeps CurrentControlSet as a link to ControlSet001 in system.reg).
    static let serviceWindowsPath = "C:\\ProgramData\\GOG.com\\Galaxy\\redists\\GalaxyCommunication.exe"
    static let serviceKey = "System\\ControlSet001\\Services\\GalaxyCommunication"

    private var listener: GalaxyListener?
    private var gameID: UUID?
    private var backfilling = Set<Int>()

    private init() {}

    private func log(_ line: String) { LogStore.shared.log(line) }

    /// Called right before a library game starts, while no session runs. Starts the service for a GOG game whose build has a Galaxy client; stops any earlier one.
    func prepare(_ game: Game) {
        stop()
        guard let product = game.gogID, game.installer != true else { return }
        guard Self.enabled(for: game) else { log("[galaxy] off for this play"); return }
        guard GogAuth.shared.signedIn, let record = GogInstaller.shared.record(product) else { return }
        guard let client = record.galaxy else {
            backfill(product, record: record)        // a game installed before this: ask GOG for its client now, so the next play has it
            return
        }
        registerService()
        let sink = GalaxyLogger { line in LogStore.shared.log(line) }
        let listener = GalaxyListener(service: GalaxyService(client: client, tokens: GogGalaxyTokens(), log: sink), log: sink)
        do {
            try listener.start()
        } catch {
            log("[galaxy] not started for id=\(product): \(error); the game runs offline")
            return
        }
        self.listener = listener
        gameID = game.id
    }

    /// The play is over (or another game is about to start).
    func stop() {
        listener?.stop()
        listener = nil
        gameID = nil
    }

    /// Stops the service once the game it was started for is no longer the running one.
    func sessionChanged(running: Game?) {
        if let gameID, running?.id != gameID { stop() }
    }

    /// A GOG game installed from GOG's own build gets its Galaxy client from the build's manifest. One installed before that was read has none: ask for it, once per app run.
    private func backfill(_ product: Int, record: GogInstalledGame) {
        guard record.build != nil, backfilling.insert(product).inserted else { return }
        Task { @MainActor in
            guard let latest = try? await GogContent.latestBuild(productID: product), let meta = try? await GogContent.meta(link: latest.link, buildID: latest.id), let client = meta.galaxy else {
                log("[galaxy] no Galaxy client for id=\(product): the game runs offline"); return
            }
            GogInstaller.shared.setGalaxy(client, for: product)
            log("[galaxy] Galaxy client read for id=\(product); it is used from the next play")
        }
    }

    /// The GalaxyCommunication service in the prefix: its program and registry key. Only while no session runs (the wineserver holds the registry then).
    private func registerService() {
        guard wineserver_is_running() == 0, wine_process_is_running() == 0 else { return }
        guard let target = AppModel.unixURL(forWindows: Self.serviceWindowsPath),
              let bundled = Bundle.main.url(forResource: "madeira-galaxy-service", withExtension: "exe", subdirectory: "aarch64-windows") else { return }
        do {
            let data = try Data(contentsOf: bundled)
            if (try? Data(contentsOf: target)) != data {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            let values: [SteamInstallValue] = [
                .init(hive: .machine, key: Self.serviceKey, name: "DisplayName", data: .string("GalaxyCommunication"), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "ImagePath", data: .string("\"" + Self.serviceWindowsPath + "\""), followsInstall: true),
                .init(hive: .machine, key: Self.serviceKey, name: "ObjectName", data: .string("LocalSystem"), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "Type", data: .dword(0x10), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "Start", data: .dword(3), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "ErrorControl", data: .dword(1), followsInstall: false),
            ]
            let changed = try SteamInstallRegistry.write(values, prefix: AppModel.prefix)
            if changed > 0 { log("[galaxy] GalaxyCommunication service registered values=\(changed)") }
        } catch {
            log("[galaxy] GalaxyCommunication service not registered: \(error.localizedDescription)")
        }
    }
}
