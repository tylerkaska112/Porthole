// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The ring of light around whatever is selected: a slowly turning two-colour edge, with a soft halo outside it.
struct GlowRing: View {
    var radius: CGFloat = 18
    var lineWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let strength = Theme.glowStrength
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || strength == 0)) { context in
            let angle = reduceMotion ? 30 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360
            let gradient = AngularGradient(colors: [Theme.accent, Theme.accent2, Theme.accent], center: .center, angle: .degrees(angle))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(gradient, lineWidth: lineWidth)
                .shadow(color: Theme.accent.opacity(0.75 * strength), radius: 10)
                .shadow(color: Theme.accent2.opacity(0.5 * strength), radius: 26)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Lifts the thing and wraps it in the glow ring while it is selected or focused.
    func focusGlow(_ active: Bool, radius: CGFloat = 18, scale: CGFloat = 1.04) -> some View {
        self
            .scaleEffect(active ? scale : 1)
            .overlay { if active { GlowRing(radius: radius).scaleEffect(active ? scale : 1).transition(.opacity) } }
            .zIndex(active ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: active)
    }
}

/// The background of every screen: a deep gradient with two soft coloured lights drifting behind it, in the colours of the chosen scheme.
struct AmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var animated = true

    var body: some View {
        let moving = animated && ThemeStore.shared.animatedBackground && !reduceMotion
        ZStack {
            Theme.background
            if colorScheme == .dark {
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !moving)) { context in
                    let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
                    GeometryReader { geo in
                        let w = geo.size.width, h = geo.size.height
                        orb(Theme.accent, 0.17, size: max(w, h) * 0.8).position(x: w * (0.15 + 0.06 * sin(t / 9)), y: h * (0.10 + 0.05 * cos(t / 11)))
                        orb(Theme.accent2, 0.09, size: max(w, h) * 0.8).position(x: w * (0.88 + 0.05 * cos(t / 10)), y: h * (0.95 + 0.04 * sin(t / 8)))
                        SeasonalDecor(decor: ThemeStore.shared.palette.decor, time: context.date.timeIntervalSinceReferenceDate, moving: moving)
                    }
                }
                if ThemeStore.shared.palette.decor != .none {
                    // Behind every screen's text and panels, above the moon and the embers. (Home draws its own sky above its picture.)
                    if animated, !BatsPlacement.shared.homeDrawsThem { FestiveSky() }
                    FestiveCorners()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func orb(_ color: Color, _ opacity: Double, size: CGFloat) -> some View {
        Circle().fill(RadialGradient(colors: [color.opacity(opacity * max(Theme.glowStrength, 0.4) * 1.2), .clear], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

/// The name older screens use for a plain page background.
typealias AppBackdrop = AmbientBackdrop
