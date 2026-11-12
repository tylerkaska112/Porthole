// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit
import CryptoKit
import Security

/// The part of Porthole that deals with Lossless Scaling's Steam licence (the design is in LosslessLicence.swift). It checks the signed-in account's licence list, downloads Lossless
/// Scaling from Steam with that account, seals its `Lossless.dll` on this device, and gives the file back only while the licence receipt is valid. Nothing in Porthole runs Lossless
/// Scaling's code yet: this is the licence gate and the file's safe, built first so that the developer of Lossless Scaling can see how it is protected.
@MainActor
final class LosslessScaling: ObservableObject {
    static let shared = LosslessScaling()

    /// What the page shows.
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    /// nil: not known yet (never checked, or signed out). true/false: what Steam's licence list said at the last check.
    @Published private(set) var owned: Bool?
    @Published private(set) var receipt: LosslessLicence.Receipt?
    @Published private(set) var fileBytes: Int?

    private let fm = FileManager.default
    private var root: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LosslessScaling", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var sealedURL: URL { root.appendingPathComponent("Lossless.dll.sealed") }
    private var receiptURL: URL { root.appendingPathComponent("licence.json") }

    private init() { reload() }

    // MARK: Device secret

    /// A random secret that exists only on this device (Keychain, this device only, after first unlock). Everything else is made from it.
    private func deviceSecret() -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "site.portholehq.lossless-scaling", kSecAttrAccount as String: "device"]
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }

    private func receiptKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: deviceSecret(), salt: Data(), info: Data("porthole-lossless-scaling-receipt".utf8), outputByteCount: 32)
    }

    // MARK: State

    var signedIn: Bool { SteamService.shared.isSignedIn }
    var accountName: String? { SteamService.shared.accountName }
    var installed: Bool { fileBytes != nil }

    /// What the stored receipt allows now.
    var status: LosslessLicence.Status? {
        guard let receipt else { return nil }
        return LosslessLicence.status(of: receipt, now: Date(), signedInSteamID: SteamService.shared.steamIDText, key: receiptKey())
    }

    /// True when the feature may open the file: it is stored, and the receipt is valid for the account in use.
    var usable: Bool { if installed, case .valid? = status { return true } else { return false } }

    func reload() {
        receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(LosslessLicence.Receipt.self, from: $0) }
        fileBytes = (try? fm.attributesOfItem(atPath: sealedURL.path)[.size] as? Int) ?? nil
    }

    private func save(_ r: LosslessLicence.Receipt) {
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: receiptURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        receipt = r
    }

    // MARK: Checking the licence

    /// Asks Steam, over the network, whether the signed-in account has an active licence for Lossless Scaling, and writes a fresh receipt when it has.
    /// A refund or a revoked licence is noticed here: the stored file is removed.
    @discardableResult
    func verify() async -> Bool {
        guard signedIn, let steamID = SteamService.shared.steamIDText else { message = "Sign in to Steam first (Stores > Steam)."; return false }
        guard busy == nil else { return false }
        busy = "Checking your Steam purchase\u{2026}"; message = nil
        defer { busy = nil }
        do {
            let apps = try await SteamService.shared.ownedApps()
            if apps.contains(where: { $0.appid == LosslessLicence.appID }) {
                owned = true
                save(LosslessLicence.issue(steamID: steamID, now: Date(), key: receiptKey()))
                LogStore.shared.log("[lossless] Steam lists Lossless Scaling on this account: receipt renewed")
                return true
            }
            owned = false
            if installed || receipt != nil {
                remove()
                message = "This Steam account has no licence for Lossless Scaling any more, so the stored file was removed."
            } else {
                message = "This Steam account does not own Lossless Scaling. Buy it on Steam, then check again."
            }
            LogStore.shared.log("[lossless] Steam does not list Lossless Scaling on this account")
            return false
        } catch {
            message = ErrorText.plain(error, doing: "Checking your Steam purchase")
            return false
        }
    }

    // MARK: The file

    /// Downloads Lossless Scaling from Steam with the user's own account (Steam only releases the files to a licensed account), keeps only `Lossless.dll`, sealed, and deletes the rest.
    func download() async {
        guard busy == nil else { return }
        guard await verify(), let steamID = SteamService.shared.steamIDText else { return }
        busy = "Downloading from Steam\u{2026}"; progress = 0; message = nil
        defer { busy = nil; progress = nil }
        let work = root.appendingPathComponent("download", isDirectory: true)
        try? fm.removeItem(at: work)
        defer { try? fm.removeItem(at: work) }
        do {
            let (folder, _) = try await SteamService.shared.install(appID: LosslessLicence.appID, name: "Lossless Scaling", steamApps: work) { [weak self] p in
                self?.progress = p.fraction
                self?.busy = p.phase == .finishing ? "Finishing\u{2026}" : "Downloading from Steam\u{2026}"
            }
            guard let dll = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.lowercased() == "lossless.dll" }),
                  let data = try? Data(contentsOf: dll), data.count > 1024 else {
                message = "The download finished but Lossless.dll was not in it."
                return
            }
            busy = "Sealing the file on this device\u{2026}"
            let sealed = try LosslessLicence.seal(data, deviceSecret: deviceSecret(), steamID: steamID)
            try sealed.write(to: sealedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            LogStore.shared.log("[lossless] Lossless.dll sealed on this device: \(data.count) bytes, sha256 \(LosslessLicence.sha256(data).prefix(16))")
            reload()
        } catch is CancellationError {
            message = "Cancelled."
        } catch {
            message = ErrorText.plain(error, doing: "Downloading Lossless Scaling")
        }
    }

    /// Removes the sealed file and the receipt.
    func remove() {
        try? fm.removeItem(at: sealedURL)
        try? fm.removeItem(at: receiptURL)
        try? fm.removeItem(at: root.appendingPathComponent("download", isDirectory: true))
        reload()
    }

    /// The file's bytes, only while the receipt is valid for the account in use and the file opens with this device's and account's key: what the frame generation will ask for once it is
    /// built (nothing calls this yet). Every use moves the receipt's `lastSeen` forward, which is how a clock set back is noticed.
    func dllData() -> Data? {
        guard usable, var r = receipt, let steamID = SteamService.shared.steamIDText ?? Optional(r.steamID),
              let sealed = try? Data(contentsOf: sealedURL), let file = try? LosslessLicence.open(sealed, deviceSecret: deviceSecret(), steamID: steamID) else { return nil }
        r = LosslessLicence.seen(r, now: Date(), key: receiptKey())
        save(r)
        return file
    }

    // MARK: For a running game

    /// Where the game finds the shaders: a file in its own prefix, there only while the game runs (the engine reads it into memory when the frame generation starts).
    nonisolated static let windowsShaderPath = #"C:\ProgramData\Porthole\lsfg.bin"#
    /// The control file the engine looks at twice a second (what the menu changes), and the status file it writes back next to it.
    nonisolated static let windowsControlPath = #"C:\ProgramData\Porthole\lsfg.ctl"#
    private var folder: URL { AppModel.prefix.appendingPathComponent("drive_c/ProgramData/Porthole", isDirectory: true) }
    private var shaderFileURL: URL { folder.appendingPathComponent("lsfg.bin") }
    private var controlFileURL: URL { folder.appendingPathComponent("lsfg.ctl") }
    private var statusFileURL: URL { folder.appendingPathComponent("lsfg.ctl.status") }

    /// What is set for the game that runs now (the menu changes it live).
    struct Live: Equatable {
        var enabled = false
        var generated = 1          // frames made between two real ones
        var flow = 1.0             // the motion search runs at the picture's size divided by this
        var force = false          // generate even when the game is fast enough not to need it (testing)
        var measure = false        // run the passes but show nothing extra: tells what the passes cost apart from what showing more frames costs
        var performance = true     // the lighter pass layout: fewer and smaller intermediate pictures, less graphics work
    }
    @Published private(set) var live = Live()

    /// Writes the shaders for the game about to start. False when the licence is not valid, the file will not open, or it is a version without the shaders the passes need.
    func prepareForGame() -> Bool {
        guard let dll = dllData(), let box = LosslessShaders.container(from: dll) else { return false }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try box.write(to: shaderFileURL, options: [.atomic]) } catch { return false }
        return true
    }

    /// A game is about to start with this setting: fresh control file, and the shaders in the prefix when it is on. False when it is on and the shaders cannot be prepared.
    @discardableResult
    func startGame(enabled: Bool, generated: Int) -> Bool {
        try? fm.removeItem(at: statusFileURL)
        return apply(Live(enabled: enabled, generated: min(max(generated, 1), 3), flow: 1.0, force: false))
    }

    /// Changes the setting of the running game (the in-game menu). Switching it on prepares the shaders first, when they are not in the prefix.
    @discardableResult
    func apply(_ new: Live) -> Bool {
        var v = new
        if v.enabled, !fm.fileExists(atPath: shaderFileURL.path), !prepareForGame() { v.enabled = false }
        live = v
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "enabled=\(v.enabled ? 1 : 0)\ngenerated=\(v.generated)\nflow=\(v.flow)\nforce=\(v.force ? 1 : 0)\nperformance=\(v.performance ? 1 : 0)\nmeasure=\(v.measure ? 1 : 0)\nhz=\(UIScreen.main.maximumFramesPerSecond)\n"
        try? text.write(to: controlFileURL, atomically: true, encoding: .utf8)
        return v.enabled == new.enabled
    }

    /// What the engine said last, as lines "key=value" (state, game, generated, cost, message ...). Empty when it has said nothing.
    func engineStatus() -> [String: String] {
        guard let text = try? String(contentsOf: statusFileURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// The status as a sentence for the menu.
    func statusText() -> String {
        guard live.enabled else { return "Off." }
        let st = engineStatus()
        switch st["state"] {
        case "generating":
            return "Making \(st["generated"] ?? "?") extra frames a second. The game draws \(st["game"] ?? "?") FPS; the passes cost \(st["cost"] ?? "?") ms of the game thread per frame; the motion search runs at \(st["flow"] ?? "?") from \(st["size"] ?? "?")."
        case "running":
            return "On, but no frames are being made now: the game draws \(st["game"] ?? "?") FPS and the screen (\(st["screen"] ?? "?") Hz) cannot show more than the game already gives it. Turn on Always generate to see the picture anyway."
        case "starting":
            return "Starting: preparing the shaders. The game may stutter for a few seconds."
        case "error":
            return "Not working: \(st["message"] ?? "unknown reason")."
        case "off":
            return "Switched off in the game."
        default:
            return "Waiting for the game to draw. Direct3D 11 and 12 games are supported; if nothing appears after a few seconds this game may use something else (Direct3D 9 or 10, OpenGL, Vulkan)."
        }
    }

    /// The game is over (or the next one does not use it): the shaders and the control files do not stay in the prefix.
    func sessionEnded() {
        try? fm.removeItem(at: shaderFileURL)
        try? fm.removeItem(at: controlFileURL)
        try? fm.removeItem(at: statusFileURL)
        live = Live()
    }
}
