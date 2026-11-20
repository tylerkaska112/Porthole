// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Tells the Discord session what the person is doing in Porthole (a game running, a download, which screen they are on), so that, when they turned the activity on, their friends see it.
/// It looks again whenever the screen or the game changes, and every few seconds for downloads (they have no single place that announces them). It does nothing while the setting is off.
@MainActor
final class DiscordPresenceCoordinator {
    static let shared = DiscordPresenceCoordinator()
    private weak var router: AppRouter?
    private weak var session: SessionController?
    private var timer: Timer?

    private init() {}

    func attach(router: AppRouter, session: SessionController) {
        self.router = router; self.session = session
        DiscordSession.shared.onActivitySettingChanged = { [weak self] in self?.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    func refresh() {
        let discord = DiscordSession.shared
        guard discord.shareActivity else { discord.presenceChanged(nil); return }
        let game = (session?.isActive == true && session?.launchGameUp == true) ? session?.game?.name : nil
        let downloads = game == nil ? Downloads.items().filter { $0.kind == .running }.map(\.title) : []
        let tab = router.map { String(describing: $0.tab) } ?? ""
        discord.presenceChanged(DiscordActivity.kind(game: game, downloading: downloads, tab: tab))
    }
}
