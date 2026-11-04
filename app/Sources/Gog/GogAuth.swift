// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// GOG sign-in. The person logs in on GOG's own page in an embedded web view; the one-time code GOG ends the login on is captured and exchanged for tokens
// with GOG's public Galaxy client (the same client id every third-party GOG tool uses). The password is typed on GOG's page and never reaches the app;
// the tokens live in the Keychain. Nothing here logs a token, a code or an account name.

import Foundation
import Security
import SwiftUI
import WebKit
import Combine

enum GogAuthError: Error {
    case notSignedIn
    case network
    case rejected(String)

    var message: String {
        switch self {
        case .notSignedIn: return "Sign in to GOG first."
        case .network: return "Could not reach GOG. Check your connection and try again."
        case .rejected(let code): return "GOG refused the sign-in (\(code)). Sign in again."
        }
    }
}

@MainActor
final class GogAuth: ObservableObject {
    static let shared = GogAuth()

    @Published private(set) var accountName: String?
    @Published var signInError: String?
    @Published private(set) var isBusy = false

    /// GOG's public Galaxy client credentials, as published by every open-source GOG client.
    private let clientID = "46899977096215655"
    private let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    private let redirectURI = "https://embed.gog.com/on_login_success?origin=client"
    private let store = GogTokenStore()

    var signedIn: Bool { accountName != nil }

    private init() {
        accountName = store.loadTokens().map { $0.username.isEmpty ? "GOG account" : $0.username }
    }

    /// GOG's login page; it ends on `on_login_success?code=...`, which the web view intercepts.
    var loginURL: URL {
        var c = URLComponents(string: "https://auth.gog.com/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: "client2"),
        ]
        return c.url!
    }

    /// The `code` out of a redirect URL, or out of whatever was pasted (a bare code works too).
    nonisolated static func extractCode(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: trimmed), let code = url.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty { return code }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    func refresh() {
        accountName = store.loadTokens().map { $0.username.isEmpty ? "GOG account" : $0.username }
        signInError = nil
    }

    func exchange(code: String) {
        guard !isBusy, !code.isEmpty else { return }
        isBusy = true
        signInError = nil
        Task {
            do {
                var tokens = try await requestTokens([
                    ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                ])
                tokens.username = (try? await fetchUsername(token: tokens.accessToken)) ?? ""
                store.save(tokens)
                accountName = tokens.username.isEmpty ? "GOG account" : tokens.username
                LogStore.shared.log("[gog-auth] signed in")
            } catch {
                signInError = (error as? GogAuthError)?.message ?? error.localizedDescription
                LogStore.shared.log("[gog-auth] sign-in failed: \((error as? GogAuthError)?.message ?? "\(error)")", level: .error)
            }
            isBusy = false
        }
    }

    /// A valid access token, refreshed first when it has expired.
    func validAccessToken() async throws -> String {
        guard var tokens = store.loadTokens() else { throw GogAuthError.notSignedIn }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
        let username = tokens.username
        tokens = try await requestTokens([("grant_type", "refresh_token"), ("refresh_token", tokens.refreshToken)])
        tokens.username = username
        store.save(tokens)
        return tokens.accessToken
    }

    /// The signed-in session's refresh token, after making sure it still works (for the Galaxy service's game token; it is never logged).
    func hostRefreshToken() async throws -> String {
        _ = try await validAccessToken()
        guard let tokens = store.loadTokens() else { throw GogAuthError.notSignedIn }
        return tokens.refreshToken
    }

    func signOut() {
        store.delete()
        accountName = nil
        signInError = nil
    }

    // MARK: Token endpoint

    private func requestTokens(_ grant: [(String, String)]) async throws -> GogTokens {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "client_secret", value: clientSecret)]
            + grant.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 20
        let data: Data, response: URLResponse
        do { (data, response) = try await StoreNetwork.session.data(for: request) } catch { throw GogAuthError.network }
        guard let http = response as? HTTPURLResponse, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GogAuthError.network }
        if let error = json["error"] as? String { throw GogAuthError.rejected(error) }
        guard http.statusCode < 400, let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw GogAuthError.rejected("status \(http.statusCode)")
        }
        let seconds = (json["expires_in"] as? Double) ?? Double((json["expires_in"] as? Int) ?? 3600)
        return GogTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds - 60),
                         userID: "\(json["user_id"] ?? "")", username: "", savedAt: Date())
    }

    private func fetchUsername(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://embed.gog.com/userData.json")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, _) = try await StoreNetwork.session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["username"] as? String) ?? ""
    }
}

struct GogTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var username: String
    var savedAt: Date
}

final class GogTokenStore {
    private let serviceName = "porthole.gog.tokens"
    private func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serviceName, kSecAttrAccount as String: "gog_tokens"]
    }

    func save(_ tokens: GogTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        var query = base()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadTokens() -> GogTokens? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GogTokens.self, from: data)
    }

    func delete() { SecItemDelete(base() as CFDictionary) }
}

/// GOG's login page in a web view. When GOG redirects to `on_login_success`, the navigation is stopped and the code handed over.
struct GogLoginWebView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()      // a sign-out leaves no GOG session behind in the app
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: MainActor.assumeIsolated { GogAuth.shared.loginURL }))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var captured = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.host == "embed.gog.com", url.path == "/on_login_success" {
                decisionHandler(.cancel)
                guard !captured else { return }
                let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value ?? ""
                if !code.isEmpty { captured = true; onCode(code) }
                return
            }
            decisionHandler(.allow)
        }
    }
}
