// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import Security
import UIKit

/// In-app JIT: asks the embedded helper extension (a separate process) to attach a debugger to this app and enable JIT, instead of opening StikDebug.
///
/// Needs, in this order: this app signed with get-task-allow; a pairing file imported once (made on a computer); the tunnel up (our own, or LocalDevVPN: it provides the
/// route to the device's own debug service); the helper extension signed and installed with the app.
final class BuiltinJIT: NSObject, F4JITHost {
    static let shared = BuiltinJIT()

    /// Where an earlier version kept the pairing file (and where it is still kept if the Keychain refuses it): Application Support, which iOS does not show
    /// in Files. (Before 0.50.218 it was in Documents, which this app shares; it is moved out of there on first use.)
    private static var newPairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porthole/Pairing/pairingFile.plist")
    }

    private static let migrated: Void = {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let old = documents.appendingPathComponent("StikJIT/pairingFile.plist")
        guard fm.fileExists(atPath: old.path) else { return }
        let new = newPairingURL
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: new.path) { try fm.removeItem(at: old) } else { try fm.moveItem(at: old, to: new) }
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var stored = new; try? stored.setResourceValues(values)
            try? fm.removeItem(at: old.deletingLastPathComponent())       // the now-empty StikJIT folder in Documents
            LogStore.shared.log("[pairing] the pairing file was moved out of the shared Documents folder")
        } catch {
            LogStore.shared.log("[pairing] could not move the pairing file out of Documents: \(error.localizedDescription)", level: .error)
        }
    }()
    // The pairing file holds a private key that lets a computer debug this device. A Windows program running inside Porthole can open any file the app
    // can, so it is kept in the Keychain (which Windows programs cannot read) and written to a file only for the moment the installer needs a path.
    private static let keychainService = "porthole.jit.pairing"
    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "pairing"]
    }
    private static func keychainLoad() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    private static func keychainSave(_ data: Data) -> Bool {
        SecItemDelete(keychainQuery() as CFDictionary)
        var query = keychainQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// The pairing file's bytes, from the Keychain. A copy an earlier version left as a file is moved into the Keychain and deleted.
    static func loadPairing() -> Data? {
        _ = migrated
        if let data = keychainLoad() { return data }
        guard let data = try? Data(contentsOf: newPairingURL), (try? JITPairing.validate(data)) != nil else { return nil }
        if keychainSave(data) {
            try? FileManager.default.removeItem(at: newPairingURL)
            LogStore.shared.log("[pairing] the pairing file was moved into the Keychain")
        }
        return data
    }

    static var hasPairing: Bool {
        guard let data = loadPairing() else { return false }
        return (try? JITPairing.validate(data)) != nil
    }

    /// Runs `body` with a temporary file holding the pairing file (for the C library that wants a path), then removes it.
    static func withPairingFile<T>(_ body: (URL) throws -> T) throws -> T {
        guard let data = loadPairing() else { throw CocoaError(.fileNoSuchFile) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    static func importPairing(from url: URL) throws {
        defer { SecretFiles.discard(url) }          // the picker's copy of it
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        try JITPairing.validate(data)
        if keychainSave(data) {
            try? FileManager.default.removeItem(at: newPairingURL)
        } else {
            // The Keychain refused (a copy re-signed without its entitlement): the protected file in Application Support is the way it always worked.
            try FileManager.default.createDirectory(at: newPairingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: newPairingURL, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var stored = newPairingURL; try stored.setResourceValues(values)
            LogStore.shared.log("[pairing] the Keychain refused the pairing file; kept in a protected file instead", level: .error)
        }
    }

    private var launcher: JITExtensionLauncher?
    private var onAttached: (() -> Void)?
    private var report: ((String) -> Void)?
    private var stage: ((String) -> Void)?
    private var poll: Timer?
    private var deadline: DispatchWorkItem?
    private var done = false

    /// Starts JIT. `onAttached` runs once the debugger is attached (the script then services the runtime's BRK requests). `report` gets a failure message.
    /// Returns false (after calling `report`) when the preconditions are not met, so the caller can fall back to StikDebug.
    @discardableResult
    func start(stage: @escaping (String) -> Void, onAttached: @escaping () -> Void, report: @escaping (String) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard launcher == nil else { report("Relaunch the app before another JIT attempt."); return false }
        guard #available(iOS 18, *) else { report("In-app JIT needs iOS 18 or later."); return false }
        guard F4HasDebugEntitlement() else { report("JIT cannot be turned on for this copy of Porthole: it was installed with a certificate that does not allow debugging (the \u{201C}get-task-allow\u{201D} permission, which distribution and enterprise certificates do not carry). Install Porthole again signed with a development certificate, for example with SideStore or AltStore and a free Apple ID."); return false }
        guard !jit_check_debugged() else {
            // The flag stays set after another tool attached and left: nothing is attached now, but the flag cannot be cleared inside this run.
            report(StikJITHelper.ready ? "A debugger is already attached (Xcode?). Relaunch without it."
                                       : "JIT was switched on by another tool earlier in this run, and nothing is attached now. Close Porthole completely, open it again from the Home Screen and try again.")
            return false
        }
        let pairing: Data
        do { guard let loaded = Self.loadPairing() else { throw CocoaError(.fileNoSuchFile) }; pairing = loaded; try JITPairing.validate(pairing) }
        catch { report("Import a pairing file first (Updates > JIT)."); return false }

        self.stage = stage; self.onAttached = onAttached; self.report = report; done = false
        let launcher = JITExtensionLauncher()
        self.launcher = launcher
        launcher.failureHandler = { [weak self] message in self?.finish(message) }
        launcher.start(withHost: self, hostProtocol: F4JITHost.self, workerProtocol: F4JITWorker.self) { [weak self] worker, error in
            guard let self, !self.done else { return }
            guard let worker = worker as? F4JITWorker else { self.finish((error?.localizedDescription ?? "The JIT helper did not start.") + " You can choose StikDebug as the JIT method in Settings instead, or reinstall Porthole and keep its app extensions if your signing tool asks."); return }
            worker.enable(getpid(), pairing: pairing)
        }
        // The app is "debugged" the moment the helper attaches; that is the signal to carry on with the runtime's own startup.
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, !self.done, jit_check_debugged() else { return }
            self.poll?.invalidate(); self.poll = nil
            self.stage?("Debugger attached.")
            let callback = self.onAttached; self.onAttached = nil
            callback?()
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.done, self.onAttached != nil else { return }
            self.finish("JIT timed out. Check that the tunnel (or LocalDevVPN) is on and the pairing file is current. StikDebug is another JIT method you can choose in Settings.")
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: deadline)
        return true
    }

    // MARK: F4JITHost (called by the helper over XPC, on an arbitrary queue)

    func preparation(_ stage: String) { DispatchQueue.main.async { [self] in self.stage?(stage) } }

    func finished(_ error: String?) {
        DispatchQueue.main.async { [self] in
            // A clean finish after we proceeded is the normal end (the script detached on request). Before that it means the helper gave up.
            if error == nil, onAttached == nil { finish(nil) } else { finish(error ?? "The helper ended before JIT was ready.") }
        }
    }

    private func finish(_ error: String?) {
        guard !done else { return }
        done = true
        poll?.invalidate(); poll = nil; deadline?.cancel()
        let waiting = onAttached != nil
        onAttached = nil
        if let error, waiting { report?(error) }
        // Keep the helper alive if it failed while attached (killing a debugger mid-session can wedge the app); drop it on a clean finish.
        if error == nil { launcher?.invalidate(); launcher = nil }
        // The tunnel is only needed to reach the debug service. If JIT failed before the debugger ever attached, turn it off now. On success it is turned
        // off by SessionController a few seconds after the game starts (the debugger has detached by then). If it failed while attached, leave it:
        // dropping the connection under a live debugger is the same wedge as killing the helper.
        if error != nil && waiting { Task { @MainActor in TunnelManager.shared.disconnect() } }
    }
}
