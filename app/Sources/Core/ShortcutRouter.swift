// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// Home Screen shortcuts: `porthole://play?exe=<Windows path>` starts that game if it is in the library (after JIT, like Play on its page). A game's page copies the link;
/// the Shortcuts app turns an "Open URL" action with it into a Home Screen icon.
@MainActor
enum ShortcutRouter {
    static func link(for windowsPath: String) -> String {
        var c = URLComponents()
        c.scheme = "porthole"
        c.host = "play"
        c.queryItems = [URLQueryItem(name: "exe", value: windowsPath)]
        return c.string ?? "porthole://play"
    }

    /// Settings > Advanced > "Allow remote-control links". Everything but `play` (which only starts a game already in the library) needs it, so another app or a web page can
    /// not change a game's settings or install an update by opening a link.
    static let remoteKey = "f4.remoteLinks"
    static var remoteAllowed: Bool { UserDefaults.standard.bool(forKey: remoteKey) }

    /// Settings > Advanced > "Ask before a link starts a game" (on by default): any web page or app can open a `porthole://play` link, so the person is asked.
    static let confirmKey = "f4.confirmLinkLaunch"
    static var confirmsLinks: Bool { UserDefaults.standard.object(forKey: confirmKey) as? Bool ?? true }

    /// Settings keys and values a link may write to a game's own madeira.cfg lines: plain names and numbers only.
    private static func plain(_ text: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !text.isEmpty) && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// `fromComputer`: the link came in as a launch argument from a paired computer, which is already trusted to install anything, so the Advanced toggle is not needed.
    static func handle(_ url: URL, fromComputer: Bool = false) {
        guard url.scheme?.lowercased() == "porthole", let host = url.host?.lowercased() else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        switch host {
        case "vpn":
            // The Shortcut that turns the person's VPN back on ends here: the app is in front again, so see whether it worked.
            Task { @MainActor in
                VPNGuard.shared.shortcutReturned()      // a launch waiting for the VPN carries on
                try? await Task.sleep(for: .seconds(1.5))
                VPNGuard.shared.recheck()
            }
        case "cellular":
            // Shortcuts is done with "Porthole Cellular Off" or "Porthole Cellular On" and has brought the app back.
            CellularGuard.shared.shortcutReturned(value("result"))
        case "play":
            guard let exe = value("exe"), !exe.isEmpty else { return }
            LogStore.shared.log("[shortcut] asked to start \(exe)")
            // `peek=1` (dev switch, computer-delivered links only): skip the launch screen and show the Steam window (the desktop) as soon as it can be shown.
            start(exe: exe, triesLeft: 40, peek: fromComputer && value("peek") == "1", ask: !fromComputer && confirmsLinks)
        case "stop", "config", "update":
            guard remoteAllowed || fromComputer else { LogStore.shared.log("[remote] \(host): remote-control links are off (Settings > Advanced)", level: .error); return }
            switch host {
            case "stop":
                AppModel.shared.session.dismiss()
                LogStore.shared.log("[remote] stop: an ended game was cleared")
            case "config": config(exe: value("exe"), set: value("set"), unset: value("unset"), triesLeft: 40)
            default: update()
            }
        default: return
        }
    }

    /// Starts the library game with this program. A launch from a link arrives before the library has loaded, so it waits a little for it.
    private static func start(exe: String, triesLeft: Int, peek: Bool = false, ask: Bool = false) {
        let model = AppModel.shared
        guard let game = model.games.first(where: { $0.exe.caseInsensitiveCompare(exe) == .orderedSame }) else {
            if triesLeft > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start(exe: exe, triesLeft: triesLeft - 1, peek: peek, ask: ask) }; return }
            LogStore.shared.log("[shortcut] no game in the library with that program", level: .error)
            return
        }
        if ask {
            confirmLaunch(of: game) { begin(game, peek: peek) }
        } else {
            begin(game, peek: peek)
        }
    }

    /// A link from outside the app wants to start a game: say so and let the person decide.
    private static func confirmLaunch(of game: Game, go: @escaping () -> Void) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(title: "Start \(game.name)?", message: "A link outside Porthole asked to start this game.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in LogStore.shared.log("[shortcut] the person declined the link") })
        alert.addAction(UIAlertAction(title: "Start", style: .default) { _ in go() })
        top.present(alert, animated: true)
    }

    private static func begin(_ game: Game, peek: Bool) {
        let model = AppModel.shared
        model.session.dismiss()   // a game that has ended is cleared first; one that is running is not
        guard !model.session.isActive else { LogStore.shared.log("[shortcut] a game is already running; not starting another"); return }
        model.session.start(game)
        if peek { peekWhenPossible(model.session, triesLeft: 240) }
    }

    /// Dev switch: shows the Steam window (the desktop) in place of the launch screen as soon as the session allows it, so a screenshot shows what the game's host prints.
    private static func peekWhenPossible(_ session: SessionController, triesLeft: Int) {
        if session.canPeekAtSteam { session.launchPeeking = true; LogStore.shared.log("[remote] peek: the Steam window is shown instead of the launch screen"); return }
        guard triesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { peekWhenPossible(session, triesLeft: triesLeft - 1) }
    }

    /// `config?exe=<path>&set=key=value` adds or replaces that line in the game's own config; `unset=key` removes it.
    private static func config(exe: String?, set: String?, unset: String?, triesLeft: Int) {
        let model = AppModel.shared
        guard let exe, let game = model.games.first(where: { $0.exe.caseInsensitiveCompare(exe) == .orderedSame }) else {
            if exe != nil, triesLeft > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { config(exe: exe, set: set, unset: unset, triesLeft: triesLeft - 1) }; return }   // the library is still loading
            LogStore.shared.log("[remote] config: no game in the library with that program", level: .error); return
        }
        var key = "", newLine: String?
        if let set {
            let parts = set.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, plain(parts[0]), plain(parts[1], allowEmpty: true) else { LogStore.shared.log("[remote] config: refused (only plain names and numbers)", level: .error); return }
            key = parts[0]; newLine = "\(parts[0]) = \(parts[1])"
        } else if let unset, plain(unset) { key = unset } else { LogStore.shared.log("[remote] config: nothing to do", level: .error); return }
        model.update(game) { g in
            var engine = g.engine ?? GameEngine()
            var lines = (engine.config ?? "").components(separatedBy: "\n").filter { line in
                let name = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return name != key
            }
            if let newLine { lines.append(newLine) }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            engine.config = text.isEmpty ? nil : text
            g.engine = engine.isEmpty ? nil : engine
        }
        LogStore.shared.log("[remote] config: \(newLine ?? "removed \(key)") for \(game.name)")
    }

    /// Installs the newest published build, the same as Settings > Updates > Update to ...
    private static func update() {
        guard let updates = UpdateService.current else { LogStore.shared.log("[remote] update: the update service is not ready", level: .error); return }
        Task { @MainActor in
            await updates.check()
            guard let release = updates.available else { LogStore.shared.log("[remote] update: already up to date (\(updates.version) build \(updates.build))"); return }
            guard updates.vault.canSign, !updates.pipeline.isBusy else { LogStore.shared.log("[remote] update: no certificate or an install is already running", level: .error); return }
            LogStore.shared.log("[remote] update: installing \(release.title)")
            updates.startUpdate(release)
        }
    }
}
