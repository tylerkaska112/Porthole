// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Steam sign-in, done natively (no Wine, no Steam client): Steam's public Web API, the same one
// Steam's website and its phone app use. Sign in by QR code (approve it in the Steam phone app, nothing to type) or by
// username and password (+ Steam Guard). Foundation and Security only, so all of it is unit-testable on the Mac.
//
// What is kept: a refresh token in the Keychain. The password is RSA-encrypted with Steam's own key, sent once and
// forgotten. Nothing here logs a token, a password or an account name.
import Foundation
import Security

// MARK: - Errors

struct SteamAPIError: Error, Equatable, CustomStringConvertible {
    var eresult: Int?
    var http: Int?
    var detail: String = ""

    static let notSignedIn = SteamAPIError(eresult: nil, http: nil, detail: "You are not signed in to Steam.")
    static func unreachable(_ text: String) -> SteamAPIError {
        SteamAPIError(eresult: nil, http: nil, detail: "Steam could not be reached (\(text)). Check the internet connection.")
    }
    static func unexpected(_ text: String) -> SteamAPIError { SteamAPIError(eresult: nil, http: nil, detail: text) }

    var description: String {
        if let eresult, eresult != 1 { return Self.message(forEResult: eresult) }
        if let http { return http == 401 || http == 403 ? "Steam did not accept the sign-in token." : "Steam answered with HTTP \(http)." }
        return detail.isEmpty ? "Something went wrong talking to Steam." : detail
    }

    /// Steam refused the token itself (expired, revoked, or not valid for this call).
    var isTokenRefusal: Bool { http == 401 || http == 403 || eresult == 15 || eresult == 21 }
    /// The refresh token can no longer be used at all, so the account has to sign in again.
    var isSessionOver: Bool { isTokenRefusal || eresult == 27 || eresult == 8 }

    static func message(forEResult code: Int) -> String {
        switch code {
        case 5: return "Steam says the username or password is not right."
        case 84: return "Steam is limiting sign-in attempts. Wait a few minutes and try again."
        case 87: return "Steam has paused sign-ins from this network. Try again later."
        case 63, 85: return "Steam wants a Steam Guard code for this sign-in."
        case 65, 88, 89: return "That Steam Guard code was not right."
        case 27: return "The sign-in expired. Start again."
        case 3: return "Steam could not be reached. Check the internet connection."
        case 15: return "Steam refused access."
        case 21: return "Steam says this device is not signed in."
        case 16: return "Steam took too long to answer."
        default: return "Steam answered with error \(code)."
        }
    }
}

// MARK: - HTTP

struct SteamHTTPResponse { var status: Int; var eresult: Int?; var body: Data }

protocol SteamTransport {
    /// Completion may arrive on any queue.
    func send(_ request: URLRequest, completion: @escaping (Result<SteamHTTPResponse, Error>) -> Void)
}

final class URLSessionSteamTransport: SteamTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }
    func send(_ request: URLRequest, completion: @escaping (Result<SteamHTTPResponse, Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(SteamAPIError.unexpected("no HTTP response"))); return }
            let eresult = http.value(forHTTPHeaderField: "x-eresult").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            completion(.success(SteamHTTPResponse(status: http.statusCode, eresult: eresult, body: data ?? Data())))
        }.resume()
    }
}

/// Small JSON helpers: Steam sends 64-bit ids as strings and small numbers as numbers.
enum SteamJSON {
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
    /// application/x-www-form-urlencoded, strictly: base64 has + / = in it, and a + must not turn into a space.
    static func formEncode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

// MARK: - The Web API

final class SteamAPI {
    static let host = "https://api.steampowered.com"
    let transport: SteamTransport
    init(transport: SteamTransport) { self.transport = transport }

    /// One call to `<service>/<method>/v1`. GET puts everything in the query string, POST sends it as a form.
    /// The completion always runs on the main queue.
    func call(_ service: String, _ method: String, post: Bool, input: [String: Any], accessToken: String? = nil,
              completion: @escaping (Result<[String: Any], SteamAPIError>) -> Void) {
        guard let json = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8) else {
            DispatchQueue.main.async { completion(.failure(.unexpected("The request could not be built."))) }
            return
        }
        var query = "input_json=" + SteamJSON.formEncode(text)
        if let accessToken { query = "access_token=" + SteamJSON.formEncode(accessToken) + "&" + query }
        let base = "\(Self.host)/\(service)/\(method)/v1/"
        var request: URLRequest
        if post {
            guard let url = URL(string: base) else { DispatchQueue.main.async { completion(.failure(.unexpected("bad URL"))) }; return }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(query.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        } else {
            guard let url = URL(string: base + "?" + query) else { DispatchQueue.main.async { completion(.failure(.unexpected("bad URL"))) }; return }
            request = URLRequest(url: url)
        }
        request.setValue("https://steamcommunity.com", forHTTPHeaderField: "Origin")
        request.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
        request.setValue("Porthole/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        transport.send(request) { result in
            let outcome: Result<[String: Any], SteamAPIError>
            switch result {
            case .failure(let error): outcome = .failure(.unreachable(error.localizedDescription))
            case .success(let reply): outcome = Self.interpret(reply)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    static func interpret(_ reply: SteamHTTPResponse) -> Result<[String: Any], SteamAPIError> {
        if reply.status != 200 { return .failure(SteamAPIError(eresult: reply.eresult, http: reply.status)) }
        if let eresult = reply.eresult, eresult != 1 { return .failure(SteamAPIError(eresult: eresult, http: nil)) }
        if reply.body.isEmpty { return .success([:]) }
        guard let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] else {
            return .failure(.unexpected("Steam's answer was not understood."))
        }
        return .success(object["response"] as? [String: Any] ?? object)
    }
}

// MARK: - Session

struct SteamAccountSession: Codable, Equatable {
    var steamID: String
    var accountName: String
    var refreshToken: String
    var accessToken: String?
}

protocol SteamSessionStore: AnyObject {
    func load() -> SteamAccountSession?
    func save(_ session: SteamAccountSession)
    func clear()
}

final class MemorySteamSessionStore: SteamSessionStore {
    var session: SteamAccountSession?
    init(_ session: SteamAccountSession? = nil) { self.session = session }
    func load() -> SteamAccountSession? { session }
    func save(_ session: SteamAccountSession) { self.session = session }
    func clear() { session = nil }
}

/// The session lives in the Keychain, readable only after the first unlock and never leaving this device.
final class KeychainSteamSessionStore: SteamSessionStore {
    private let service: String
    init(service: String = "app.porthole.steam") { self.service = service }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }
    func load() -> SteamAccountSession? {
        var query = identity
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SteamAccountSession.self, from: data)
    }
    func save(_ session: SteamAccountSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(identity as CFDictionary)
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { SteamLog.event("Steam: the sign-in could not be kept in the Keychain (status \(status)); you will sign in again next time.") }
    }
    func clear() { SecItemDelete(identity as CFDictionary) }
}

// MARK: - Tokens

/// Steam's tokens are JWTs. Only the payload is read (to learn the account and when the token runs out); nothing is verified here.
enum SteamJWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func subject(_ token: String) -> String? { SteamJSON.string(claims(token)?["sub"]) }
    static func expiry(_ token: String) -> Date? { SteamJSON.double(claims(token)?["exp"]).map { Date(timeIntervalSince1970: $0) } }
    /// A token that cannot be read counts as expired, so a fresh one is asked for.
    static func isExpired(_ token: String, margin: TimeInterval = 120, now: Date = Date()) -> Bool {
        guard let expiry = expiry(token) else { return true }
        return expiry.timeIntervalSince(now) < margin
    }
}

// MARK: - Password encryption

enum SteamCrypto {
    static func hexData(_ text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0, !characters.isEmpty else { return nil }
        var out = Data(capacity: characters.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 97...102: return c - 87; case 65...70: return c - 55; default: return nil }
        }
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
            out.append(high << 4 | low); index += 2
        }
        return out
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []; var n = length
        while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    private static func derInteger(_ value: Data) -> [UInt8] {
        var bytes = Array(value)
        while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }     // a positive number
        return [0x02] + derLength(bytes.count) + bytes
    }
    /// PKCS#1 RSAPublicKey: SEQUENCE { modulus INTEGER, exponent INTEGER }.
    static func publicKeyDER(modulus: Data, exponent: Data) -> Data {
        let body = derInteger(modulus) + derInteger(exponent)
        return Data([0x30] + derLength(body.count) + body)
    }

    /// RSA (PKCS#1 v1.5) with the key Steam hands out for this account, base64 encoded: what Steam's own sign-in does.
    static func encryptPassword(_ password: String, modulusHex: String, exponentHex: String) -> String? {
        guard let modulus = hexData(modulusHex), let exponent = hexData(exponentHex) else { return nil }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                         kSecAttrKeySizeInBits as String: modulus.count * 8]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(publicKeyDER(modulus: modulus, exponent: exponent) as CFData, attributes as CFDictionary, &error),
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, &error) else { return nil }
        return (encrypted as Data).base64EncodedString()
    }
}

// MARK: - Signing in

/// One sign-in attempt. Drive it with `startQR()` or `startCredentials`, listen to `onEvent`, and stop with `cancel()`.
/// Events always arrive on the main queue.
final class SteamAuthenticator {
    enum CodeKind: Equatable { case device, email }
    enum Event: Equatable {
        case qr(String)                        // show (or refresh) this link as a QR code
        case approve(String)                   // waiting for approval on the phone (or by email)
        case needsCode(CodeKind, String)       // a Steam Guard code can be typed now
        case codeRejected(String)
        case signedIn(SteamAccountSession)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    /// Tests poll faster than Steam asks for.
    var pollIntervalOverride: TimeInterval?
    let deviceName: String
    private let api: SteamAPI
    private var generation = 0
    private var clientID = "", requestID = "", steamID: String?, enteredAccount = ""
    private var interval: TimeInterval = 5
    private var lastQR: String?
    private var failedPolls = 0
    private var codeKinds: [CodeKind] = []
    private(set) var isActive = false

    /// Platform 1 is "Steam client": its refresh token logs on to Steam's servers (library and downloads) and is what Valve's own client accepts for Dock.
    private static let platform = 1, website = "Client"

    /// Steam wants to know what kind of device is signing in: a Windows 10 PC running the Steam client.
    private func deviceDetails() -> [String: Any] {
        ["device_friendly_name": deviceName, "platform_type": Self.platform, "os_type": 16, "gaming_device_type": 1]
    }

    init(api: SteamAPI, deviceName: String = "Porthole") { self.api = api; self.deviceName = deviceName }

    private func emit(_ event: Event) { onEvent?(event) }
    private func begin() -> Int { generation += 1; isActive = true; failedPolls = 0; steamID = nil; lastQR = nil; codeKinds = []; return generation }
    private func fail(_ message: String) { isActive = false; generation += 1; emit(.failed(message)) }

    func cancel() { generation += 1; isActive = false }

    // MARK: QR

    func startQR() {
        let mine = begin()
        api.call("IAuthenticationService", "BeginAuthSessionViaQR", post: true,
                 input: ["device_friendly_name": deviceName, "platform_type": Self.platform, "website_id": Self.website, "device_details": deviceDetails()]) { [weak self] result in
            guard let self, self.generation == mine else { return }
            switch result {
            case .failure(let error): self.fail(error.description)
            case .success(let reply):
                guard let client = SteamJSON.string(reply["client_id"]), let request = SteamJSON.string(reply["request_id"]),
                      let link = SteamJSON.string(reply["challenge_url"]) else { self.fail("Steam's answer to the QR request was not understood."); return }
                self.clientID = client; self.requestID = request
                self.interval = SteamJSON.double(reply["interval"]) ?? 5
                self.lastQR = link
                self.emit(.qr(link))
                self.schedulePoll(mine)
            }
        }
    }

    // MARK: Username and password

    func startCredentials(account: String, password: String) {
        let mine = begin()
        enteredAccount = account
        api.call("IAuthenticationService", "GetPasswordRSAPublicKey", post: false, input: ["account_name": account]) { [weak self] result in
            guard let self, self.generation == mine else { return }
            switch result {
            case .failure(let error): self.fail(error.description)
            case .success(let key):
                guard let modulus = SteamJSON.string(key["publickey_mod"]), let exponent = SteamJSON.string(key["publickey_exp"]),
                      let timestamp = SteamJSON.string(key["timestamp"]),
                      let encrypted = SteamCrypto.encryptPassword(password, modulusHex: modulus, exponentHex: exponent) else {
                    self.fail("Steam did not give a usable key for this account. Check the username."); return
                }
                self.api.call("IAuthenticationService", "BeginAuthSessionViaCredentials", post: true, input: [
                    "device_friendly_name": self.deviceName, "account_name": account, "encrypted_password": encrypted,
                    "encryption_timestamp": timestamp, "remember_login": true, "platform_type": Self.platform,
                    "persistence": 1, "website_id": Self.website, "device_details": self.deviceDetails()]) { [weak self] result in
                    guard let self, self.generation == mine else { return }
                    switch result {
                    case .failure(let error): self.fail(error.description)
                    case .success(let reply): self.credentialsAccepted(reply, generation: mine)
                    }
                }
            }
        }
    }

    private func credentialsAccepted(_ reply: [String: Any], generation mine: Int) {
        guard let client = SteamJSON.string(reply["client_id"]), let request = SteamJSON.string(reply["request_id"]) else {
            fail("Steam's answer to the sign-in was not understood."); return
        }
        clientID = client; requestID = request; steamID = SteamJSON.string(reply["steamid"])
        interval = SteamJSON.double(reply["interval"]) ?? 5
        let confirmations = (reply["allowed_confirmations"] as? [[String: Any]]) ?? []
        let types = confirmations.compactMap { SteamJSON.int($0["confirmation_type"]) }
        codeKinds = (types.contains(3) ? [.device] : []) + (types.contains(2) ? [.email] : [])
        let emailHint = confirmations.first { SteamJSON.int($0["confirmation_type"]) == 2 }.flatMap { SteamJSON.string($0["associated_message"]) }
        if types.contains(4) || types.contains(3) {
            let message = types.contains(4) ? "Approve the sign-in in the Steam app on your phone, or enter the code the app shows."
                                            : "Enter the code from the Steam app on your phone."
            emit(.approve(message))
            if codeKinds.contains(.device) { emit(.needsCode(.device, "Steam Guard code from the Steam app")) }
        } else if types.contains(2) {
            emit(.approve("Steam sent a code by email" + (emailHint.map { " to \($0)" } ?? "") + "."))
            emit(.needsCode(.email, "Code from the email" + (emailHint.map { " sent to \($0)" } ?? "")))
        } else if types.contains(5) {
            emit(.approve("Steam sent you an email. Approve the sign-in from it."))
        } else if types.isEmpty || types.contains(1) {
            emit(.approve("Signing in…"))
        } else {
            emit(.approve("Waiting for Steam…"))
        }
        schedulePoll(mine)
    }

    func submitCode(_ code: String, kind: CodeKind) {
        guard isActive, !clientID.isEmpty else { return }
        let mine = generation
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        api.call("IAuthenticationService", "UpdateAuthSessionWithSteamGuardCode", post: true, input: [
            "client_id": clientID, "steamid": steamID ?? "", "code": cleaned, "code_type": kind == .device ? 3 : 2]) { [weak self] result in
            guard let self, self.generation == mine else { return }
            switch result {
            case .success: self.emit(.approve("Code sent. Signing in…")); self.pollNow(mine)
            case .failure(let error):
                if [65, 88, 89].contains(error.eresult ?? 0) { self.emit(.codeRejected(error.description)) } else { self.fail(error.description) }
            }
        }
    }

    // MARK: Polling

    private func schedulePoll(_ mine: Int) {
        let delay = pollIntervalOverride ?? max(1, interval)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pollNow(mine) }
    }

    private func pollNow(_ mine: Int) {
        guard generation == mine, isActive else { return }
        api.call("IAuthenticationService", "PollAuthSessionStatus", post: true, input: ["client_id": clientID, "request_id": requestID]) { [weak self] result in
            guard let self, self.generation == mine else { return }
            switch result {
            case .failure(let error):
                // A hiccup in the network is retried a few times; an answer from Steam (expired, refused) is final.
                if error.eresult == nil, error.http == nil, self.failedPolls < 4 { self.failedPolls += 1; self.schedulePoll(mine) }
                else { self.fail(error.description) }
            case .success(let reply):
                self.failedPolls = 0
                if let refresh = SteamJSON.string(reply["refresh_token"]), !refresh.isEmpty { self.finish(reply, refreshToken: refresh); return }
                if let link = SteamJSON.string(reply["new_challenge_url"]), link != self.lastQR {
                    self.lastQR = link; self.emit(.qr(link))
                    if let id = SteamJSON.string(reply["new_client_id"]) { self.clientID = id }
                }
                if reply["had_remote_interaction"] as? Bool == true, self.lastQR != nil { self.emit(.approve("Scanned. Approve the sign-in in the Steam app.")) }
                self.schedulePoll(mine)
            }
        }
    }

    private func finish(_ reply: [String: Any], refreshToken: String) {
        guard let id = steamID ?? SteamJWT.subject(refreshToken), !id.isEmpty else { fail("Steam signed in but did not say which account."); return }
        let account = SteamJSON.string(reply["account_name"]) ?? (enteredAccount.isEmpty ? "Steam account" : enteredAccount)
        let session = SteamAccountSession(steamID: id, accountName: account, refreshToken: refreshToken, accessToken: SteamJSON.string(reply["access_token"]))
        isActive = false; generation += 1
        emit(.signedIn(session))
    }
}

// MARK: - The signed-in account

struct SteamGame: Codable, Equatable, Identifiable {
    var appid: Int
    var name: String
    var playtimeMinutes: Int
    var lastPlayed: Date?
    var id: Int { appid }
}

final class SteamAccount {
    let api: SteamAPI
    private let store: SteamSessionStore
    private(set) var session: SteamAccountSession?

    init(api: SteamAPI, store: SteamSessionStore) { self.api = api; self.store = store; session = store.load() }

    var isSignedIn: Bool { session != nil }
    var displayName: String? { session?.accountName }

    func adopt(_ session: SteamAccountSession) { self.session = session; store.save(session) }
    func signOut() { session = nil; store.clear() }

    /// A working access token: the one we hold if it has time left, otherwise a new one made from the refresh token.
    func accessToken(forceRefresh: Bool, completion: @escaping (Result<String, SteamAPIError>) -> Void) {
        guard var current = session else { completion(.failure(.notSignedIn)); return }
        if !forceRefresh, let token = current.accessToken, !SteamJWT.isExpired(token) { completion(.success(token)); return }
        api.call("IAuthenticationService", "GenerateAccessTokenForApp", post: true,
                 input: ["refresh_token": current.refreshToken, "steamid": current.steamID]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error.isSessionOver { SteamLog.event("Steam: the saved sign-in is no longer accepted; signing out."); self.signOut() }
                completion(.failure(error))
            case .success(let reply):
                guard let token = SteamJSON.string(reply["access_token"]), !token.isEmpty else {
                    completion(.failure(.unexpected("Steam did not give a new access token."))); return
                }
                current.accessToken = token
                if let renewed = SteamJSON.string(reply["refresh_token"]), !renewed.isEmpty { current.refreshToken = renewed }
                self.session = current; self.store.save(current)
                completion(.success(token))
            }
        }
    }

    /// The games this account owns, with hours played. Falls back to a fresh token once if Steam refuses the one it has.
    func ownedGames(completion: @escaping (Result<[SteamGame], SteamAPIError>) -> Void) {
        func attempt(forceRefresh: Bool) {
            accessToken(forceRefresh: forceRefresh) { [weak self] tokenResult in
                guard let self, let session = self.session else { completion(.failure(.notSignedIn)); return }
                switch tokenResult {
                case .failure(let error): completion(.failure(error))
                case .success(let token):
                    self.api.call("IPlayerService", "GetOwnedGames", post: false, input: [
                        "steamid": session.steamID, "include_appinfo": true, "include_played_free_games": true,
                        "include_free_sub": true, "skip_unvetted_apps": false, "language": "english"], accessToken: token) { result in
                        switch result {
                        case .failure(let error) where error.isTokenRefusal && !forceRefresh: attempt(forceRefresh: true)
                        case .failure(let error): completion(.failure(error))
                        case .success(let reply): completion(.success(Self.parseGames(reply)))
                        }
                    }
                }
            }
        }
        attempt(forceRefresh: false)
    }

    static func parseGames(_ reply: [String: Any]) -> [SteamGame] {
        let items = (reply["games"] as? [[String: Any]]) ?? []
        var seen = Set<Int>()
        return items.compactMap { item -> SteamGame? in
            guard let appid = SteamJSON.int(item["appid"]), seen.insert(appid).inserted else { return nil }
            let name = SteamJSON.string(item["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? "App \(appid)"
            let last = SteamJSON.double(item["rtime_last_played"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return SteamGame(appid: appid, name: name, playtimeMinutes: SteamJSON.int(item["playtime_forever"]) ?? 0, lastPlayed: last)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
