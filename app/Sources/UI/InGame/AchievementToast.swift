// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

/// The pop-ups for achievements unlocked while a Steam game runs: one at a time, each for a few seconds, in the order they were earned.
@MainActor
final class AchievementToastCenter: ObservableObject {
    static let shared = AchievementToastCenter()
    static let enabledKey = "steam.achievementToasts"
    /// On unless the person turned it off.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); AchievementToastCenter.shared.objectWillChange.send() }
    }

    /// When a game asks for Steam's overlay, show the app's Steam menu instead (on unless the person turned it off).
    static let overlayKey = "steam.overlayOpensMenu"
    static var overlayOpensMenu: Bool {
        get { UserDefaults.standard.object(forKey: overlayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: overlayKey) }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let achievement: SteamAchievement
        let appID: Int
    }

    @Published private(set) var current: Toast?
    private var queue: [Toast] = []

    func post(_ achievement: SteamAchievement, appID: Int) {
        guard Self.enabled else { return }
        queue.append(Toast(achievement: achievement, appID: appID))
        pump()
    }

    /// What a real one looks like, from the Steam tab of the in-game menu.
    func showTest() {
        post(SteamAchievement(apiName: "PORTHOLE_TEST", name: "Pop-ups are working", detail: "This is how an unlocked achievement will look.", hidden: false), appID: 0)
    }

    func clear() { queue.removeAll(); current = nil }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let toast = queue.removeFirst()
        current = toast
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self, self.current?.id == toast.id else { return }
            self.current = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pump() }
        }
    }
}

/// Drawn over the game at the top centre; it takes no touches.
struct AchievementToastView: View {
    @ObservedObject private var center = AchievementToastCenter.shared

    var body: some View {
        VStack {
            if let toast = center.current {
                card(toast).transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8).padding(.horizontal, 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: center.current?.id)
        .allowsHitTesting(false)
    }

    private func card(_ toast: AchievementToastCenter.Toast) -> some View {
        let item = toast.achievement
        return AchievementToastCard(name: item.name, detail: item.detail, icon: toast.appID == 0 ? nil : item.iconURL(app: toast.appID), lifetime: 5.5)
            .frame(maxWidth: 440, alignment: .leading)
    }
}
