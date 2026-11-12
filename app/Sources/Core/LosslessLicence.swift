// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CryptoKit

/// How Porthole makes sure Lossless Scaling's file is only ever used by someone who bought it. Foundation and CryptoKit only; app/Tests/Licence runs it.
///
/// The design (written down here so the developer of Lossless Scaling can read exactly what it does):
///  1. **Ownership comes from Steam.** The signed-in account's licence list (Steam's servers) must hold an active licence for app 993090. That is checked online; the result is kept as a
///     *receipt* with the account's SteamID and the time, signed with a key that exists only on this device (HMAC-SHA256, key in the Keychain, this device only).
///  2. **The file only comes from Steam.** Porthole downloads Lossless Scaling's depot with the user's own account (Steam gives the depot key only to a licensed account), keeps nothing
///     of it but `Lossless.dll`, and offers no way to import a file from anywhere else.
///  3. **The file is sealed.** The DLL is stored encrypted (AES-GCM) with a key made from a secret that exists only on this device and the account's SteamID. It is decrypted in memory
///     only, and only while the receipt is valid.
///  4. **The receipt runs out.** It must be renewed online every `graceDays` days (a refund or a revoked licence stops the feature at the next check), a receipt that was edited does not
///     verify, a receipt for another account does not open the file, and a clock set back does not extend it.
/// What this cannot do: Porthole is open source and runs on a device its owner controls, so someone who builds a modified copy, or reads the decrypted file out of memory with a debugger,
/// is not stopped. It makes the normal path need a purchase; it is not copy protection that withstands that.
enum LosslessLicence {
    /// Lossless Scaling's Steam app id.
    static let appID = 993090
    /// How long a verified receipt keeps the feature working without the device being online.
    static let graceDays = 7

    struct Receipt: Codable, Equatable {
        var appID: Int
        var steamID: String
        /// When Steam's licence list last showed the licence.
        var verifiedAt: Date
        /// The latest time the receipt was checked at all (it only moves forward): a clock set back below it is noticed.
        var lastSeen: Date
        /// Hex of the HMAC over the fields above.
        var mac: String
    }

    enum Status: Equatable {
        /// Usable, and for how many more whole days without going online.
        case valid(daysLeft: Int)
        /// The week is up: go online and check again.
        case expired
        /// The receipt was changed, or the device's clock was set back.
        case tampered
        /// The receipt belongs to another Steam account than the one signed in.
        case otherAccount
    }

    // MARK: Receipt

    private static func message(_ r: Receipt) -> Data {
        Data("\(r.appID)|\(r.steamID)|\(Int64(r.verifiedAt.timeIntervalSince1970))|\(Int64(r.lastSeen.timeIntervalSince1970))".utf8)
    }

    static func mac(_ r: Receipt, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: message(r), using: key)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh receipt: Steam's licence list showed the licence just now.
    static func issue(steamID: String, now: Date, key: SymmetricKey) -> Receipt {
        var r = Receipt(appID: appID, steamID: steamID, verifiedAt: now, lastSeen: now, mac: "")
        r.mac = mac(r, key: key)
        return r
    }

    /// What a receipt allows now. `signedInSteamID`: the account that is signed in (nil while signed out or offline: the receipt's own account is then the one in use).
    static func status(of r: Receipt, now: Date, signedInSteamID: String?, key: SymmetricKey) -> Status {
        guard r.appID == appID, mac(r, key: key) == r.mac else { return .tampered }
        if let signedInSteamID, signedInSteamID != r.steamID { return .otherAccount }
        // A clock set back: before the last time the receipt was seen (a day of slack for time zones and corrections), or a licence "verified" in the future.
        if now < r.lastSeen.addingTimeInterval(-86_400) || r.verifiedAt > now.addingTimeInterval(86_400) { return .tampered }
        let age = now.timeIntervalSince(r.verifiedAt)
        if age > Double(graceDays) * 86_400 { return .expired }
        return .valid(daysLeft: max(0, graceDays - Int(age / 86_400)))
    }

    /// The receipt after a use: `lastSeen` moves forward (never back) and the MAC is made again.
    static func seen(_ r: Receipt, now: Date, key: SymmetricKey) -> Receipt {
        var out = r
        out.lastSeen = max(r.lastSeen, now)
        out.mac = mac(out, key: key)
        return out
    }

    // MARK: Sealed file

    enum VaultError: Error { case sealFailed, opened(String) }

    /// The key the DLL is sealed with: made from this device's secret and the account's SteamID, so the file does not open for another account or on another device.
    static func vaultKey(deviceSecret: SymmetricKey, steamID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: deviceSecret, salt: Data(steamID.utf8), info: Data("porthole-lossless-scaling-file".utf8), outputByteCount: 32)
    }

    static func seal(_ file: Data, deviceSecret: SymmetricKey, steamID: String) throws -> Data {
        let box = try AES.GCM.seal(file, using: vaultKey(deviceSecret: deviceSecret, steamID: steamID), authenticating: Data("\(appID)".utf8))
        guard let combined = box.combined else { throw VaultError.sealFailed }
        return combined
    }

    static func open(_ sealed: Data, deviceSecret: SymmetricKey, steamID: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: vaultKey(deviceSecret: deviceSecret, steamID: steamID), authenticating: Data("\(appID)".utf8))
        } catch { throw VaultError.opened("\(error)") }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
