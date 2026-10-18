// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit
import UserNotifications

/// "Restart game": closes the running game and the app (a game cannot be started twice in one process), then starts the same game again when Porthole is opened next, after
/// any Workshop downloads that were waiting for the game to end have finished. iOS can't reopen an app by itself, so a notification offers to open it; opening it any other way works too.
@MainActor
final class RestartCoordinator: ObservableObject {
    static let shared = RestartCoordinator()

    /// The game that is about to start again (the notice on the Home screen shows it with a Cancel button).
    @Published private(set) var starting: String?

    private static let key = "f4.restartGame"
    private static let validFor: TimeInterval = 30 * 60
    private var cancelled = false
    private var closing: Task<Void, Never>?

    /// Closes the game the way "Close game" does (so it can save), and when it has ended closes the app and offers to open it again.
    func restart(_ game: Game, session: SessionController) {
        guard closing == nil else { return }
        answer = nil
        UserDefaults.standard.set(["id": game.id.uuidString, "at": Date().timeIntervalSince1970], forKey: Self.key)
        LogStore.shared.log("[restart] closing \(game.name) to start it again")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        session.requestClose()
        closing = Task { @MainActor in
            let began = Date()
            var asked = false, retried = false
            // The game has up to ten minutes to close itself (a menu may need an answer). Some games ignore Alt+F4: after a few seconds the person is asked whether to stop the game.
            while Date().timeIntervalSince(began) < 600 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if session.state == .ended || session.state == .idle {
                    self.dismissPrompt()
                    LogStore.shared.log("[restart] \(game.name) closed; closing Porthole")
                    self.offerToReopen(game)
                    session.closeApp()
                    return
                }
                if !retried, Date().timeIntervalSince(began) > 4 { retried = true; session.requestClose() }     // once more, in case the first was lost
                if !asked, Date().timeIntervalSince(began) > 8 {
                    asked = true
                    LogStore.shared.log("[restart] \(game.name) did not close after the close request; asking whether to stop it")
                    self.promptToStop(game)
                }
                switch self.answer {
                case .stop:
                    LogStore.shared.log("[restart] the person chose to stop \(game.name)")
                    self.offerToReopen(game)
                    session.closeApp()
                    return
                case .keep:
                    LogStore.shared.log("[restart] the person kept playing; the restart was dropped")
                    UserDefaults.standard.removeObject(forKey: Self.key)
                    self.answer = nil; self.closing = nil
                    return
                case nil: break
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.key)
            self.dismissPrompt()
            self.closing = nil
            LogStore.shared.log("[restart] the game did not close; the restart was dropped", level: .error)
        }
    }

    private enum Answer { case stop, keep }
    private var answer: Answer?
    private weak var prompt: UIAlertController?

    private func promptToStop(_ game: Game) {
        answer = nil
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { answer = .stop; return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(title: "\(game.name) did not close", message: "Some games ignore the close request. Stop it now and start it again? Anything not saved in the game is lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep playing", style: .cancel) { [weak self] _ in self?.answer = .keep })
        alert.addAction(UIAlertAction(title: "Stop and restart", style: .destructive) { [weak self] _ in self?.answer = .stop })
        prompt = alert
        top.present(alert, animated: true)
    }

    private func dismissPrompt() { prompt?.dismiss(animated: true); prompt = nil }

    private func offerToReopen(_ game: Game) {
        let content = UNMutableNotificationContent()
        content.title = "Start \(game.name) again"
        content.body = "Tap to open Porthole. It starts the game with your new Workshop items."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "f4.restart", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    /// Called when Porthole opens: if a restart was asked for a moment ago, starts that game once the Workshop downloads for it are done (at most two minutes).
    func resumeIfPending(model: AppModel) async {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.key) else { return }
        UserDefaults.standard.removeObject(forKey: Self.key)
        guard let id = (saved["id"] as? String).flatMap(UUID.init(uuidString:)), let at = saved["at"] as? Double, Date().timeIntervalSince1970 - at < Self.validFor else { return }
        cancelled = false
        var game: Game?
        for _ in 0..<40 {
            game = model.games.first { $0.id == id }
            if game != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let game else { return }
        starting = game.name
        defer { starting = nil }
        let appID = game.steamAppID ?? game.dockAppID
        let workshop = SteamWorkshopStore.shared
        try? await Task.sleep(for: .seconds(4))               // gives items that waited for the game to end time to start
        let began = Date()
        while !cancelled, Date().timeIntervalSince(began) < 120, let appID, workshop.hasPending(appID: appID) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !cancelled else { LogStore.shared.log("[restart] cancelled"); return }
        LogStore.shared.log("[restart] starting \(game.name) again")
        model.session.dismiss()
        guard !model.session.isActive else { return }
        model.session.start(game)
    }

    func cancel() { cancelled = true }
}
