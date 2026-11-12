// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import Network
import CryptoKit

/// Pair this iPhone with itself so the app can enable JIT without a computer.
///
/// Starting with iOS 27 a device can start pairing from its own Settings (Privacy & Security > Developer Mode > "Pair with <name>"). It looks for
/// computers advertising `_remotepairing-pairable-host._tcp` on the local network, connects to the one the person picks, and the two run Apple's
/// remote-pairing conversation: a handshake, then an SRP pair-setup in which the host shows a six-digit code and the person types it into the device.
/// The result is a pairing file (our long-term Ed25519 key and identifier) that the debugger later uses to prove it is the paired host.
///
/// This is a Swift implementation of the host ("pairable host") side. The protocol was worked out by the idevice project (Jackson Coxson) and shown to
/// work on iPhones by the StikPair app (StephenDev0 / StikDebug team); see PairingCredits. Their code is not used here.
final class RemotePairingHost: @unchecked Sendable {
    struct Result {
        var pairingFile: Data            // XML plist: public_key, private_key, identifier, alt_irk
        var deviceName: String
        var deviceModel: String
    }

    /// What the device displays after "Pair with ...".
    let displayName: String
    private let model = "Mac17,7"        // the device treats the host as a computer
    private let advertise: Bool
    private let queue = DispatchQueue(label: "f4.pairing")

    /// Called (on an arbitrary queue) when the Bonjour record is published and the device can find us.
    var onAdvertising: (@Sendable () -> Void)?
    /// Called with the six-digit code to show the person.
    var onPIN: (@Sendable (String) -> Void)?
    /// Called when the Local Network permission or the network itself blocks advertising.
    var onBlocked: (@Sendable (String) -> Void)?
    /// Step-by-step trace of the conversation (no secrets), for the log and the pairing screen.
    var onLog: (@Sendable (String) -> Void)?
    /// A conversation failed but the host keeps listening for another try (the person can tap "Pair with" again).
    var onAttemptFailed: (@Sendable (String) -> Void)?
    private let clock = Date()
    private func log(_ text: String) { onLog?(String(format: "[+%.1fs] ", Date().timeIntervalSince(clock)) + text) }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var cancelled = false
    private var sequence = 0

    init(displayName: String, advertise: Bool = true) { self.displayName = displayName; self.advertise = advertise }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            listener?.cancel(); connection?.cancel()
        }
    }

    // MARK: Entry point

    func run(portOut: (@Sendable (UInt16) -> Void)? = nil) async throws -> Result {
        let signing = Curve25519.Signing.PrivateKey()
        let identifier = PairingIdentity.uuidV3(dnsName: displayName)
        let altIRK = (0..<16).map { _ in UInt8.random(in: 0...255) }

        let (listener, connections) = try makeListener(identifier: identifier, altIRK: altIRK, portOut: portOut)
        self.listener = listener
        defer { listener.cancel() }

        var wrongCodes = 0          // anyone on the network can connect while this listens: a few wrong codes end it
        var nextSetup = Task.detached(priority: .userInitiated) { Self.makeSetup() }

        // The iPhone may open more than one connection (a probe first, or both IPv4 and IPv6), so keep listening until one conversation succeeds.
        for try await conn in connections {
            if cancelled { throw PairingError.cancelled }
            log("connection from \(conn.endpoint)")
            connection = conn
            sequence = 0
            do {
                try await waitReady(conn)
                log("connection ready")
                try await handshake()
                log("handshake done")
                let setup = await nextSetup.value
                nextSetup = Task.detached(priority: .userInitiated) { Self.makeSetup() }          // the next try gets a fresh code, ready in advance
                let peer = try await pairSetup(signing: signing, identifier: identifier, altIRK: altIRK, setup: setup)
                conn.cancel()

                var plist: [String: Any] = [
                    "public_key": Data(signing.publicKey.rawRepresentation),
                    "private_key": Data(signing.rawRepresentation),
                    "identifier": identifier,
                ]
                if let irk = peer.altIRK { plist["alt_irk"] = Data(irk) }
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                log("paired")
                return Result(pairingFile: data, deviceName: peer.name, deviceModel: peer.model)
            } catch PairingError.cancelled {
                conn.cancel(); throw PairingError.cancelled
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? ErrorText.plain(error)
                log("conversation failed: \(why)")
                conn.cancel()
                if case PairingError.wrongPIN = error {
                    wrongCodes += 1
                    if wrongCodes >= 5 { throw PairingError.unexpected("Too many wrong codes. Pairing was stopped; start it again.") }
                }
                onAttemptFailed?(why)
            }
        }
        throw cancelled ? PairingError.cancelled : PairingError.network("The network listener stopped.")
    }

    private func waitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; cont.resume()
                case .failed(let e): done = true; cont.resume(throwing: PairingError.network(ErrorText.plain(e)))
                case .cancelled: done = true; cont.resume(throwing: PairingError.cancelled)
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    // MARK: Listening

    private func makeListener(identifier: String, altIRK: [UInt8], portOut: (@Sendable (UInt16) -> Void)?) throws -> (NWListener, AsyncThrowingStream<NWConnection, Error>) {
        let listener = try NWListener(using: .tcp)
        if advertise {
            let tag = Data(PairingIdentity.authTag(altIRK: altIRK, serviceIdentifier: identifier)).base64EncodedString()
            var txt = NWTXTRecord()
            for (k, v) in [("name", displayName), ("identifier", identifier), ("authTag", tag), ("model", model), ("flags", "1"), ("ver", "26"), ("minVer", "17")] {
                txt[k] = v
            }
            listener.service = NWListener.Service(name: identifier, type: "_remotepairing-pairable-host._tcp", txtRecord: txt)
        }
        let stream = AsyncThrowingStream<NWConnection, Error> { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { portOut?(port); self?.log("listening on port \(port)") }
                    if self?.advertise == true { self?.onAdvertising?() }
                case .failed(let error):
                    self?.log("listener failed: \(error)")
                    self?.onBlocked?(ErrorText.plain(error))
                    continuation.finish(throwing: PairingError.network(ErrorText.plain(error)))
                case .waiting(let error):
                    self?.log("listener waiting: \(error)")
                    self?.onBlocked?(ErrorText.plain(error))
                case .cancelled:
                    continuation.finish()
                default: break
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in self?.log("bonjour: \(change)") }
            listener.newConnectionHandler = { conn in continuation.yield(conn) }
            continuation.onTermination = { _ in listener.cancel() }
            listener.start(queue: queue)
        }
        return (listener, stream)
    }

    // MARK: Framing ("RPPairing" + 16-bit big-endian length + JSON)

    private static let magic = Array("RPPairing".utf8)

    private func receiveChunk(max: Int) async throws -> [UInt8] {
        guard let conn = connection else { throw PairingError.cancelled }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error { cont.resume(throwing: PairingError.network(ErrorText.plain(error))) }
                else if let data, !data.isEmpty { cont.resume(returning: [UInt8](data)) }
                else if isComplete { cont.resume(throwing: PairingError.network("The iPhone closed the connection.")) }
                else { cont.resume(throwing: PairingError.network("The connection ended.")) }
            }
        }
    }

    private func receiveExactly(_ n: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < n { out += try await receiveChunk(max: n - out.count) }
        return out
    }

    private func sendBytes(_ bytes: [UInt8]) async throws {
        guard let conn = connection else { throw PairingError.cancelled }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: PairingError.network(ErrorText.plain(error))) } else { cont.resume() }
            })
        }
    }

    /// Wraps `value` as {"message":{"plain":{"_0":value}},"originatedBy":"device","sequenceNumber":n} and sends it.
    private func sendPlain(_ value: Any) async throws {
        let envelope: [String: Any] = ["message": ["plain": ["_0": value]], "originatedBy": "device", "sequenceNumber": sequence]
        sequence += 1
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes])
        log("sending \(json.count) bytes")
        guard json.count <= 0xFFFF else { throw PairingError.unexpected("message too large") }
        try await sendBytes(Self.magic + [UInt8(json.count >> 8), UInt8(json.count & 0xFF)] + [UInt8](json))
    }

    /// Reads one frame and returns `message.plain._0` (or the whole message if it is not a plain one).
    private func receivePlain() async throws -> [String: Any] {
        let magic = try await receiveExactly(Self.magic.count)
        guard magic == Self.magic else { throw PairingError.malformed("bad frame marker") }
        let lengthBytes = try await receiveExactly(2)
        let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
        let body = try await receiveExactly(length)
        guard let object = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { throw PairingError.malformed("not a JSON object") }
        log("received \(length) bytes: \(summary(object))")
        if let message = object["message"] as? [String: Any], let plain = message["plain"] as? [String: Any], let value = plain["_0"] as? [String: Any] { return value }
        return object
    }

    /// A short description of a message for the trace: handshake requests in full (they hold no secrets), pairing data as TLV types and sizes.
    private func summary(_ object: [String: Any]) -> String {
        if let b64 = dig(object, "message", "plain", "_0", "event", "_0", "pairingData", "_0", "data") as? String, let d = Data(base64Encoded: b64),
           let tlv = try? PairingTLV.parse([UInt8](d)) {
            return "pairingData " + tlv.map { "\($0.type)(\($0.data.count))" }.joined(separator: " ")
        }
        if let d = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), let t = String(data: d, encoding: .utf8) { return String(t.prefix(700)) }
        return "?"
    }

    private func dig(_ root: [String: Any], _ path: String...) -> Any? {
        var current: Any = root
        for key in path { guard let d = current as? [String: Any], let next = d[key] else { return nil }; current = next }
        return current
    }

    // MARK: Conversation

    /// The device opens with a handshake request; we answer with what we are and what we allow.
    private func handshake() async throws {
        let request = try await receivePlain()
        guard let hs = dig(request, "request", "_0", "handshake", "_0") as? [String: Any] else {
            throw PairingError.unexpected("no handshake request")
        }
        if (dig(hs, "hostOptions", "attemptPairVerify") as? Bool) == true {
            throw PairingError.unexpected("the iPhone wants to re-verify an existing pairing; only a new pairing is supported")
        }
        let response: [String: Any] = [
            "response": [
                "forRequestIdentifier": 0,
                "_1": ["handshake": ["_0": [
                    "wireProtocolVersion": 26,
                    "minimumSupportedWireProtocolVersion": 8,
                    "deviceOptions": [
                        "allowsPairSetup": true,
                        "allowsPinlessPairing": false,
                        "allowsIncomingTunnelConnections": false,
                        "allowsUpgradeOfLockdownPairings": false,
                        "allowsSharingSensitiveInfo": false,
                    ],
                    "peerDeviceInfo": [
                        "udid": "",
                        "deviceKVSIncludesSensitiveInfo": false,
                        "identifier": "",
                        "name": displayName,
                        "model": model,
                    ],
                ]]],
            ]
        ]
        try await sendPlain(response)
    }

    private func sendTLV(_ entries: [PairingTLV]) async throws {
        let event: [String: Any] = ["event": ["_0": ["pairingData": ["_0": [
            "data": Data(PairingTLV.serialize(entries)).base64EncodedString(),
            "startNewSession": false,
            "kind": "setupManualPairing",
        ]]]]]
        try await sendPlain(event)
    }

    private func receiveTLV() async throws -> [PairingTLV] {
        let message = try await receivePlain()
        guard let b64 = dig(message, "event", "_0", "pairingData", "_0", "data") as? String, let data = Data(base64Encoded: b64) else {
            throw PairingError.unexpected("no pairing data in the message")
        }
        return try PairingTLV.parse([UInt8](data))
    }

    private func expect(_ entries: [PairingTLV], state: UInt8) throws {
        if let error = entries.first(where: { $0.type == .errorResponse }) { throw PairingError.unexpected("the iPhone reported error \(error.data)") }
        guard entries.first(where: { $0.type == .state })?.data.first == state else { throw PairingError.unexpected("expected pair-setup step \(state)") }
    }

    /// One attempt's secrets, worked out ahead of time: the big-number maths takes a moment and the iPhone should never wait for it.
    private struct Setup { let pin: String; let salt: [UInt8]; let verifier: [UInt8]; let b: [UInt8]; let bPublic: [UInt8] }
    private static let srp = SRP3072Server()
    private static let username = Array("Pair-Setup".utf8)

    private static func makeSetup() -> Setup {
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let verifier = srp.verifier(username: username, password: Array(pin.utf8), salt: salt)
        var b: [UInt8], bPublic: [UInt8]
        repeat {
            b = (0..<32).map { _ in UInt8.random(in: 0...255) }
            bPublic = srp.publicValue(privateB: b, verifier: verifier)
        } while bPublic.count != 384
        return Setup(pin: pin, salt: salt, verifier: verifier, b: b, bPublic: bPublic)
    }

    private struct Peer { var name: String; var model: String; var altIRK: [UInt8]? }

    private func pairSetup(signing: Curve25519.Signing.PrivateKey, identifier: String, altIRK: [UInt8], setup: Setup) async throws -> Peer {
        // M1: the device starts pair-setup.
        let m1 = try await receiveTLV()
        try expect(m1, state: 1)

        // M2: salt and our public value, derived from a fresh six-digit code that the person types into the device.
        let srp = Self.srp, username = Self.username
        let salt = setup.salt, verifier = setup.verifier, b = setup.b, bPublic = setup.bPublic, pin = setup.pin
        log("pair-setup started; sending salt and public value")
        onPIN?(pin)
        try await sendTLV([PairingTLV(type: .state, data: [2]), PairingTLV(type: .salt, data: salt)] + PairingTLV.chunked(.publicKey, bPublic))

        // M3: the device's public value and proof. A wrong code fails here.
        let m3 = try await receiveTLV()
        try expect(m3, state: 3)
        let clientPublic = PairingTLV.joined(m3, .publicKey), clientProof = PairingTLV.joined(m3, .proof)
        guard !clientPublic.isEmpty, !clientProof.isEmpty else { throw PairingError.unexpected("pair-setup step 3 is incomplete") }
        let session = try srp.process(privateB: b, publicB: bPublic, verifier: verifier, clientPublic: clientPublic, username: username, salt: salt)
        log("client proof received (A \(clientPublic.count) bytes)")
        guard Self.constantTimeEqual(session.clientProof, clientProof) else {
            try? await sendTLV([PairingTLV(type: .state, data: [4]), PairingTLV(type: .errorResponse, data: [2])])
            throw PairingError.wrongPIN
        }

        // M4: our proof.
        try await sendTLV([PairingTLV(type: .state, data: [4])] + PairingTLV.chunked(.proof, session.serverProof))

        let key = SymmetricKey(data: session.key)
        let setupKey = HKDF<SHA512>.deriveKey(inputKeyMaterial: key, salt: Data("Pair-Setup-Encrypt-Salt".utf8),
                                              info: Data("Pair-Setup-Encrypt-Info".utf8), outputByteCount: 32)

        // M5: the device's identity, encrypted.
        let m5 = try await receiveTLV()
        try expect(m5, state: 5)
        let sealed = PairingTLV.joined(m5, .encryptedData)
        guard sealed.count > 16 else { throw PairingError.unexpected("pair-setup step 5 is empty") }
        let nonce5 = try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0] + Array("PS-Msg05".utf8)))
        let box5 = try ChaChaPoly.SealedBox(nonce: nonce5, ciphertext: Data(sealed.dropLast(16)), tag: Data(sealed.suffix(16)))
        let plain5: Data
        do { plain5 = try ChaChaPoly.open(box5, using: setupKey) } catch { throw PairingError.unexpected("could not decrypt the iPhone's identity") }
        let identity = try PairingTLV.parse([UInt8](plain5))
        var peer = Peer(name: "this iPhone", model: "", altIRK: nil)
        if let info = try? OPACK.decode(PairingTLV.joined(identity, .info)) {
            if let name = info["name"]?.stringValue, !name.isEmpty { peer.name = name }
            peer.model = info["model"]?.stringValue ?? ""
            peer.altIRK = info["altIRK"]?.dataValue
        }

        // M6: our identity: identifier, long-term public key, a signature binding them to this session, and some descriptive info.
        let accessoryX = HKDF<SHA512>.deriveKey(inputKeyMaterial: key, salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
                                                info: Data("Pair-Setup-Accessory-Sign-Info".utf8), outputByteCount: 32)
        let publicKey = [UInt8](signing.publicKey.rawRepresentation)
        let signed = accessoryX.withUnsafeBytes { Array($0) } + Array(identifier.utf8) + publicKey
        let signature = [UInt8](try signing.signature(for: Data(signed)))
        let info = OPACK.encode(.dict([
            ("altIRK", .data(altIRK)),
            ("btAddr", .string("11:22:33:44:55:66")),
            ("mac", .data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])),
            ("remotepairing_serial_number", .string("AAAAAAAAAAAA")),
            ("accountID", .string(identifier)),
            ("remotepairing_udid", .string("")),
            ("model", .string(model)),
            ("name", .string(displayName)),
        ]))
        let plain6 = PairingTLV.serialize(
            [PairingTLV(type: .identifier, data: Array(identifier.utf8)), PairingTLV(type: .publicKey, data: publicKey), PairingTLV(type: .signature, data: signature)]
            + PairingTLV.chunked(.info, info))
        let nonce6 = try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0] + Array("PS-Msg06".utf8)))
        let box6 = try ChaChaPoly.seal(Data(plain6), using: setupKey, nonce: nonce6)
        try await sendTLV(PairingTLV.chunked(.encryptedData, [UInt8](box6.ciphertext) + [UInt8](box6.tag)) + [PairingTLV(type: .state, data: [6])])
        return peer
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
