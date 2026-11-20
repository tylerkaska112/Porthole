// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Discord's web API (the same one the website uses) for what the gateway does not carry. One request per thing a person asked for: nothing here polls or retries on its own.
enum DiscordREST {
    enum Failure: Error, Equatable {
        case signedOut, unauthorized, forbidden, notFound, rateLimited, network(String), server(Int)

        /// What to tell the person.
        var message: String {
            switch self {
            case .signedOut: "Not signed in to Discord."
            case .unauthorized: "Discord does not accept the saved sign-in any more. Sign in again in the Social tab."
            case .forbidden: "This account is not allowed to read this channel."
            case .notFound: "Discord does not have this channel any more."
            case .rateLimited: "Discord asked Porthole to slow down. Try again in a moment."
            case .network(let why): "Could not reach Discord (\(why))."
            case .server(let code): "Discord answered with an error (\(code)). Try again later."
            }
        }
    }

    static func failure(forStatus code: Int) -> Failure? {
        switch code {
        case 200..<300: nil
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        default: .server(code)
        }
    }

    /// The same, for sending a message: a refusal there is about posting, not reading.
    static func sendingMessage(_ failure: Failure) -> String {
        switch failure {
        case .forbidden: "You are not allowed to send messages in this channel."
        case .rateLimited: "Discord asked Porthole to slow down. Wait a moment, then send again."
        default: failure.message
        }
    }

    /// GET https://discord.com/api/v9/<path>. The token goes only in the Authorization header, never in the address and never in a log.
    static func get(_ path: String, query: [URLQueryItem] = [], token: String?) async throws -> Any {
        try await call("GET", path, query: query, body: nil, token: token)
    }

    /// POST with a JSON body, for something a person asked for (sending a message). Never retried by itself: a message sent twice is worse than one that needs a second tap.
    static func post(_ path: String, body: [String: Any], token: String?) async throws -> Any {
        try await call("POST", path, query: [], body: body, token: token)
    }

    /// PUT, for something a person pressed (a reaction). Discord answers with nothing.
    static func put(_ path: String, query: [URLQueryItem] = [], token: String?) async throws {
        _ = try await call("PUT", path, query: query, body: nil, token: token)
    }

    /// PATCH with a JSON body (editing a message the person pressed Edit on).
    static func patch(_ path: String, body: [String: Any], token: String?) async throws -> Any {
        try await call("PATCH", path, query: [], body: body, token: token)
    }

    /// DELETE, for something a person confirmed (their own message, their own reaction).
    static func delete(_ path: String, query: [URLQueryItem] = [], token: String?) async throws {
        _ = try await call("DELETE", path, query: query, body: nil, token: token)
    }

    private static func call(_ method: String, _ path: String, query: [URLQueryItem], body: [String: Any]?, token: String?) async throws -> Any {
        guard let token else { throw Failure.signedOut }
        guard var parts = URLComponents(string: "https://discord.com/api/v9/\(path)") else { throw Failure.network("the address is not valid") }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw Failure.network("the address is not valid") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.network((error as NSError).localizedDescription) }
        if let code = (response as? HTTPURLResponse)?.statusCode, let failure = failure(forStatus: code) { throw failure }
        if data.isEmpty { return [String: Any]() }          // 204: a reaction put or taken away answers with nothing
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw Failure.server(0) }
        return json
    }
}
