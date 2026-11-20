// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import AVFoundation
import SwiftUI
import UIKit

/// A second screen (AirPlay, or a cable to a TV or monitor) while a game runs.
///
/// The game's picture goes to the other screen, aspect-fitted on black; the phone keeps the touch controls, the menu and the controller pointer. iOS mirrors the
/// phone to a connected display unless the app puts a window of its own there, so while a display is connected Porthole shows its own calm screen on it
/// between games. Turning the setting off hands the display back to mirroring.
///
/// The scene is announced by iOS (UIScene.willConnectNotification); Info.plist declares the role so iOS makes one.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    /// Settings > Display: use a connected display for the game. On by default.
    static let enabledKey = "f4.externalDisplay"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Posted on connect and disconnect, so the game view can lay itself out again.
    static let changed = Notification.Name("PortholeExternalDisplayChanged")

    /// The display's window and the view the game goes in. Nil while nothing is connected.
    private(set) var window: UIWindow?
    private(set) var container: UIView?
    private var session: UISceneSession?
    private var idleLabel: UILabel?
    @Published private(set) var name: String?

    /// True when the game's picture should be on the other screen right now.
    var isHosting: Bool { Self.isEnabled && container != nil }

    // MARK: Scene

    private var observers: [NSObjectProtocol] = []
    private var started = false

    private static func isExternalRole(_ role: UISceneSession.Role) -> Bool {
        role == .windowExternalDisplayNonInteractive || role.rawValue == "UIWindowSceneSessionRoleExternalDisplay"
    }

    /// Listens for the scene iOS makes for a connected display. A SwiftUI app cannot name its own scene delegate for that role (SwiftUI answers for every
    /// scene), so the window is made from the connect notification instead; the Info.plist entry for the role is what makes iOS create the scene at all.
    /// Call once, at launch: a display that is already connected announces itself while the app starts.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            MainActor.assumeIsolated { self?.sceneConnecting(scene) }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            MainActor.assumeIsolated { self?.disconnect(scene: scene) }
        })
        // The raw screens too: a display can exist as a UIScreen without ever being given to the app as a scene.
        observers.append(center.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] note in
            guard let screen = note.object as? UIScreen else { return }
            MainActor.assumeIsolated { self?.screenConnected(screen) }
        })
        observers.append(center.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { _ in
            LogStore.shared.log("[display] a screen was disconnected (\(UIScreen.screens.count) screen(s) now)")
        })
        observers.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report("the screen capture or mirroring state changed") }
        })
        LogStore.shared.log("[display] watching for a connected display (setting is \(Self.isEnabled ? "on" : "off"), \(UIScreen.screens.count) screen(s) now; role names: \(UISceneSession.Role.windowExternalDisplayNonInteractive.rawValue), \(UISceneSession.Role.windowExternalDisplay.rawValue))")
        report("at launch")
    }

    /// One line per scene and screen: what iOS has given the app right now.
    func report(_ when: String) {
        let scenes = UIApplication.shared.connectedScenes.map { s -> String in
            let ws = s as? UIWindowScene
            return "\(s.session.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: ""))(\(ws.map { "\(Int($0.screen.bounds.width))x\(Int($0.screen.bounds.height))" } ?? "?"))"
        }
        let screens = UIScreen.screens.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))\($0 === UIScreen.main ? " main" : "")\($0.mirrored != nil ? " mirrors" : "")" }
        LogStore.shared.log("[display] \(when): \(UIScreen.screens.count) screen(s) [\(screens.joined(separator: ", "))], \(scenes.count) scene(s) [\(scenes.joined(separator: ", "))]")
        // What else says a display is attached: the screen is being captured or mirrored, and the audio route is AirPlay or HDMI.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ", ")
        let plist = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") != nil
        LogStore.shared.log("[display] \(when): captured=\(UIScreen.main.isCaptured) mirrored=\(UIScreen.main.mirrored != nil) audio-out=[\(outputs)] scene-manifest-in-app=\(plist)")
    }

    private func screenConnected(_ screen: UIScreen) {
        LogStore.shared.log("[display] a screen was connected: \(Int(screen.bounds.width))x\(Int(screen.bounds.height)) scale \(screen.scale)")
        report("after the screen connected")
        // A scene for it may already exist (or arrive a moment later through the scene notification).
        if window == nil,
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.screen === screen && Self.isExternalRole($0.session.role) }) {
            connect(scene: scene, session: scene.session)
        }
    }

    private func sceneConnecting(_ scene: UIScene) {
        let role = scene.session.role
        let screen = (scene as? UIWindowScene)?.screen
        LogStore.shared.log("[display] scene connecting: role=\(role.rawValue) screen=\(screen.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "?")")
        guard Self.isExternalRole(role), let windowScene = scene as? UIWindowScene else { return }
        // The scene delegate (below) normally makes the window itself; this is the fallback if it was not used.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.window == nil, windowScene.session.scene != nil else { return }
            LogStore.shared.log("[display] the scene delegate was not called; making the window from the notification")
            self.connect(scene: windowScene, session: windowScene.session)
        }
    }

    func connect(scene: UIWindowScene, session: UISceneSession) {
        guard window == nil else { return }
        guard Self.isEnabled else {
            // Mirroring is what the person gets with the setting off: ask iOS to drop the scene it just made.
            LogStore.shared.log("[display] a display was connected but \"Use a connected display\" is off: leaving it to mirroring")
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { _ in }
            return
        }
        let w = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        let box = UIView()
        box.backgroundColor = .black
        box.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), box.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            box.topAnchor.constraint(equalTo: root.view.topAnchor), box.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        let mark = UIImageView(image: UIImage(named: "PortholeMark"))
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = "Start a game on your iPhone or iPad to play it here."
        label.textColor = UIColor(white: 1, alpha: 0.6)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(mark); box.addSubview(label)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: box.centerXAnchor), mark.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -40),
            mark.widthAnchor.constraint(equalTo: box.heightAnchor, multiplier: 0.22), mark.heightAnchor.constraint(equalTo: mark.widthAnchor),
            label.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 28),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -40),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        ])
        w.rootViewController = root
        w.isHidden = false
        window = w; container = box; self.session = session; idleLabel = label
        let b = scene.screen.bounds
        name = "\(Int(b.width)) \u{00D7} \(Int(b.height)) display"
        LogStore.shared.log("[display] external display connected: \(Int(b.width))x\(Int(b.height)) pt, scale \(scene.screen.scale), \(scene.screen.maximumFramesPerSecond) Hz")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func disconnect(scene: UIScene) {
        guard Self.isExternalRole(scene.session.role), session?.persistentIdentifier == scene.session.persistentIdentifier else { return }
        LogStore.shared.log("[display] external display disconnected")
        winios_set_compositor_container(nil)
        window?.isHidden = true
        window = nil; container = nil; session = nil; idleLabel = nil; name = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Layout

    /// Where the game goes on the other screen: the guest desktop aspect-fitted into the container.
    func fitRect(guestWidth: CGFloat, guestHeight: CGFloat) -> CGRect {
        guard let container, guestWidth > 0, guestHeight > 0 else { return .zero }
        let b = container.bounds
        let s = min(b.width / guestWidth, b.height / guestHeight)
        let size = CGSize(width: guestWidth * s, height: guestHeight * s)
        return CGRect(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Hide the "start a game" text while a game's picture is up.
    func setGameShowing(_ showing: Bool) { idleLabel?.isHidden = showing }
}


/// The scene iOS makes for a connected display (named for the external-display role in Info.plist and by `PortholeAppDelegate`), as Amethyst does it.
@objc(PortholeExternalSceneDelegate)
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        LogStore.shared.log("[display] the external scene delegate was called")
        Task { @MainActor in ExternalDisplay.shared.connect(scene: windowScene, session: session) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Task { @MainActor in ExternalDisplay.shared.disconnect(scene: scene) }
    }
}
