// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import StikJIT

/// Runs inside the helper extension. Receives the host's XPC endpoint, then on request attaches a debugserver to the host's PID, runs Madeira's JIT script
/// (bundled in this extension) and detaches when the script is told to. Needs: LocalDevVPN connected, a pairing file, and a host with get-task-allow.
@objc(JITRequestHandler)
final class JITRequestHandler: NSObject, NSExtensionRequestHandling, F4JITWorker {
    private var context: NSExtensionContext?
    private var connection: NSXPCConnection?
    private var host: F4JITHost?
    private var accepted = false
    private let queue = DispatchQueue(label: "site.portholehq.jit.worker")

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let endpoint = item.userInfo?["F4JITEndpoint"] as? NSXPCListenerEndpoint else {
            context.cancelRequest(withError: CocoaError(.coderReadCorrupt)); return
        }
        self.context = context
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.exportedInterface = NSXPCInterface(with: F4JITWorker.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: F4JITHost.self)
        connection.resume()
        self.connection = connection
        host = connection.remoteObjectProxy as? F4JITHost
        // XPC connects lazily: sending a message is what lets the host accept this connection and reply with enable().
        host?.preparation("Helper connected.")
    }

    func enable(_ pid: Int32, pairing: Data) {
        queue.async { [self] in
            // One request, and only for the process that launched us.
            guard !accepted, pid > 0, pid != getpid(), pid == connection?.processIdentifier else {
                host?.finished("The JIT request did not match its host process."); return
            }
            accepted = true
            let stage = Stage()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID()).plist")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try JITPairing.validate(pairing)
                try pairing.write(to: file, options: [.atomic, .completeFileProtection])
                guard let script = Bundle.main.url(forResource: "madeira-jit", withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
                let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                try StikJIT.enableJIT(
                    targetPID: pid, pairingFile: file,
                    ddiPaths: DDIPaths.default(in: library.appendingPathComponent("StikJIT")),
                    script: .custom(script), forceScript: true,
                    preparationProgress: { [self] step in
                        switch step {
                        case .checkingReachability: stage.set("checking the connection"); host?.preparation("Checking the connection (the tunnel must be on).")
                        case .checkingDDI: stage.set("checking the developer support files"); host?.preparation("Checking Apple's developer support files.")
                        case .downloadingDDI: stage.set("downloading the developer support files"); host?.preparation("Downloading Apple's developer support files.")
                        case .mountingDDI: stage.set("preparing the device"); host?.preparation("Preparing this device for debugging.")
                        case .verifyingDDI: stage.set("checking the device preparation"); host?.preparation("Checking device preparation.")
                        case .ready: stage.set("attaching"); host?.preparation("Attaching and starting the JIT script.")
                        @unknown default: stage.set("preparing"); host?.preparation("Preparing JIT.")
                        }
                    },
                    progress: { _ in })   // raw framework output can contain paths and protocol detail; it stays in this process
                host?.finished(nil)
            } catch {
                host?.finished("JIT failed (\(stage.value): \(Self.reason(error))): check that the tunnel (or LocalDevVPN) is on and the pairing file is current.")
            }
        }
    }

    /// Which step the helper was at when it failed (the framework reports steps from its own thread).
    private final class Stage: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "starting"
        func set(_ new: String) { lock.lock(); text = new; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// What went wrong, in words and numbers only: the framework's own messages can carry paths and protocol detail, so they are not passed on.
    static func reason(_ error: Error) -> String {
        if let stik = error as? StikJITError {
            switch stik {
            case .pairingFile: return "the pairing file was not accepted"
            case .scriptUnavailable: return "the JIT script is missing"
            case .debugProxyUnavailable: return "the debug service could not be reached"
            case .device(let code, let subCode, _): return "the device answered with error \(code)/\(subCode)"
            case .ddiDownload: return "the developer support files could not be downloaded"
            case .ddiFilesMissing: return "the developer support files are missing"
            case .ddiNotMounted: return "the developer disk image is not mounted"
            case .deviceNotReady: return "the device is not ready for debugging"
            case .txmDetectionUnavailable: return "the device's security mode could not be read"
            case .customScript: return "the JIT script could not be loaded"
            case .scriptExecution: return "the JIT script failed"
            @unknown default: return "an error of the JIT library"
            }
        }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
