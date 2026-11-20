// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Signs in by QR code, the way the community-maintained documentation of Discord's user API describes it (see DiscordRemoteAuthCrypto for the steps). The person scans the code
/// with the Discord app on another device and confirms there; this ends with the account token, which goes to the Keychain (DiscordSession) and is never logged.
///
/// Discord's remote-authentication server only answers a connection that names `https://discord.com` as its origin, so that one header is sent here; every request also says
/// what Porthole is in its User-Agent.
@MainActor
final class DiscordRemoteAuth {
    enum Event: Equatable {
        case qr(URL)
        case scanned(String)
        case token(String)
        case failed(String)
        case cancelled
    }

    var onEvent: ((Event) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var crypto: DiscordRemoteAuthCrypto?
    private var heartbeat: Task<Void, Never>?
    private var finished = false
    /// No sign-in by QR code is under way.
    var isIdle: Bool { finished || task == nil }

    func start() {
        finished = false
        do { crypto = try DiscordRemoteAuthCrypto() } catch { finish(.failed("Could not make a key for the sign-in.")); return }
        var request = URLRequest(url: URL(string: "wss://remote-auth-gateway.discord.gg/?v=2")!)
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        Task { await receiveLoop(task) }
    }

    func cancel() {
        guard !finished else { return }
        finish(.cancelled)
    }

    private func finish(_ event: Event) {
        guard !finished else { return }
        finished = true
        heartbeat?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        crypto = nil
        onEvent?(event)
    }

    private func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !finished {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): await handle(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { await handle(text) }
                @unknown default: break
                }
            } catch {
                if !finished { finish(.failed("The connection to Discord's sign-in closed. Try again.")) }
                return
            }
        }
    }

    private func handle(_ text: String) async {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let op = object["op"] as? String, let crypto else { return }
        switch op {
        case "hello":
            let interval = (object["heartbeat_interval"] as? Double ?? 40000) / 1000
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { return }
                    await MainActor.run { self?.send(["op": "heartbeat"]) }
                }
            }
            send(["op": "init", "encoded_public_key": crypto.encodedPublicKey])
        case "nonce_proof":
            guard let encrypted = object["encrypted_nonce"] as? String, let nonce = try? crypto.decrypt(base64: encrypted) else { finish(.failed("Discord's sign-in answered in a way this version cannot read.")); return }
            send(["op": "nonce_proof", "proof": DiscordRemoteAuthCrypto.proof(forNonce: nonce)])
        case "pending_remote_init":
            guard let fingerprint = object["fingerprint"] as? String, let url = DiscordRemoteAuthCrypto.qrURL(fingerprint: fingerprint) else { finish(.failed("Discord did not give a code to show.")); return }
            onEvent?(.qr(url))
        case "pending_ticket":
            if let encrypted = object["encrypted_user_payload"] as? String, let plain = try? crypto.decrypt(base64: encrypted), let user = DiscordRemoteAuthCrypto.scannedUser(from: plain) {
                onEvent?(.scanned(user.display))
            } else {
                onEvent?(.scanned("someone"))
            }
        case "pending_login":
            guard let ticket = object["ticket"] as? String else { finish(.failed("Discord did not finish the sign-in.")); return }
            await exchange(ticket: ticket, crypto: crypto)
        case "cancel":
            finish(.cancelled)
        default:
            break   // heartbeat_ack and anything newer
        }
    }

    /// The ticket becomes the account token at the login address; the token comes back encrypted to our key.
    private func exchange(ticket: String, crypto: DiscordRemoteAuthCrypto) async {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v9/users/@me/remote-auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ticket": ticket])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let encrypted = body?["encrypted_token"] as? String, let plain = try? crypto.decrypt(base64: encrypted), let token = String(data: plain, encoding: .utf8), !token.isEmpty {
                finish(.token(token))
            } else if body?["captcha_key"] != nil {
                finish(.failed("Discord asked for a captcha, which this version cannot show. Try again later."))
            } else {
                finish(.failed("Discord refused the sign-in (\(status))."))
            }
        } catch {
            finish(.failed("Could not reach Discord to finish the sign-in."))
        }
    }
}
