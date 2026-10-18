// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// The games an Amazon account is entitled to (bought on Amazon, or claimed with Prime Gaming), from the same distribution service the Amazon Games app uses.
// Kept on disk so the library shows at once.

import Foundation
import Combine
import CryptoKit

struct AmazonGame: Codable, Identifiable, Hashable {
    /// The product id ("amzn1.adg.product...").
    let id: String
    /// The entitlement id: what the download service wants when a game is installed.
    let entitlementID: String
    let title: String
    let sku: String
    let artURL: String?
    let logoURL: String?
    let developer: String?

    var key: String { id }
    var art: URL? { (artURL ?? logoURL).flatMap(URL.init(string:)) }
    var logo: URL? { logoURL.flatMap(URL.init(string:)) }
}

enum AmazonError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// The distribution service's calls (JSON over HTTPS, an access token in a header).
enum AmazonAPI {
    private static let entitlements = URL(string: "https://gaming.amazon.com/api/distribution/entitlements")!
    private static let distribution = URL(string: "https://gaming.amazon.com/api/distribution/v2/public")!
    private static let targetPrefix = "com.amazon.animusdistributionservice."

    static func call(_ url: URL, target: String, token: String, body: [String: Any]) async throws -> (json: [String: Any], status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.setValue(token, forHTTPHeaderField: "x-amzn-token")
        request.setValue("com.amazon.agslauncher.win/3.0.9202.1", forHTTPHeaderField: "UserAgent")
        request.setValue(AmazonAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("amz-1.0", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let data: Data, response: URLResponse
        do { (data, response) = try await StoreNetwork.session.data(for: request) } catch { throw AmazonAuthError.network }
        guard let http = response as? HTTPURLResponse else { throw AmazonAuthError.network }
        return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:], http.statusCode)
    }

    /// All entitlements, page by page.
    static func entitlementPages(token: String, serial: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = [], next: String?
        for _ in 0..<200 {
            let hardware = SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02X", $0) }.joined()
            let body: [String: Any] = [
                "Operation": "GetEntitlements", "clientId": "Sonic", "syncPoint": NSNull(), "nextToken": next.map { $0 as Any } ?? NSNull(), "maxResults": 50,
                "productIdFilter": NSNull(), "keyId": "d5dc8b8b-86c8-4fc4-ae93-18c0def5314d", "hardwareHash": hardware,
            ]
            let (json, status) = try await call(entitlements, target: targetPrefix + "entitlement.AnimusEntitlementsService.GetEntitlements", token: token, body: body)
            guard status == 200 else { throw AmazonError.invalid("Amazon did not list your games (answer \(status)).") }
            all.append(contentsOf: (json["entitlements"] as? [[String: Any]]) ?? [])
            guard let more = json["nextToken"] as? String, !more.isEmpty else { return all }
            next = more
        }
        return all
    }

    /// Where a game's files are: the build id and the address the manifest and files hang off.
    static func download(entitlementID: String, token: String) async throws -> (version: String, base: URL) {
        let (json, status) = try await call(distribution, target: targetPrefix + "external.AnimusDistributionService.GetGameDownload", token: token,
                                            body: ["entitlementId": entitlementID, "Operation": "GetGameDownload"])
        guard status == 200, let version = json["versionId"] as? String, let link = (json["downloadUrl"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https" else {
            LogStore.shared.log("[amazon-install] download details answered \(status)", level: .error)
            throw AmazonError.invalid("Amazon did not give a download for this game (answer \(status)).")
        }
        return (version, link)
    }
}

@MainActor
final class AmazonLibrary: ObservableObject {
    static let shared = AmazonLibrary()

    @Published private(set) var games: [AmazonGame] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private var lastRefresh: Date?
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("amazon-library.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? JSONDecoder().decode([AmazonGame].self, from: data) { games = cached }
    }

    func refreshIfStale() {
        guard AmazonAuth.shared.signedIn else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        refresh()
    }

    func clear() {
        games = []
        error = nil
        lastRefresh = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    func refresh() {
        guard !isLoading, AmazonAuth.shared.signedIn else { return }
        guard NetworkStatus.shared.isOnline else { LogStore.shared.log("[amazon-library] offline: keeping the saved list"); return }
        isLoading = true
        lastRefresh = Date()
        error = nil
        Task {
            do {
                let (token, serial) = try await AmazonAuth.shared.session()
                let raw = try await AmazonAPI.entitlementPages(token: token, serial: serial)
                let list = Self.games(from: raw)
                if let data = try? JSONEncoder().encode(list) {
                    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.cacheURL, options: .atomic)
                }
                games = list
                AmazonInstaller.shared.refreshArt(from: list)
            } catch {
                LogStore.shared.log("[amazon-library] refresh failed: \((error as? AmazonAuthError)?.message ?? error.localizedDescription)", level: .error)
                self.error = (error as? AmazonAuthError)?.message ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    /// The games among the entitlements (an account also holds in-game items and add-ons, which have nothing to download), sorted by name.
    nonisolated static func games(from entitlements: [[String: Any]]) -> [AmazonGame] {
        var byProduct: [String: AmazonGame] = [:]
        var lines: [String: Int] = [:]
        for entitlement in entitlements {
            guard let product = entitlement["product"] as? [String: Any], let id = product["id"] as? String, let entitlementID = entitlement["id"] as? String,
                  let title = (product["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            let line = (product["productLine"] as? String) ?? ""
            lines[line, default: 0] += 1
            // Games are the "FuelGame" product line; an entitlement that does not say its line is kept rather than hidden.
            guard line.isEmpty || line.lowercased().contains("game") else { continue }
            let detail = product["productDetail"] as? [String: Any]
            let details = detail?["details"] as? [String: Any]
            func text(_ dict: [String: Any]?, _ key: String) -> String? { (dict?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let art = text(details, "backgroundUrl1") ?? text(details, "backgroundUrl2") ?? text(details, "logoUrl") ?? text(detail, "iconUrl")
            byProduct[id] = AmazonGame(id: id, entitlementID: entitlementID, title: title, sku: (product["sku"] as? String) ?? "",
                                       artURL: art, logoURL: text(details, "logoUrl") ?? text(detail, "iconUrl"), developer: text(details, "developer"))
        }
        let summary = lines.sorted { $0.key < $1.key }.map { "\($0.key.isEmpty ? "-" : $0.key)=\($0.value)" }.joined(separator: " ")
        Task { @MainActor in LogStore.shared.log("[amazon-library] \(entitlements.count) entitlement(s), \(byProduct.count) game(s); product lines: \(summary)") }
        return byProduct.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
