// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

/// What the launch screen shows, read live from the session.
struct LaunchHost: View {
    @ObservedObject var session: SessionController
    let scope: FocusScope

    var body: some View {
        Group {
            if session.launchPeeking {
                // The person wants to see Steam's own window: only a small pill stays, to come back.
                Button { session.launchPeeking = false } label: {
                    Label("Back to launch screen", systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.accentGradient, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.5), radius: 10)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 8)
            } else if let data = session.launchData {
                LaunchView(data: data, scope: scope, cancel: { session.cancelLaunch() }, showSteam: session.canPeekAtSteam ? { session.launchPeeking = true } : nil)
                    .environment(\.artLoader, AppArt.loader)
            }
        }
        .id(ThemeStore.shared.revision)
    }
}

/// A window of its own above everything (the game's picture is drawn at window level, above SwiftUI, so only another window can cover it).
@MainActor
final class LaunchOverlay {
    static let shared = LaunchOverlay()
    private var window: UIWindow?
    private let scope = FocusScope()

    private var lastWanted = false

    func update(session: SessionController) {
        let wanted = session.launchOverlayActive
        if wanted != lastWanted {
            lastWanted = wanted
            LogStore.shared.log("[launch-screen] \(wanted ? "shown" : "hidden"): state=\(session.state) gameUp=\(session.launchGameUp) peeking=\(session.launchPeeking) game=\(session.game?.name ?? "none")")
        }
        if wanted { show(session: session) } else { hide() }
        // While the launch screen is up it owns the controller; once the game is running the controller belongs to the game.
        NavHub.shared.enabled = wanted || !session.isActive
    }

    private func show(session: SessionController) {
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }) else { return }
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = UIWindow.Level.alert + 10
            let host = UIHostingController(rootView: LaunchHost(session: session, scope: scope))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            w.backgroundColor = .clear
            w.alpha = 0
            w.isHidden = false
            window = w
            UIView.animate(withDuration: 0.25) { w.alpha = 1 }
        }
        (window as? PassthroughWindow)?.pillOnly = session.launchPeeking
    }

    private func hide() {
        NavHub.shared.pop(scope)
        guard let w = window else { return }
        window = nil
        UIView.animate(withDuration: 0.35, animations: { w.alpha = 0 }, completion: { _ in w.isHidden = true })
    }
}

/// While the person peeks at Steam, only the "back" pill takes touches; everything else falls through to the game view underneath.
final class PassthroughWindow: UIWindow {
    var pillOnly = false
    /// Never the key window. A touch on a window that can be key makes it key, and the game's picture (Wine's compositor view) is added to whichever window is key when Steam starts:
    /// tapping this screen first put the picture INSIDE this window, over the launch screen, and took it away again when this window went (a blue picture, then a black screen with
    /// only the controls). The launch screen has no text field, so nothing here needs the keyboard.
    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard pillOnly else { return super.hitTest(point, with: event) }
        let pill = CGRect(x: bounds.midX - 120, y: 0, width: 240, height: 64)
        return pill.contains(point) ? super.hitTest(point, with: event) : nil
    }
}
