// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CFNetwork
import Observation
import SwiftUI
import UIKit

/// Looks after the person's own VPN while Porthole's tunnel is up.
///
/// iOS runs one VPN at a time, so switching Porthole's tunnel on (for JIT, or for installing an update) switches the person's VPN off. iOS gives an app no way to
/// start another app's VPN again, so this does what can be done: it notices a VPN is on, asks first, remembers that it was paused, and afterwards either runs the
/// Shortcut the person made ("Set VPN: connect ...") or reminds them. A VPN with its own "connect on demand" setting comes back by itself and needs none of that.
@MainActor @Observable
final class VPNGuard {
    static let shared = VPNGuard()

    /// Settings: whether to ask before pausing (default yes), and the name of the Shortcut that turns the VPN back on.
    static let askKey = "f4.vpnAsk"
    static let shortcutKey = "f4.vpnShortcut"
    /// Whether the paused VPN is turned back on as soon as JIT is on, before the game starts (default yes), instead of only after the game closes.
    static let earlyKey = "f4.vpnEarly"
    private static let pausedKey = "f4.vpnPaused"

    /// True from the moment a VPN was paused until it is back on (or the person said they know). Kept across launches: installing an update restarts the app.
    private(set) var paused = UserDefaults.standard.bool(forKey: pausedKey)

    /// The question while a screen of the app (the update popup) shows it itself instead of this guard's own window; nil otherwise.
    private(set) var hostedQuestion: String?

    private var waiting: CheckedContinuation<Bool, Never>?
    private var shortcutWaiter: CheckedContinuation<Void, Never>?
    private var restoring = false
    private var window: UIWindow?
    private let scope = FocusScope()

    private var shortcutName: String { (UserDefaults.standard.string(forKey: Self.shortcutKey) ?? "").trimmingCharacters(in: .whitespaces) }
    var hasShortcut: Bool { !shortcutName.isEmpty }

    private func setPaused(_ value: Bool) {
        paused = value
        UserDefaults.standard.set(value, forKey: Self.pausedKey)
    }

    // MARK: Looking

    /// A VPN other than Porthole's own is up: iOS lists a tunnel interface (utun, ipsec, ppp) among the network settings. It cannot say which VPN it is.
    /// (Rarely, something that is not a VPN, like iCloud Private Relay, shows up the same way; the worst that happens is one unneeded question.)
    nonisolated static func vpnInterfaceUp() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { key in ["tap", "tun", "utun", "ppp", "ipsec"].contains { key.hasPrefix($0) } }
    }

    private var ourTunnelBusy: Bool {
        switch TunnelManager.shared.status { case .connected, .connecting, .reasserting, .disconnecting: true; default: false }
    }

    /// Someone else's VPN is on right now.
    private var otherVPNOn: Bool { !ourTunnelBusy && Self.vpnInterfaceUp() }

    // MARK: Before the tunnel comes up

    /// Call before Porthole's own tunnel starts. Returns false when the person would rather keep their VPN on (the caller then does not start the tunnel).
    /// `what`: "turn on JIT"; `until`: "the game closes".
    /// `hosted`: the caller shows the question itself (it reads `hostedQuestion` and answers with `answerHosted`), so no window of its own is opened.
    func confirmPause(for what: String, until: String, hosted: Bool = false) async -> Bool {
        guard InstallCheck.hasTunnel, !TunnelManager.useLocalDevVPN, waiting == nil, otherVPNOn else { return true }
        let ask = UserDefaults.standard.object(forKey: Self.askKey) as? Bool ?? true
        if ask {
            let back = hasShortcut ? "Porthole then runs your \u{201C}\(shortcutName)\u{201D} shortcut to turn it back on."
                                   : "Porthole then reminds you to turn it back on."
            let early = hasShortcut && (UserDefaults.standard.object(forKey: Self.earlyKey) as? Bool ?? true)
            let text = "Porthole needs its own connection for a moment to \(what). Your VPN switches off now and stays off until \(early ? "JIT is on" : until). \(back)"
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }) else { return markPaused() }
            let yes = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                waiting = c
                if hosted { hostedQuestion = text } else { present(text, in: scene) }
            }
            hostedQuestion = nil
            dismissPrompt()
            guard yes else { LogStore.shared.log("[vpn] the person kept their VPN on; nothing was started"); return false }
        }
        return markPaused()
    }

    private func markPaused() -> Bool {
        setPaused(true)
        LogStore.shared.log("[vpn] another VPN is on: it is paused while Porthole's tunnel is up")
        return true
    }

    /// The hosting screen's answer to `hostedQuestion`.
    func answerHosted(_ yes: Bool) { answer(yes) }

    private func answer(_ yes: Bool) {
        guard let c = waiting else { return }
        waiting = nil
        c.resume(returning: yes)
    }

    private func present(_ text: String, in scene: UIWindowScene) {
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level.alert + 30     // above the launch screen's window
        let host = UIHostingController(rootView: VPNPrompt(message: text, scope: scope) { [weak self] yes in self?.answer(yes) })
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.backgroundColor = .clear
        w.isHidden = false
        window = w
    }

    private func dismissPrompt() {
        NavHub.shared.pop(scope)
        window?.isHidden = true
        window = nil
    }

    // MARK: After

    /// Call whenever Porthole's tunnel has gone off, when a game ends, and when the app opens. Does nothing unless a VPN was paused and is still off, and never while a
    /// game is starting or running (turning a VPN on means leaving the app for a moment).
    func restoreIfPaused() {
        guard paused, !restoring else { return }
        restoring = true
        Task { @MainActor in
            defer { restoring = false }
            // Our tunnel has to be gone, and iOS takes its network interface down a moment later.
            for _ in 0..<20 where ourTunnelBusy { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(2))
            guard paused, !AppModel.shared.session.isActive else { return }
            if Self.vpnInterfaceUp() { setPaused(false); LogStore.shared.log("[vpn] a VPN is on again"); return }
            LogStore.shared.log("[vpn] the paused VPN is still off" + (hasShortcut ? "; running the shortcut" : ""))
            if hasShortcut { runShortcut() }
        }
    }

    /// JIT is on and the debugger has gone, but the game has not started: turn the paused VPN back on now, so the game (and Steam's client in it) starts with the VPN up.
    /// Some networks block Steam without it. Leaves the app for a moment (Shortcuts), like the cellular data guard. Does nothing unless a VPN was paused for this launch and
    /// the person has a shortcut that turns it back on. Waits for the VPN to be up, at most about a minute.
    nonisolated static func restoreBlocking() {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await VPNGuard.shared.restoreForLaunch()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 75)
    }

    private func restoreForLaunch() async {
        guard paused, hasShortcut, UserDefaults.standard.object(forKey: Self.earlyKey) as? Bool ?? true else { return }
        // Our tunnel has nothing left to do (JIT is on); it has to be gone before another VPN can start, and iOS takes its network interface down a moment later.
        TunnelManager.shared.disconnect()
        for _ in 0..<20 where ourTunnelBusy { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(2))
        if Self.vpnInterfaceUp() { setPaused(false); LogStore.shared.log("[vpn] a VPN is on again (before the game starts)"); return }
        LogStore.shared.log("[vpn] JIT is on: running the shortcut to turn the paused VPN back on before the game starts")
        await runShortcutAndWait()
        for _ in 0..<40 where !Self.vpnInterfaceUp() { try? await Task.sleep(for: .milliseconds(500)) }
        if Self.vpnInterfaceUp() {
            setPaused(false)
            LogStore.shared.log("[vpn] a VPN is on again (before the game starts)")
        } else {
            LogStore.shared.log("[vpn] the VPN did not come back; the game starts without it", level: .error)
        }
    }

    /// Runs the Shortcut and waits until it has brought the app back (porthole://vpn), at most 30 seconds.
    private func runShortcutAndWait() async {
        guard hasShortcut else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            shortcutWaiter = c
            runShortcut()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                self.shortcutReturned()
            }
        }
    }

    /// Shortcuts is done and the app is in front again.
    func shortcutReturned() {
        guard let c = shortcutWaiter else { return }
        shortcutWaiter = nil
        c.resume()
    }

    /// The person is back in the app (from Shortcuts or Settings): if a VPN is on again, the reminder goes away.
    func recheck() {
        guard paused, otherVPNOn else { return }
        setPaused(false)
        LogStore.shared.log("[vpn] a VPN is on again")
    }

    /// "Got it": the person does not want it back on.
    func forget() { setPaused(false) }

    /// Runs the person's Shortcut and comes back here afterwards (porthole://vpn does nothing but bring the app to the front).
    func runShortcut() {
        guard hasShortcut else { return }
        var c = URLComponents()
        c.scheme = "shortcuts"; c.host = "x-callback-url"; c.path = "/run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: shortcutName), URLQueryItem(name: "x-success", value: "porthole://vpn"),
                        URLQueryItem(name: "x-cancel", value: "porthole://vpn"), URLQueryItem(name: "x-error", value: "porthole://vpn")]
        guard let url = c.url else { return }
        UIApplication.shared.open(url)
    }
}

/// The question, drawn in a window of its own so it shows over the launch screen too.
private struct VPNPrompt: View {
    let message: String
    let scope: FocusScope
    let done: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ConfirmSheet(title: "Pause your VPN?", message: message, confirmTitle: "Pause it", scope: scope, done: done)
                .frame(maxWidth: 500, maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .padding(20)
        }
        .preferredColorScheme(Theme.scheme)
    }
}
