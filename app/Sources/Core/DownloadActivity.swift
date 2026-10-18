// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import ActivityKit
import Foundation

/// The download card on the lock screen and in the Dynamic Island (the F4Activity extension draws it): the game, percentage, size, speed and time left, with
/// Pause / Resume and Cancel buttons. One card per store while that store has downloads. Without the extension in the install, or with Live Activities turned off
/// for the app, there is no card and iOS's own download card (SteamBackground / EpicBackground) is used instead.
@MainActor final class DownloadActivity {
    static let shared = DownloadActivity()

    private struct Card {
        var activity: Activity<DownloadActivityAttributes>
        var state: DownloadActivityAttributes.ContentState
        var lastPush = Date.distantPast
        var linger: Task<Void, Never>?
    }
    private var cards: [String: Card] = [:]

    /// The extension is inside this install and the person has not turned Live Activities off.
    static var available: Bool { InstallCheck.hasActivityExtension && ActivityAuthorizationInfo().areActivitiesEnabled }

    func hasCard(_ store: String) -> Bool { cards[store] != nil }

    /// Ends the cards a previous run left behind.
    func cleanUp() {
        guard InstallCheck.hasActivityExtension else { return }
        for activity in Activity<DownloadActivityAttributes>.activities where !cards.values.contains(where: { $0.activity.id == activity.id }) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// A download became active for `store`.
    func begin(store: String, name: String) {
        guard Self.available else { return }
        var state = cards[store]?.state ?? .init(title: name, line: "Preparing\u{2026}", fraction: 0)
        state.title = name; state.paused = false; state.finished = false; state.failed = false
        if var card = cards[store] {
            card.linger?.cancel(); card.linger = nil
            DownloadKeepAlive.shared.release("activity-" + store)
            card.state = state
            cards[store] = card
            push(store, force: true)
            return
        }
        do {
            let activity = try Activity.request(attributes: DownloadActivityAttributes(store: store), content: .init(state: state, staleDate: nil), pushType: nil)
            cards[store] = Card(activity: activity, state: state, lastPush: Date())
        } catch {
            SteamLog.event("[bg-download] live activity refused: \((error as NSError).code)")
        }
    }

    /// The running download's progress (at most once a second reaches the card).
    func update(store: String, name: String, progress: SteamDownloadProgress, waiting: Int) {
        guard var card = cards[store] else { return }
        card.state.title = name
        card.state.line = DownloadCardText.detail(progress)
        card.state.fraction = progress.phase == .downloading ? progress.fraction : card.state.fraction
        card.state.waiting = waiting
        card.state.paused = false
        cards[store] = card
        push(store, force: false)
    }

    /// The queue stopped and the person may want it back: the card stays with a Resume button for a while.
    func paused(store: String, name: String) {
        guard var card = cards[store] else { return }
        card.state.paused = true; card.state.title = name; card.state.line = "Paused \u{00B7} tap Resume to continue"
        card.linger?.cancel()
        DownloadKeepAlive.shared.hold("activity-" + store)         // the Resume button needs the app to still be running
        card.linger = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.end(store: store, failed: false, message: nil, finished: false)
        }
        cards[store] = card
        push(store, force: true)
    }

    /// The queue is over: done, stopped with a problem, or simply gone (cancelled, or a game started).
    func end(store: String, failed: Bool, message: String?, finished: Bool) {
        guard let card = cards.removeValue(forKey: store) else { return }
        card.linger?.cancel()
        DownloadKeepAlive.shared.release("activity-" + store)
        var state = card.state
        let lingers = finished || failed
        if lingers {
            state.finished = true; state.failed = failed; state.paused = false
            state.fraction = failed ? state.fraction : 1
            state.line = message ?? (failed ? "The download stopped." : "Ready to play")
        }
        Task {
            await card.activity.end(.init(state: state, staleDate: nil), dismissalPolicy: lingers ? .after(Date().addingTimeInterval(failed ? 120 : 20)) : .immediate)
        }
    }

    private func push(_ store: String, force: Bool) {
        guard var card = cards[store] else { return }
        guard force || Date().timeIntervalSince(card.lastPush) >= 1 else { return }
        card.lastPush = Date()
        cards[store] = card
        let state = card.state
        let activity = card.activity
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    // MARK: The card's buttons

    /// Runs in the app's process, from a button on the card.
    func handle(_ action: DownloadActivityAction, store: String) {
        switch (store, action) {
        case ("steam", .pause): SteamStore.shared.pauseAll()
        case ("steam", .resume): SteamStore.shared.resumeAll()
        case ("steam", .cancel): SteamStore.shared.cancelCurrent()
        case ("epic", .pause): EpicInstaller.shared.pauseAll()
        case ("epic", .resume): EpicInstaller.shared.resumeAll()
        case ("epic", .cancel): EpicInstaller.shared.cancelCurrent()
        case ("gog", .pause): GogInstaller.shared.pauseAll()
        case ("gog", .resume): GogInstaller.shared.resumeAll()
        case ("gog", .cancel): GogInstaller.shared.cancelCurrent()
        case ("itch", .pause): ItchInstaller.shared.pauseAll()
        case ("itch", .resume): ItchInstaller.shared.resumeAll()
        case ("itch", .cancel): ItchInstaller.shared.cancelCurrent()
        case ("amazon", .pause): AmazonInstaller.shared.pauseAll()
        case ("amazon", .resume): AmazonInstaller.shared.resumeAll()
        case ("amazon", .cancel): AmazonInstaller.shared.cancelCurrent()
        default: break
        }
        if action == .pause, let card = cards[store] { paused(store: store, name: card.state.title) }
        if action == .cancel { end(store: store, failed: false, message: nil, finished: false) }
    }
}
