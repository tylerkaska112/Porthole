// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

/// Tells UIKit which orientations the app allows right now. Without this the answer is the Info.plist list; with it a running game can hold the screen in landscape.
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { AutoLandscape.mask }

    /// SwiftUI answers for every scene unless the app delegate says otherwise: the external-display role gets its delegate class here, every other role is left to SwiftUI.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        LogStore.shared.log("[display] iOS asked for a scene configuration: role=\(role.rawValue)")
        if role == .windowExternalDisplayNonInteractive || role.rawValue == "UIWindowSceneSessionRoleExternalDisplay" {
            let config = UISceneConfiguration(name: "External Display", sessionRole: role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: role)
    }
}

/// Turns the screen to landscape when a game starts and keeps it there while the game runs, for people who play lying down or with the rotation lock on.
/// The app-wide switch is in Settings > Display; a game's own page can override it. A request the app makes itself works with the system's rotation lock on.
enum AutoLandscape {
    static let key = "f4.autoLandscape"

    /// What the Info.plist allows: an iPhone never turns upside down, an iPad can.
    private static var normal: UIInterfaceOrientationMask { UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown }
    /// Read by UIKit on the main thread (the delegate method) and written on it (`apply`).
    nonisolated(unsafe) static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown

    /// On unless the person switched it off.
    static var appWide: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Whether this game should run in landscape: its own choice (1 landscape, 0 any orientation), else the app-wide one.
    static func wanted(perGame: Int?, appWide: Bool) -> Bool { perGame.map { $0 == 1 } ?? appWide }
    static func wanted(for game: Game?) -> Bool { wanted(perGame: game?.settings?.autoLandscape, appWide: appWide) }

    /// Holds the screen in landscape (and turns it, when it is upright) or lets every orientation back in.
    @MainActor static func apply(landscape: Bool) {
        mask = landscape ? .landscape : normal
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.session.role == .windowApplication && $0.activationState != .unattached }) else { return }
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        guard landscape, !scene.interfaceOrientation.isLandscape else {
            LogStore.shared.log("[orientation] \(landscape ? "already landscape, held" : "released")")
            return
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
            Task { @MainActor in LogStore.shared.log("[orientation] turning to landscape was refused: \(error.localizedDescription)", level: .error) }
        }
        LogStore.shared.log("[orientation] turned to landscape for the game")
    }
}
