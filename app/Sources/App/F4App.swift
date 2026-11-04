// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

@main
struct F4App: App {
    @StateObject private var model = AppModel.shared
    @State private var updates = UpdateService()

    init() {
        PointerScrollEverywhere.install()          // every scroll view takes a mouse: wheel, trackpad and press-and-drag
        OnDevicePairing.registerBackgroundTask()
        // The download card's buttons run here, possibly before any window exists.
        DownloadActivityBridge.handler = { action, store in
            DispatchQueue.main.async { DownloadActivity.shared.handle(action, store: store) }
        }
        DispatchQueue.main.async { DownloadActivity.shared.cleanUp() }
        // `-portholeURL <porthole:// link>` on the command line (tools/ipad.sh starts the app this way through devicectl, which can only come from a computer paired with
        // this device): the same links as the Home Screen shortcuts, but delivered as a launch argument because devicectl's --payload-url does not reach onOpenURL.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-portholeURL"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            DispatchQueue.main.async { ShortcutRouter.handle(url, fromComputer: true) }
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .environmentObject(model)
                .environmentObject(model.session)
                .environment(updates)
                .onOpenURL { ShortcutRouter.handle($0) }
        }
    }
}
