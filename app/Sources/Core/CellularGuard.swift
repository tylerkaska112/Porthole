// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import Network
import NetworkExtension
import Observation
import SwiftUI
import UIKit

/// Cellular data and Porthole's tunnel.
///
/// Porthole's tunnel makes the device's own address (10.7.0.1) answer on the device itself, and JIT and the on-device update install both talk to the device through
/// it. That loopback works on Wi-Fi, or with no network at all, but not while cellular data is the network in use (the same limit Madeira documents for LocalDevVPN).
/// Neither job needs the internet, so while one runs Cellular Data can simply be off.
///
/// An app cannot switch Cellular Data itself. The only way is a Shortcut with the action "Set Cellular Data", which an app can start by opening the Shortcuts app
/// (x-callback-url) and which comes back to `porthole://cellular?result=...`. So this does what the VPN guard does for the person's own VPN: it notices the problem,
/// asks once, remembers that it switched something off (kept across launches, an update restarts the app), and switches it back on afterwards.
///
/// The order matters. The tunnel is brought up first, while cellular data still works, and cellular data goes off after that: a VPN that is not up yet may not
/// connect at all with no network, one that is already up keeps working.
@MainActor @Observable
final class CellularGuard {
    static let shared = CellularGuard()

    /// Settings > JIT and tunnel > Cellular data: on by default.
    static let enabledKey = "f4.cellularAuto"
    private static let pausedKey = "f4.cellularPaused"
    private static let ranKey = "f4.cellularShortcutRan"
    private static let blockedKey = "f4.cellularAutoBlocked"
    private static let setupShownKey = "f4.cellularSetupShown"
    static let offName = "Porthole Cellular Off"
    static let onName = "Porthole Cellular On"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// True from the moment cellular data was switched off until it is back on. Kept across launches.
    private(set) var paused = UserDefaults.standard.bool(forKey: pausedKey)
    /// The question while the update popup shows it itself instead of this guard's own window; nil otherwise.
    private(set) var hostedQuestion: String?
    /// A shortcut is running: the app is away for a moment on purpose, which the update popup must not read as the person leaving.
    private(set) var busy = false
    /// What went wrong last, for the settings page.
    private(set) var lastProblem: String?
    var shortcutsHaveRun: Bool { UserDefaults.standard.bool(forKey: Self.ranKey) }

    /// `confirm` said yes and cellular data is the network: `switchOff` has to run once the tunnel is up.
    private(set) var armed = false
    private var asking: CheckedContinuation<Bool, Never>?
    private var running: CheckedContinuation<Bool, Never>?
    private var runID = 0
    private var window: UIWindow?
    private var restoring = false
    private let scope = FocusScope()

    /// The "on" shortcut failed: Porthole stops trying by itself (at app start, when a game ends, before a game starts). Each try opens the Shortcuts app and comes back, which is
    /// all it did on every start while the shortcut was missing. The reminder on Home still turns cellular data on by hand; adding the shortcuts or a working test starts it again.
    private(set) var autoBlocked = UserDefaults.standard.bool(forKey: blockedKey)

    private func setPaused(_ value: Bool) {
        paused = value
        UserDefaults.standard.set(value, forKey: Self.pausedKey)
    }

    private func setBlocked(_ value: Bool) {
        autoBlocked = value
        UserDefaults.standard.set(value, forKey: Self.blockedKey)
    }

    // MARK: The network

    nonisolated private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        // A change of network is when "cellular data is off" may stop being true (the person switched it on themselves, on Wi-Fi or not).
        m.pathUpdateHandler = { _ in Task { @MainActor in CellularGuard.shared.recheck() } }
        m.start(queue: DispatchQueue(label: "site.portholehq.cellular-guard", qos: .utility))
        return m
    }()

    /// Start watching early: a monitor only knows the network a moment after it starts.
    nonisolated static func warmUp() { _ = monitor }

    /// Cellular data is what the device is using right now (not Wi-Fi, not a cable).
    nonisolated static func cellularInUse() -> Bool {
        let p = monitor.currentPath
        return p.status == .satisfied && p.usesInterfaceType(.cellular) && !p.usesInterfaceType(.wifi) && !p.usesInterfaceType(.wiredEthernet)
    }

    /// Cellular data is switched on (an interface for it exists), whether or not it is the one in use.
    nonisolated static func cellularAvailable() -> Bool {
        monitor.currentPath.availableInterfaces.contains { $0.type == .cellular }
    }

    /// Porthole's own jobs (a game, or the tunnel for JIT or an update) are using the connection: cellular data is off on purpose until they are done.
    private var jobRunning: Bool {
        if AppModel.shared.session.isActive { return true }
        switch TunnelManager.shared.status { case .connecting, .connected, .reasserting, .disconnecting: return true; default: return false }
    }

    nonisolated static func pathSummary() -> String {
        let p = monitor.currentPath
        let types = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other].filter { p.usesInterfaceType($0) }.map { "\($0)" }.joined(separator: "+")
        let available = p.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
        return "\(p.status) using [\(types.isEmpty ? "none" : types)] available [\(available)]\(p.isExpensive ? " expensive" : "")"
    }

    // MARK: Before the tunnel comes up

    /// Call before Porthole's own tunnel starts. Returns false when the person would rather not (or the setup was only just offered): the caller then does not
    /// start. `what`: "turn on JIT" or "install the update". `hosted`: the caller shows the question itself (reads `hostedQuestion`, answers `answerHosted`).
    func confirm(for what: String, hosted: Bool = false) async -> Bool {
        armed = false
        guard Self.enabled, InstallCheck.hasTunnel, !TunnelManager.useLocalDevVPN, asking == nil else { return true }
        guard Self.cellularInUse() else { return true }
        LogStore.shared.log("[cellular] cellular data is the network: \(Self.pathSummary())")
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }) else { return true }

        // First time: the two shortcuts have to exist. Offer to add them, and stop; the person presses Play again afterwards.
        if !UserDefaults.standard.bool(forKey: Self.setupShownKey) {
            let text = "You are on cellular data, and Porthole's private connection does not work over it. Porthole can switch cellular data off for a few seconds and back on, " +
                "but iOS only allows that through two small Shortcuts. Tap Add shortcuts, choose Shortcuts in the share sheet and tap Add Shortcut, once for each. Then try again."
            let go = await ask(title: "Add two shortcuts first", text: text, confirm: "Add shortcuts", hosted: hosted, in: scene)
            UserDefaults.standard.set(true, forKey: Self.setupShownKey)
            if go { addShortcuts() }
            LogStore.shared.log("[cellular] the shortcuts were offered; nothing was started")
            return false
        }

        let back = "Porthole switches it back on as soon as it is done."
        let text = "You are on cellular data. Porthole needs its own connection to \(what), and that does not work while cellular data is on. " +
            "Cellular data is switched off for a few seconds with your \u{201C}\(Self.offName)\u{201D} shortcut. \(back) Nothing needs the internet meanwhile."
        let yes = await ask(title: "Switch cellular data off?", text: text, confirm: "Switch it off", hosted: hosted, in: scene)
        guard yes else { LogStore.shared.log("[cellular] the person kept cellular data on; nothing was started"); return false }
        armed = true
        return true
    }

    private func ask(title: String, text: String, confirm: String, hosted: Bool, in scene: UIWindowScene) async -> Bool {
        let yes = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            asking = c
            if hosted { hostedQuestion = text } else { present(title: title, text: text, confirm: confirm, in: scene) }
        }
        hostedQuestion = nil
        dismissPrompt()
        return yes
    }

    /// The hosting screen's answer to `hostedQuestion`.
    func answerHosted(_ yes: Bool) { answer(yes) }

    private func answer(_ yes: Bool) {
        guard let c = asking else { return }
        asking = nil
        c.resume(returning: yes)
    }

    /// The tunnel is not going to be started after all (the person kept their VPN on, say): nothing needs switching off.
    func disarm() { armed = false }

    // MARK: Switching off and on

    /// Call once the tunnel is up. Switches cellular data off with the shortcut and waits until the network really is no longer cellular. Returns false when it
    /// did not work (the reason is in `lastProblem`); cellular data is then switched back on.
    func switchOff() async -> Bool {
        guard armed else { return true }
        armed = false
        lastProblem = nil
        LogStore.shared.log("[cellular] switching cellular data off")
        setPaused(true)                       // before leaving the app: if it is closed in between, the next launch puts it right
        guard await runShortcut(Self.offName) else {
            lastProblem = "Cellular data could not be switched off: the \u{201C}\(Self.offName)\u{201D} shortcut did not run. Add the two shortcuts in Settings \u{203A} JIT and tunnel \u{203A} Cellular data."
            LogStore.shared.log("[cellular] \(lastProblem ?? "")", level: .error)
            await restoreNow()
            return false
        }
        for _ in 0..<24 where Self.cellularInUse() { try? await Task.sleep(for: .milliseconds(500)) }
        if Self.cellularInUse() {
            lastProblem = "The shortcut ran, but the device is still on cellular data. Open the shortcut once in Shortcuts and allow what it asks."
            LogStore.shared.log("[cellular] \(lastProblem ?? "") \(Self.pathSummary())", level: .error)
            await restoreNow()
            return false
        }
        LogStore.shared.log("[cellular] cellular data is off: \(Self.pathSummary())", level: .success)
        return true
    }

    /// Switches cellular data back on and waits for it. Does nothing unless it was switched off by Porthole.
    func restoreNow() async {
        guard paused else { return }
        LogStore.shared.log("[cellular] switching cellular data back on")
        let ran = await runShortcut(Self.onName)
        if ran {
            setPaused(false)                  // the shortcut ran to the end: that is what counts, the network path may take a moment to show it
            setBlocked(false)
            for _ in 0..<16 where !Self.cellularAvailable() { try? await Task.sleep(for: .milliseconds(500)) }
            LogStore.shared.log("[cellular] cellular data is back on: \(Self.pathSummary())", level: .success)
        } else if Self.cellularAvailable() {
            setPaused(false)                  // the person switched it on themselves
            setBlocked(false)
            LogStore.shared.log("[cellular] cellular data is on again: \(Self.pathSummary())")
        } else {
            lastProblem = "The \u{201C}\(Self.onName)\u{201D} shortcut did not run, so cellular data may still be off."
            setBlocked(true)
            LogStore.shared.log("[cellular] \(lastProblem ?? "") It stays marked as off; Porthole no longer tries by itself (the reminder on Home turns it on by hand).", level: .error)
        }
    }

    /// For the launch worker: switches cellular data back on before the game starts, and returns when that is done (or after a limit). Runs the shortcut on the main
    /// actor, which leaves the app for a moment; JIT is set up and the debugger has gone, so nothing is lost.
    nonisolated static func restoreBlocking() {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            if !CellularGuard.shared.autoBlocked { await CellularGuard.shared.restoreNow() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 60)
    }

    /// Call when a game has ended or never started, when a job failed, and when the app opens. Does nothing unless cellular data was switched off by Porthole and is
    /// still off, and never while a game is starting or running.
    func restoreIfPaused() {
        guard paused, !autoBlocked, !restoring, !busy else { return }
        restoring = true
        Task { @MainActor in
            defer { restoring = false }
            for _ in 0..<20 where TunnelManager.shared.status == .connecting || TunnelManager.shared.status == .disconnecting { try? await Task.sleep(for: .milliseconds(500)) }
            guard paused, !AppModel.shared.session.isActive else { return }
            if Self.cellularAvailable() { setPaused(false); LogStore.shared.log("[cellular] cellular data is on again: \(Self.pathSummary())"); return }
            await restoreNow()
        }
    }

    /// The person is back in the app, or the network changed: if cellular data is on again (they switched it on themselves, and it need not be the network in use: on Wi-Fi it
    /// is only available), the reminder goes away. Not while a game or the tunnel is running: cellular data is off then on purpose.
    func recheck() {
        guard paused, !busy, !jobRunning, Self.cellularAvailable() else { return }
        setPaused(false)
        setBlocked(false)
        LogStore.shared.log("[cellular] cellular data is on again: \(Self.pathSummary())")
    }

    /// Settings: switches cellular data off and straight back on once, to check that both shortcuts are added and allowed. Works on Wi-Fi too.
    func selfTest() async {
        guard !paused, !busy else { return }
        lastProblem = nil
        setBlocked(false)
        LogStore.shared.log("[cellular] test: switching cellular data off and on")
        setPaused(true)
        guard await runShortcut(Self.offName) else {
            lastProblem = "The \u{201C}\(Self.offName)\u{201D} shortcut did not run. Add it with the button above, and allow what Shortcuts asks."
            await restoreNow()
            return
        }
        try? await Task.sleep(for: .seconds(2))
        await restoreNow()
        if lastProblem == nil { LogStore.shared.log("[cellular] test: both shortcuts worked", level: .success) }
    }

    // MARK: Shortcuts

    /// Runs one shortcut and waits for it to come back to `porthole://cellular`. False when it was cancelled, failed, could not be opened or took too long.
    private func runShortcut(_ name: String, timeout: TimeInterval = 40) async -> Bool {
        guard running == nil else { return false }
        var c = URLComponents()
        c.scheme = "shortcuts"; c.host = "x-callback-url"; c.path = "/run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: name),
                        URLQueryItem(name: "x-success", value: "porthole://cellular?result=ok"),
                        URLQueryItem(name: "x-cancel", value: "porthole://cellular?result=cancel"),
                        URLQueryItem(name: "x-error", value: "porthole://cellular?result=error")]
        guard let url = c.url else { return false }
        runID += 1
        let id = runID
        busy = true
        defer { busy = false }
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            running = cont
            UIApplication.shared.open(url) { opened in
                if !opened { Task { @MainActor in self.finishRun(false, id: id, why: "iOS would not open the Shortcuts app") } }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                self.finishRun(false, id: id, why: "no answer from Shortcuts after \(Int(timeout)) s")
            }
        }
        if ok { UserDefaults.standard.set(true, forKey: Self.ranKey) }
        LogStore.shared.log("[cellular] shortcut \u{201C}\(name)\u{201D}: \(ok ? "done" : "did not complete")", level: ok ? .info : .error)
        return ok
    }

    private func finishRun(_ ok: Bool, id: Int, why: String? = nil) {
        guard id == runID, let c = running else { return }
        running = nil
        if let why { LogStore.shared.log("[cellular] \(why)", level: .error) }
        c.resume(returning: ok)
    }

    /// `porthole://cellular?result=ok|cancel|error`, opened by Shortcuts when the shortcut has finished.
    func shortcutReturned(_ result: String?) {
        LogStore.shared.log("[cellular] Shortcuts returned: \(result ?? "?")")
        finishRun(result == "ok", id: runID)
    }

    // MARK: Adding the shortcuts

    /// Shares the two bundled, signed shortcut files, one after the other: the person picks Shortcuts in the share sheet and taps Add Shortcut for each.
    func addShortcuts() {
        UserDefaults.standard.set(true, forKey: Self.setupShownKey)
        setBlocked(false)
        share(Self.offName) { [weak self] in self?.share(Self.onName, then: nil) }
    }

    private func share(_ name: String, then next: (() -> Void)?) {
        guard let source = Bundle.main.url(forResource: name, withExtension: "shortcut") else {
            LogStore.shared.log("[cellular] the bundled shortcut \u{201C}\(name)\u{201D} is missing", level: .error)
            return
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).shortcut")
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in try? FileManager.default.removeItem(at: copy); next?() }
        }
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(sheet, animated: true)
    }

    // MARK: The question's own window

    private func present(title: String, text: String, confirm: String, in scene: UIWindowScene) {
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level.alert + 30     // above the launch screen's window
        let host = UIHostingController(rootView: CellularPrompt(title: title, message: text, confirm: confirm, scope: scope) { [weak self] yes in self?.answer(yes) })
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.backgroundColor = .clear
        w.isHidden = false
        window = w
    }

    private func dismissPrompt() {
        guard window != nil else { return }
        NavHub.shared.pop(scope)
        window?.isHidden = true
        window = nil
    }
}

private struct CellularPrompt: View {
    let title: String
    let message: String
    let confirm: String
    let scope: FocusScope
    let done: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ConfirmSheet(title: title, message: message, confirmTitle: confirm, scope: scope, done: done)
                .frame(maxWidth: 520, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .padding(20)
        }
        .preferredColorScheme(Theme.scheme)
    }
}
