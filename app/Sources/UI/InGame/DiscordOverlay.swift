// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// What the Discord overlay shows and where (Discord branch, experimental). It is the list of people in the call you are in, over the game, with a ring round whoever is talking.
/// On by default, but it only appears while a call is running. Kept between games.
@MainActor
final class DiscordOverlaySettings: ObservableObject {
    static let shared = DiscordOverlaySettings()
    private static let prefix = "f4.discord.overlay."

    @Published var enabled: Bool { didSet { save() } }
    @Published var corner: OverlayCorner { didSet { save() } }
    @Published var size: OverlaySize { didSet { save() } }
    @Published var opacity: Double { didSet { save() } }
    /// Show only the people who are talking right now, instead of everyone in the call.
    @Published var onlySpeaking: Bool { didSet { save() } }
    /// Where the layout in use puts the overlay (not saved: it comes from the layout); nil = in the chosen corner.
    @Published var placement: OverlayPlacement?

    private init() {
        let d = UserDefaults.standard, p = Self.prefix
        enabled = d.object(forKey: p + "enabled") as? Bool ?? true
        corner = OverlayCorner(rawValue: d.string(forKey: p + "corner") ?? "") ?? .topLeading
        size = OverlaySize(rawValue: d.string(forKey: p + "size") ?? "") ?? .medium
        opacity = d.object(forKey: p + "opacity") as? Double ?? 0.75
        onlySpeaking = d.bool(forKey: p + "onlySpeaking")
    }

    private func save() {
        let d = UserDefaults.standard, p = Self.prefix
        d.set(enabled, forKey: p + "enabled")
        d.set(corner.rawValue, forKey: p + "corner")
        d.set(size.rawValue, forKey: p + "size")
        d.set(opacity, forKey: p + "opacity")
        d.set(onlySpeaking, forKey: p + "onlySpeaking")
    }
}

/// The overlay itself. It never takes touches: they go to the game.
struct DiscordOverlayView: View {
    @ObservedObject var settings: DiscordOverlaySettings
    @ObservedObject var discord: DiscordSession

    var body: some View {
        GeometryReader { geo in
            let shown = settings.onlySpeaking ? discord.callMembers.filter(\.speaking) : discord.callMembers
            let font = settings.size.font
            let list = VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { member in
                    HStack(spacing: 6) {
                        DiscordAvatar(member: member, diameter: font * 2)
                        Text(member.name).font(.system(size: font, weight: member.speaking ? .bold : .medium)).foregroundStyle(.white)
                            .lineLimit(1).frame(maxWidth: font * 14, alignment: .leading)
                    }
                    .opacity(member.speaking ? 1 : 0.75)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(settings.opacity * 0.7)))
            .opacity(shown.isEmpty ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: shown)
            if let at = settings.placement {
                PlacedAtFraction(at: at, room: geo.size) { list }
            } else {
                list.frame(width: geo.size.width, height: geo.size.height, alignment: settings.corner.alignment)
            }
        }
    }
}
