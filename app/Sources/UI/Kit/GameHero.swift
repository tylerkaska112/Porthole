// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The top of a game's page, drawn from plain values: the game's picture as a card with its name on it, how it runs, Play, and three numbers about the game.

struct GameHeroStat: Identifiable, Equatable {
    var symbol: String
    var title: String
    var value: String
    var id: String { title }
}

struct GameHero<Chips: View>: View {
    let id: UUID
    let name: String
    let stats: [GameHeroStat]
    var playTitle = "Play"
    var playEnabled = true
    let play: () -> Void
    /// Set when the hero carries its own Back button (the side pane); the stacked page has one in a bar above.
    var back: (() -> Void)?
    /// A phone held sideways: less of everything, the numbers on one line.
    var compact = false
    @ViewBuilder var chips: Chips

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            if compact {
                HStack(spacing: 10) {
                    if let back { PillButton(id: "gp-back", title: "Home", symbol: "chevron.left", action: back) }
                    Spacer(minLength: 0)
                    playButton
                }
            } else if let back {
                PillButton(id: "gp-back", title: "Home", symbol: "chevron.left", action: back)
            }
            artCard
            FlowLayout(spacing: 8) { chips }
            if compact {
                Text(stats.map(\.value).joined(separator: "  \u{00B7}  ")).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
            } else {
                playButton
                statTiles
            }
        }
    }

    private var playButton: some View {
        PillButton(id: "gp-play", title: playTitle, symbol: "play.fill", style: .primary, enabled: playEnabled, action: play)
    }

    /// The picture, with a shade at its foot and the name written over it.
    private var artCard: some View {
        Color.clear.aspectRatio(compact ? 460.0 / 215.0 : 16.0 / 9.0, contentMode: .fit)
            .overlay { GameArtView(id: id, name: name, kind: .hero, titled: true) }
            .overlay(alignment: .bottom) { LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.45), location: 0.45), .init(color: .black.opacity(0.88), location: 1)], startPoint: .top, endPoint: .bottom).frame(height: compact ? 64 : 130) }
            .overlay(alignment: .bottomLeading) {
                Text(name).font(.system(size: compact ? 20 : 30, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2).padding(compact ? 10 : 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 24, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            .accessibilityElement(children: .ignore).accessibilityLabel(name)
    }

    private var statTiles: some View { GameStatTiles(stats: stats) }
}

/// Up to three numbers about a game as small tiles in a row: an icon, the value, what it is.
struct GameStatTiles: View {
    let stats: [GameHeroStat]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: stat.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(stat.value).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text(stat.title).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The top of a store's game page (Steam, Epic): the game's picture as a card with its name on it, who made it and when, how it runs, the buttons for what can be done now (install,
/// pause, update, play) and three numbers about it. The same shape as a library game's page, so the two feel like one app.
struct StoreHero<Art: View, Chips: View, Actions: View>: View {
    let name: String
    var subtitle: String?
    let stats: [GameHeroStat]
    /// Set when the hero carries its own Back button (the side pane); the stacked page has one in a bar above.
    var back: (() -> Void)?
    var backTitle = "Back"
    var compact = false
    @ViewBuilder var art: Art
    @ViewBuilder var chips: Chips
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            if let back { PillButton(id: "sp-back", title: backTitle, symbol: "chevron.left", action: back) }
            Color.clear.aspectRatio(compact ? 460.0 / 215.0 : 16.0 / 9.0, contentMode: .fit)
                .overlay { art }
                .overlay(alignment: .bottom) { LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.45), location: 0.45), .init(color: .black.opacity(0.88), location: 1)], startPoint: .top, endPoint: .bottom).frame(height: compact ? 64 : 130) }
                .overlay(alignment: .bottomLeading) {
                    Text(name).font(.system(size: compact ? 20 : 30, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2).padding(compact ? 10 : 16)
                }
                .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 24, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                .accessibilityElement(children: .ignore).accessibilityLabel(name)
            if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.system(size: compact ? 13 : 15, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75)) }
            FlowLayout(spacing: 8) { chips }
            actions
            if !stats.isEmpty { GameStatTiles(stats: stats) }
        }
    }
}
