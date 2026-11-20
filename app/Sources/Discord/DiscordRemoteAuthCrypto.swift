// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// The cryptography of Discord's QR-code login ("remote authentication"), on its own so a Mac test can run it (app/Tests/DiscordAuth). Foundation, Security and CryptoKit only.
//
// The login, as the community-maintained documentation of Discord's user API describes it: the client makes an RSA-2048 key pair and sends the public half (as an X.509
// SubjectPublicKeyInfo, base64). Discord answers with a nonce encrypted to that key (RSA-OAEP, SHA-256); the client decrypts it and returns base64url(SHA-256(nonce)) as the
// proof. Discord then gives a fingerprint to show as a QR code; the person scans it with the Discord app on another device, which sends their name and picture (encrypted to
// the same key) and, once they confirm, a ticket. The ticket is traded at the login endpoint for the account token, encrypted to the same key once more.

import Foundation
import Security
import CryptoKit

enum DiscordRemoteAuthError: Error, Equatable {
    case keyGeneration
    case decrypt
    case badPayload
}

struct DiscordRemoteAuthCrypto {
    private let privateKey: SecKey
    private let publicKey: SecKey

    /// The DER prefix that turns an RSA-2048 PKCS#1 public key into a SubjectPublicKeyInfo.
    static let spkiPrefix: [UInt8] = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00]

    init() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let pub = SecKeyCopyPublicKey(key) else { throw DiscordRemoteAuthError.keyGeneration }
        privateKey = key
        publicKey = pub
    }

    /// The public key as base64 of a SubjectPublicKeyInfo: what Discord's `init` message carries.
    var encodedPublicKey: String {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return "" }
        return (Data(Self.spkiPrefix) + pkcs1).base64EncodedString()
    }

    /// Decrypts what Discord encrypted to the public key (the base64 text is the cipher text).
    func decrypt(base64 text: String) throws -> Data {
        guard let cipher = Data(base64Encoded: text) else { throw DiscordRemoteAuthError.badPayload }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, cipher as CFData, &error) as Data? else { throw DiscordRemoteAuthError.decrypt }
        return plain
    }

    /// The proof for a nonce: base64url, no padding, of its SHA-256.
    static func proof(forNonce nonce: Data) -> String {
        let digest = Data(SHA256.hash(data: nonce))
        return digest.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// What the scanned QR code shows: Discord's own "ra" link for the fingerprint.
    static func qrURL(fingerprint: String) -> URL? { URL(string: "https://discord.com/ra/" + fingerprint) }

    /// The person who scanned the code, from the decrypted `id:discriminator:avatar:username`.
    struct ScannedUser: Equatable {
        var id: String
        var discriminator: String
        var avatar: String
        var username: String
        var display: String { discriminator == "0" || discriminator.isEmpty ? username : username + "#" + discriminator }
    }

    static func scannedUser(from plain: Data) -> ScannedUser? {
        guard let text = String(data: plain, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        return ScannedUser(id: parts[0], discriminator: parts[1], avatar: parts[2], username: parts[3])
    }
}
