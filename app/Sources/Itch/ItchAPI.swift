// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// itch.io: sign-in with the person's own API key (made on itch.io/user/settings/api-keys; it never leaves the Keychain except as the Authorization header of
// requests to api.itch.io), the library of games they own or claimed, and the download links of a game's uploads. The key is never logged.

import Foundation
import Security
import Combine

enum ItchError: LocalizedError {
    case notSignedIn
    case network
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to itch.io first."
        case .network: return "Could not reach itch.io. Check your connection and try again."
        case .unauthorized: return "itch.io did not accept the API key. Make a new one and sign in again."
        case .server(let message): return message
        }
    }
}

struct ItchGame: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let url: String
    let coverURL: String?
    /// The download key the account holds for this game (needed for paid games; lets the uploads be listed).
    let keyID: Int?
    let author: String?
    let summary: String?

    var key: String { String(id) }
    var cover: URL? { coverURL.flatMap(URL.init(string:)) }
    var page: URL? { URL(string: url) }
}

struct ItchUpload: Identifiable, Hashable {
    let id: Int
    let filename: String
    let displayName: String
    let size: UInt64
    let type: String
    let storage: String
    let demo: Bool
    let windows: Bool

    var title: String { displayName.isEmpty ? filename : displayName }
    var ext: String { (filename as NSString).pathExtension.lowercased() }
}

// MARK: - Account

@MainActor
final class ItchAuth: ObservableObject {
    static let shared = ItchAuth()

    @Published private(set) var accountName: String?
    @Published var signInError: String?
    @Published private(set) var isBusy = false

    private let store = ItchKeyStore()
    var signedIn: Bool { accountName != nil }

    private init() { accountName = store.load()?.username }

    func refresh() { accountName = store.load()?.username; signInError = nil }

    /// The saved API key, for requests only.
    func apiKey() -> String? { store.load()?.key }

    /// Checks a pasted key against itch.io and keeps it when it works.
    func signIn(apiKey raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !key.isEmpty, !key.contains(" "), key.count >= 20 else {
            signInError = "That does not look like an itch.io API key."
            return
        }
        isBusy = true
        signInError = nil
        Task {
            do {
                let json = try await ItchAPI.get("profile", key: key)
                let user = json["user"] as? [String: Any]
                let name = (user?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (user?["username"] as? String) ?? "itch.io account"
                store.save(.init(key: key, username: name))
                accountName = name
                LogStore.shared.log("[itch-auth] signed in")
            } catch {
                signInError = ErrorText.plain(error)
                LogStore.shared.log("[itch-auth] sign-in failed: \(error.localizedDescription)", level: .error)
            }
            isBusy = false
        }
    }

    func signOut() {
        store.delete()
        accountName = nil
        signInError = nil
    }
}

struct ItchCredentials: Codable { var key: String; var username: String }

final class ItchKeyStore {
    private let serviceName = "porthole.itch.key"
    private func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serviceName, kSecAttrAccount as String: "itch_key"]
    }
    func save(_ credentials: ItchCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        delete()
        var query = base()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
    func load() -> ItchCredentials? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ItchCredentials.self, from: data)
    }
    func delete() { SecItemDelete(base() as CFDictionary) }
}

// MARK: - Requests

/// Stops a redirect so the download address can be read (and the key is not sent on to the file host).
private final class ItchNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ItchAPI {
    private static let host = "https://api.itch.io/"

    static func get(_ path: String, query: [String: String] = [:], key: String) async throws -> [String: Any] {
        var components = URLComponents(string: host + path)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        let data: Data, response: URLResponse
        do { (data, response) = try await StoreNetwork.session.data(for: request) } catch { throw ItchError.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ItchError.unauthorized }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let errors = json?["errors"] as? [String], let first = errors.first {
            if first.lowercased().contains("invalid key") || first.lowercased().contains("api key") { throw ItchError.unauthorized }
            throw ItchError.server("itch.io said: \(first)")
        }
        guard status == 200, let json else { throw ItchError.server("itch.io answered \(status).") }
        return json
    }

    /// Every game the account owns a download key for (purchases, claims, bundles, gifts), Windows downloadable ones only.
    static func ownedGames(key: String) async throws -> [ItchGame] {
        var games: [ItchGame] = [], seen = Set<Int>()
        var page = 1
        while page <= 60 {
            let json = try await get("profile/owned-keys", query: ["page": "\(page)", "per_page": "100"], key: key)
            let keys = json["owned_keys"] as? [[String: Any]] ?? []
            if keys.isEmpty { break }
            for entry in keys {
                guard let game = entry["game"] as? [String: Any], let id = (game["id"] as? NSNumber)?.intValue, !seen.contains(id),
                      let title = game["title"] as? String else { continue }
                // A game for a browser, a soundtrack, a book and the like has nothing Windows to download.
                let traits = (game["traits"] as? [String]) ?? []
                let windows = traits.contains("p_windows") || (game["p_windows"] as? Bool) == true
                let type = (game["type"] as? String) ?? "default"
                let classification = (game["classification"] as? String) ?? "game"
                guard windows, type == "default", ["game", "tool"].contains(classification) else { continue }
                seen.insert(id)
                let user = game["user"] as? [String: Any]
                games.append(ItchGame(id: id, title: title, url: (game["url"] as? String) ?? "https://itch.io",
                                      coverURL: (game["still_cover_url"] as? String) ?? (game["cover_url"] as? String),
                                      keyID: (entry["id"] as? NSNumber)?.intValue,
                                      author: (user?["display_name"] as? String) ?? (user?["username"] as? String),
                                      summary: game["short_text"] as? String))
            }
            page += 1
        }
        // Free games sit in the person's collections, not in their purchases: a free game needs no download key, so it can be fetched without one. A failure
        // here (a private collection, a hiccup) must not hide the games that were found.
        if let extra = try? await collectionGames(key: key, excluding: seen) { games += extra }
        return games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Games in the account's own collections that cost nothing and have a Windows download.
    static func collectionGames(key: String, excluding known: Set<Int>) async throws -> [ItchGame] {
        let list = try await get("profile/collections", key: key)
        var found: [ItchGame] = [], seen = known
        for collection in (list["collections"] as? [[String: Any]] ?? []).prefix(60) {
            guard let id = (collection["id"] as? NSNumber)?.intValue else { continue }
            if let count = (collection["games_count"] as? NSNumber)?.intValue, count == 0 { continue }
            var page = 1
            while page <= 20 {
                guard let json = try? await get("collections/\(id)/collection-games", query: ["page": "\(page)", "per_page": "500"], key: key) else { break }
                let entries = json["collection_games"] as? [[String: Any]] ?? []
                if entries.isEmpty { break }
                for entry in entries {
                    guard let game = entry["game"] as? [String: Any], let gameID = (game["id"] as? NSNumber)?.intValue, !seen.contains(gameID),
                          let title = game["title"] as? String else { continue }
                    let traits = (game["traits"] as? [String]) ?? []
                    let windows = traits.contains("p_windows") || (game["p_windows"] as? Bool) == true
                    let type = (game["type"] as? String) ?? "default"
                    let classification = (game["classification"] as? String) ?? "game"
                    // Free means a minimum price of zero (pay-what-you-want games included); a paid game that is only in a collection is not downloadable.
                    let price = (game["min_price"] as? NSNumber)?.intValue
                    let free = price == 0 || (price == nil && !traits.contains("can_be_bought"))
                    guard windows, free, type == "default", ["game", "tool"].contains(classification) else { continue }
                    seen.insert(gameID)
                    let user = game["user"] as? [String: Any]
                    found.append(ItchGame(id: gameID, title: title, url: (game["url"] as? String) ?? "https://itch.io",
                                          coverURL: (game["still_cover_url"] as? String) ?? (game["cover_url"] as? String), keyID: nil,
                                          author: (user?["display_name"] as? String) ?? (user?["username"] as? String),
                                          summary: game["short_text"] as? String))
                }
                if entries.count < 500 { break }
                page += 1
            }
        }
        return found
    }

    static func uploads(of game: ItchGame, key: String) async throws -> [ItchUpload] {
        var query: [String: String] = [:]
        if let keyID = game.keyID { query["download_key_id"] = String(keyID) }
        let json = try await get("games/\(game.id)/uploads", query: query, key: key)
        return (json["uploads"] as? [[String: Any]] ?? []).compactMap { u in
            guard let id = (u["id"] as? NSNumber)?.intValue, let filename = u["filename"] as? String else { return nil }
            let platforms = u["platforms"] as? [String: Any]
            let traits = (u["traits"] as? [String]) ?? []
            let lower = filename.lowercased()
            var windows = platforms?["windows"] != nil || traits.contains("p_windows") || (u["p_windows"] as? Bool) == true
            // An upload with no platform information at all and a Windows-looking name is taken as a Windows one.
            if platforms == nil, traits.isEmpty, u["p_windows"] == nil, lower.hasSuffix(".exe") || lower.hasSuffix(".msi") || lower.contains("win") { windows = true }
            return ItchUpload(id: id, filename: filename, displayName: (u["display_name"] as? String) ?? "",
                              size: (u["size"] as? NSNumber)?.uint64Value ?? 0, type: (u["type"] as? String) ?? "default",
                              storage: (u["storage"] as? String) ?? "hosted", demo: (u["demo"] as? Bool) ?? false, windows: windows)
        }
    }

    /// The address one upload can be fetched from right now (it carries its own short-lived signature).
    static func downloadURL(upload: ItchUpload, game: ItchGame, key: String) async throws -> URL {
        var components = URLComponents(string: host + "uploads/\(upload.id)/download")!
        if let keyID = game.keyID { components.queryItems = [URLQueryItem(name: "download_key_id", value: String(keyID))] }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        let session = URLSession(configuration: .ephemeral, delegate: ItchNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw ItchError.network }
        guard let http = response as? HTTPURLResponse else { throw ItchError.network }
        if http.statusCode == 401 || http.statusCode == 403 { throw ItchError.unauthorized }
        if (300 ..< 400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location), url.scheme == "https" {
            return url
        }
        if http.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let link = (json["url"] as? String) ?? (json["link"] as? String), let url = URL(string: link), url.scheme == "https" {
            return url
        }
        LogStore.shared.log("[itch-install] download link answered \(http.statusCode), \(data.count) bytes", level: .error)
        throw ItchError.server("itch.io did not give a download link (answer \(http.statusCode)).")
    }
}
