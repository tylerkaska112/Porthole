// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CryptoKit
import LauncherCore
import UIKit

// Compatibility reports: how games run on which phones. The server is the Hub (hub/compat.js on the Mac); reading is public, writing is signed with a
// key this install makes for itself. Nothing here needs an account, a code or a token.

// MARK: - Vocabulary (the same words the server accepts)

/// Playtime needed before a game can be reported as working. The server enforces the same number (COMPAT_MIN_MINUTES, default 5).
/// It was set to 0 for one test build (0.50.203); keep both in step if it is ever changed again.
enum CompatRules {
    static let minMinutesForWorking = 5
}

enum CompatStability: String, Codable, CaseIterable, Identifiable {
    case never, sometimes, constantly, wont_launch
    var id: String { rawValue }
    var title: String {
        switch self { case .never: "Never crashed"; case .sometimes: "Crashes sometimes"; case .constantly: "Crashes all the time"; case .wont_launch: "Won't start" }
    }
}

enum CompatTag: String, Codable, CaseIterable, Identifiable {
    case controller_ok, controller_bad, audio_issues, graphics_glitches, online_works, online_broken, long_loading, overheats, drains_battery, needs_low_settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .controller_ok: "Controls work"
        case .controller_bad: "Controls are awkward"
        case .audio_issues: "Sound problems"
        case .graphics_glitches: "Graphics glitches"
        case .online_works: "Online works"
        case .online_broken: "Online doesn't work"
        case .long_loading: "Slow to load"
        case .overheats: "Phone gets hot"
        case .drains_battery: "Drains the battery"
        case .needs_low_settings: "Needs low settings"
        }
    }
}

/// Where the game's files came from. A fixed list on purpose: nobody types a website, so no download site can end up in a report.
enum CompatSource: String, Codable, CaseIterable, Identifiable {
    case steam, gog, epic, itch, humble, physical, demo, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .steam: "Steam"
        case .gog: "GOG"
        case .epic: "Epic Games Store"
        case .itch: "itch.io"
        case .humble: "Humble Bundle"
        case .physical: "A disc or my own backup"
        case .demo: "A developer's demo or free release"
        case .other: "Somewhere else (kept private)"
        }
    }
}

// MARK: - Server answers

struct CompatGameSummary: Codable, Identifiable, Equatable {
    var id: String
    var kind: String
    var steamAppID: Int?
    var title: String?
    var reportCount: Int
    var lastReport: String
    var badge: CompatBadge
}

struct CompatDeviceBreakdown: Codable, Identifiable, Equatable {
    var device: String
    var deviceId: String
    var verdict: CompatVerdict
    var reports: Int
    var confidence: String
    var id: String { deviceId }
}

struct CompatGameDetail: Codable, Equatable {
    var id: String
    var kind: String
    var steamAppID: Int?
    var title: String?
    var titlePending: Bool
    var badge: CompatBadge
    var devices: [CompatDeviceBreakdown]
    var settingsSummary: CompatSettingsSummary?
}

struct CompatPerf: Codable, Equatable {
    var fpsAvg: Double?
    var fpsLow: Double?
    var minutes: Int?
    var thermal: String?
}

struct CompatPublicReport: Codable, Identifiable, Equatable {
    var id: Int
    var device: String
    var deviceId: String
    var ios: String
    var appVersion: String
    var engine: String?              // nil: sent by an app from before engine versions
    var onThisEngine: Bool?          // set when the question named an engine
    var rating: CompatVerdict
    var stability: CompatStability
    var tags: [CompatTag]
    var source: CompatSource
    var perf: CompatPerf?
    var settings: CompatSettings?
    var comment: String?
    var date: String
}

/// One of this install's own reports, with the parts only its author sees (a comment still waiting for approval).
struct CompatMyReport: Codable, Identifiable, Equatable {
    var id: Int
    var gameId: String
    var gameTitle: String
    var device: String
    var rating: CompatVerdict
    var comment: String?
    var commentStatus: String
    /// pending: waiting for the developer to approve it; approved: public; rejected: not accepted. Nil from a server that does not have approval yet.
    var status: String?
    var hidden: Bool
    var date: String
}

// MARK: - What gets sent

/// How a game was set up when it ran: only fixed choices and numbers, never anything typed (launch options are left out on purpose).
struct CompatSettings: Codable, Equatable {
    var launch: String            // "steam" (started through Steam) or "direct"
    var power: String             // performance, balanced, saver
    var keepModeWhenHot: Bool
    var swapMB: Int
    var swapCoverage: String      // "", "blocks", "wide"
    var vramMB: Int
    var audioCushionMs: Int
    var preciseMath: Bool
    var desktopDisplay: Bool      // Wine's virtual desktop
    var controls: String          // standard, firstPerson

    /// One readable line, for the form and for each report.
    var summary: String {
        [Self.describe("launch", .string(launch)), Self.describe("power", .string(power)), Self.describe("desktopDisplay", .bool(desktopDisplay)),
         Self.describe("swapMB", .int(swapMB)), Self.describe("vramMB", .int(vramMB)), Self.describe("audioCushionMs", .int(audioCushionMs)),
         Self.describe("preciseMath", .bool(preciseMath)), Self.describe("controls", .string(controls))].joined(separator: " \u{00B7} ")
    }

    static func describe(_ key: String, _ value: CompatScalar) -> String {
        switch (key, value) {
        case ("launch", .string(let v)): return v == "steam" ? "Started through Steam" : "Run directly (not through Steam)"
        case ("power", .string(let v)): return v == "performance" ? "Performance mode" : v == "saver" ? "Battery saver" : "Balanced mode"
        case ("desktopDisplay", .bool(let v)): return v ? "Wine desktop display on" : "Wine desktop display off"
        case ("swapMB", .int(let v)): return v == 0 ? "no extra swap" : "\(v) MB swap"
        case ("vramMB", .int(let v)): return v == 0 ? "video memory automatic" : "\(v) MB video memory"
        case ("audioCushionMs", .int(let v)): return "audio cushion \(v) ms"
        case ("preciseMath", .bool(let v)): return v ? "precise shader math" : "fast shader math"
        case ("controls", .string(let v)): return v == "firstPerson" ? "first-person controls" : "standard controls"
        case ("keepModeWhenHot", .bool(let v)): return v ? "keeps its mode when hot" : "drops to battery saver when hot"
        case ("swapCoverage", .string(let v)): return v.isEmpty ? "classic swap" : "\(v) swap"
        default: return "\(key): \(value.text)"
        }
    }
}

/// A number, flag or word from the server where the kind depends on the setting.
enum CompatScalar: Codable, Equatable {
    case string(String), int(Int), bool(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .int(let v): try c.encode(v); case .bool(let v): try c.encode(v) }
    }
    var text: String { switch self { case .string(let v): v; case .int(let v): String(v); case .bool(let v): v ? "on" : "off" } }
}

/// "How people who say it works great have it set up".
struct CompatSettingsSummary: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable { var key: String; var value: CompatScalar; var count: Int; var id: String { key } }
    var reports: Int
    var items: [Item]
}

struct CompatReportPayload: Codable, Equatable {
    struct GameRef: Codable, Equatable {
        var kind: String                // "steam" or "file"
        var steamAppID: Int?
        var fingerprint: String?
        var title: String
    }
    struct Device: Codable, Equatable { var id: String; var name: String }
    var game: GameRef
    var device: Device
    var ios: String
    var appVersion: String
    var engine: String?              // nil only for a report saved by an earlier build while it waited to be sent
    var rating: CompatVerdict
    var stability: CompatStability
    var tags: [CompatTag]
    var source: CompatSource
    var perf: CompatPerf?
    var settings: CompatSettings?
    var comment: String
    /// The game's own log, cleaned and packed (raw deflate, base64): private, read only by the developer's Launcher. Not kept in a queued report (the log waits in a file).
    var logGz: String?
}

// MARK: - This phone

enum CompatDeviceInfo {
    /// "iPhone17,1" and a readable name, or nil where reporting makes no sense (a Mac or an unknown device).
    static var current: (id: String, name: String)? {
        var id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if id.isEmpty {
            var info = utsname(); uname(&info)
            id = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        }
        guard id.hasPrefix("iPhone") || id.hasPrefix("iPad") else { return nil }
        return (id, names[id] ?? (id.hasPrefix("iPad") ? "iPad, model \(id)" : "iPhone, model \(id)"))
    }

    private static let names: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
    ]

    /// "2026-10-02" (what the server sends) as a date in the person's own format.
    static func date(_ iso: String) -> String {
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"; parser.locale = Locale(identifier: "en_US_POSIX")
        return parser.date(from: iso).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? iso
    }

    static var iOSVersion: String { UIDevice.current.systemVersion }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
}

// MARK: - The game engine

/// Which version of the emulation layer this build runs games on (the Madeira commit plus a revision; see tools/engine.sh). Compatibility badges
/// belong to an engine, not to an app version: an update that leaves the engine alone keeps every badge, and a new engine starts with none.
enum CompatEngine {
    static var id: String { Bundle.main.object(forInfoDictionaryKey: "PortholeEngine") as? String ?? "unknown" }
    static var madeira: String { Bundle.main.object(forInfoDictionaryKey: "PortholeEngineMadeira") as? String ?? "unknown" }
    /// For people: "Madeira 40d5e74, revision 0".
    static var label: String {
        let parts = id.components(separatedBy: "-r")
        return parts.count == 2 ? "Madeira \(parts[0]), revision \(parts[1])" : id
    }
    /// A report's engine, in words.
    static func describe(_ engine: String?) -> String {
        guard let engine else { return "an earlier version" }
        let parts = engine.components(separatedBy: "-r")
        return parts.count == 2 ? "Madeira \(parts[0]) r\(parts[1])" : engine
    }
}

// MARK: - This install's key

/// The P-256 key that signs this install's reports. It is made on first use and kept in the Keychain; the server only ever sees the public half.
enum CompatIdentity {
    private static let storeKey = "compat.signing-key"
    private static let store = KeychainSecretStore()
    /// When the Keychain refuses, the key lives for this run only (never in a file a Windows program could read); reports then cannot be edited later.
    nonisolated(unsafe) private static var inMemory: P256.Signing.PrivateKey?

    static func privateKey() -> P256.Signing.PrivateKey {
        SecretMigration.run()
        if let data = store.load(storeKey), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) { return key }
        if let inMemory { return inMemory }
        let key = P256.Signing.PrivateKey()
        if (try? store.save(key.rawRepresentation, for: storeKey)) == nil { inMemory = key }
        return key
    }

    /// A fresh identity: earlier reports stay on the server under the old key but can no longer be edited from this install.
    static func reset() { store.remove(storeKey) }
}

// MARK: - The server

enum CompatError: LocalizedError {
    case offline
    case server(Int, String)
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .offline: "Can't reach the compatibility server right now."
        case .server(_, let message): message
        case .notAvailable(let why): why
        }
    }
    /// A problem with the network or the server itself, as opposed to the server refusing this particular request.
    var isTemporary: Bool {
        switch self { case .offline: true; case .server(let code, _): code >= 500 || code == 429; case .notAvailable: false }
    }
}

struct CompatClient: Sendable {
    /// `nil` when no server has been set (a build made without one, and nothing typed in Settings).
    var baseURL: URL?

    /// The Hub address the Updates screen uses (or the one this build was made with).
    static func standard() -> CompatClient {
        let typed = UserDefaults.standard.string(forKey: "hubURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        // https only (plain http only for this device itself): the update server's address carries tokens and reports.
        let url = typed.flatMap { URL(string: $0) }.flatMap { u -> URL? in
            guard let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return nil }
            if scheme == "https" { return u }
            return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) ? u : nil
        }
        return CompatClient(baseURL: url ?? BuiltIn.defaultHubURL)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func url(_ path: String, _ query: [(String, String)]) throws -> URL {
        guard let baseURL else { throw CompatError.notAvailable("This build is not connected to a community server.") }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts?.percentEncodedPath = path
        if !query.isEmpty { parts?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = parts?.url else { throw CompatError.notAvailable("Bad server address.") }
        return url
    }

    /// For an upload of a few megabytes (a problem report with its whole log): minutes, not seconds.
    private static let longSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func perform<T: Decodable>(_ request: URLRequest, long: Bool = false, as type: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do { (data, response) = try await (long ? Self.longSession : Self.session).data(for: request) }
        catch { throw CompatError.offline }
        guard let http = response as? HTTPURLResponse else { throw CompatError.offline }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "The server answered \(http.statusCode)."
            throw CompatError.server(http.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CompatError.server(http.statusCode, "The server's answer wasn't understood.") }
    }

    func get<T: Decodable>(_ path: String, _ query: [(String, String)] = [], as type: T.Type) async throws -> T {
        var request = URLRequest(url: try url(path, query))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await perform(request, as: type)
    }

    /// The signature covers the method, the exact request target, the time and the body (see verifySigned in hub/compat.js).
    func signed<T: Decodable>(_ method: String, _ path: String, _ query: [(String, String)] = [], body: Data? = nil, long: Bool = false, as type: T.Type) async throws -> T {
        let url = try url(path, query)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let target = (parts?.percentEncodedPath ?? path) + (parts?.percentEncodedQuery.map { "?" + $0 } ?? "")
        let time = Int(Date().timeIntervalSince1970 * 1000)
        var message = Data("\(method)\n\(target)\n\(time)\n".utf8)
        if let body { message.append(body) }
        let key = CompatIdentity.privateKey()
        guard let signature = try? key.signature(for: message) else { throw CompatError.notAvailable("Couldn't sign the request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(key.publicKey.derRepresentation.base64EncodedString(), forHTTPHeaderField: "x-compat-key")
        request.setValue(signature.rawRepresentation.base64EncodedString(), forHTTPHeaderField: "x-compat-sig")
        request.setValue(String(time), forHTTPHeaderField: "x-compat-time")
        return try await perform(request, long: long, as: type)
    }

    // The calls the screens use.

    /// Every game that has public reports, with its badge for this engine and device, in a few pages. The app then picks the library's games out of
    /// this list ON THE DEVICE: the server is never told which games the person has (the old way asked it about each game's id).
    func allBadges(device: String?, pageSize: Int = 100, maxPages: Int = 100) async throws -> [String: CompatBadge] {
        var out: [String: CompatBadge] = [:]
        for page in 0..<maxPages {
            let games = try await self.games(query: "", sort: "reports", limit: pageSize, offset: page * pageSize, device: device)
            for g in games { out[g.id] = g.badge }
            if games.count < pageSize { break }
        }
        return out
    }

    func games(query: String, sort: String, limit: Int, offset: Int, device: String?) async throws -> [CompatGameSummary] {
        var items: [(String, String)] = [("sort", sort), ("limit", String(limit)), ("offset", String(offset)), ("engine", CompatEngine.id)]
        if !query.isEmpty { items.append(("q", query)) }
        if let device { items.append(("device", device)) }
        return try await get("/compat/games", items, as: [CompatGameSummary].self)
    }

    private func gamePath(_ id: String) -> String { "/compat/games/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id) }

    func game(id: String, device: String?) async throws -> CompatGameDetail {
        try await get(gamePath(id), (device.map { [("device", $0)] } ?? []) + [("engine", CompatEngine.id)], as: CompatGameDetail.self)
    }

    func reports(gameID: String, device: String?, limit: Int, offset: Int) async throws -> [CompatPublicReport] {
        var items: [(String, String)] = [("limit", String(limit)), ("offset", String(offset)), ("engine", CompatEngine.id)]
        if let device { items.append(("device", device)) }
        return try await get(gamePath(gameID) + "/reports", items, as: [CompatPublicReport].self)
    }

    struct Saved: Decodable { var id: Int; var replaced: Bool; var commentStatus: String; var status: String?; var logStored: Bool? }

    func submit(_ payload: CompatReportPayload) async throws -> Saved {
        try await signed("POST", "/compat/reports", body: try JSONEncoder().encode(payload), long: payload.logGz != nil, as: Saved.self)
    }

    func mine() async throws -> [CompatMyReport] { try await signed("GET", "/compat/mine", as: [CompatMyReport].self) }

    struct Done: Decodable {}
    func delete(reportID: Int) async throws { _ = try await signed("DELETE", "/compat/reports/\(reportID)", as: Done.self) }
    func flag(reportID: Int) async throws { _ = try await signed("POST", "/compat/reports/\(reportID)/flag", as: Done.self) }
}
