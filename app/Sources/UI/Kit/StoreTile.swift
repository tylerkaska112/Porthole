// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// What every store's game tile shares: how a status looks on the picture, the progress bar under it, and the card's own shape. The stores keep their own data and their own tiles;
// these pieces make them look like one set (and like the tiles on Home).

/// A status on the picture: a round icon in the status's colour, or, while something downloads, a ring that fills with the percent in it.
struct TileStatus: View {
    let badge: BadgeData
    var size: CGFloat = 28

    private var percent: Int? {
        guard badge.text.hasSuffix("%") else { return nil }
        return Int(badge.text.dropLast())
    }

    var body: some View {
        if let percent {
            ZStack {
                Circle().fill(.black.opacity(0.65))
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(percent) / 100).stroke(badge.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(percent)").font(.system(size: size * 0.34, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(.white)
            }
            .frame(width: size + 6, height: size + 6)
            .accessibilityElement(children: .ignore).accessibilityLabel("Downloading \(percent) percent")
        } else {
            BadgeIcon(badge: badge, size: size)
        }
    }
}

/// The thin bar under a downloading game's name.
struct TileProgress: View {
    let value: Double
    var paused = false

    var body: some View {
        Capsule().fill(.white.opacity(0.1)).frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(paused ? AnyShapeStyle(Theme.textDim) : AnyShapeStyle(Theme.accentGradient))
                        .frame(width: max(5, geo.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// The shape every store tile's picture has: a soft shade at the foot, rounded corners, a thin light edge and a shadow.
    func storeTileStyle(radius: CGFloat = 18) -> some View {
        overlay(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom).frame(height: 56).allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
    }
}

// MARK: - A store's game sheet

/// The frame of the sheet GOG, itch.io, Amazon Games and the EA app show for a game: the Porthole background, a Done button and the store at the top, the game's picture as a card
/// with its name on it, then whatever the store has to say and to do.
struct StoreSheetShell<Art: View, Content: View>: View {
    let store: GameStore
    let title: String
    var subtitle: String?
    let close: () -> Void
    @ViewBuilder var art: Art
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(spacing: 0) {
                HStack {
                    StoreChip(store: store)
                    Spacer()
                    PillButton(id: "ss-done", title: "Done", symbol: "xmark", action: close)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                            .overlay { art }
                            .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 90) }
                            .overlay(alignment: .bottomLeading) {
                                Text(title).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2).padding(16)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                        if let subtitle { Text(subtitle).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim) }
                        content
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                    .frame(maxWidth: 640).frame(maxWidth: .infinity)
                }
            }
        }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}

/// A full-width button in a store's game sheet: filled with the accent for the main one, red for one that deletes, quiet for the rest.
struct StoreSheetButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(prominent ? Theme.onAccent : (destructive ? Theme.bad : Theme.text))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background { Capsule().fill(prominent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(destructive ? Theme.bad.opacity(0.14) : Theme.panel)) }
                .overlay(Capsule().strokeBorder(prominent ? Color.clear : (destructive ? Theme.bad.opacity(0.4) : Theme.line), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(CardPress())
    }
}
