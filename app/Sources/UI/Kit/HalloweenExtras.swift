// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

// The rarer, quieter parts of the Halloween look: a witch crossing the moon, eyes blinking in a dark corner, bats roosting under the top bar, a bat circling the launch porthole, and
// the warm light of a pumpkin on its card. They are meant to be noticed now and then, not all the time: each one is rare, faint or small, and none of them ever covers a word.

private func frac(_ v: Double) -> Double { v - floor(v) }
private func smooth(_ v: Double) -> Double { let x = max(0, min(1, v)); return x * x * (3 - 2 * x) }

enum HalloweenNight {
    /// 31 October itself: the rare things come round a little more often.
    /// For the simulator preview, which cannot wait for the date (`--night`).
    nonisolated(unsafe) static var forceTonight = false
    static var isTonight: Bool {
        if forceTonight { return true }
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return c.month == 10 && c.day == 31
    }
}

// MARK: The witch

/// A witch on her broom flying in from the left, rising to pass in front of the moon, and away to the right. Once in a minute or two (every half minute on Halloween night itself).
enum HalloweenWitch {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double, night: Bool) {
        let w = size.width, h = size.height, unit = min(w, h)
        let period = night ? 38.0 : 80.0, active = 14.0
        let local = (t + 55).truncatingRemainder(dividingBy: period)
        guard local < active else { return }
        let p = local / active
        let u = -0.15 + 1.3 * p                                  // across the screen; the moon is at 0.9 of the width
        let y = h * (0.30 + 0.18 * (u - 0.9) * (u - 0.9)) + sin(t * 1.3) * h * 0.008          // a curve that reaches the moon's height as she passes it
        let slope = 2 * 0.18 * (u - 0.9) * h / w
        var c = ctx
        c.translateBy(x: w * u, y: y)
        c.rotate(by: .radians(atan(slope) * 0.8 - 0.05))
        let s = unit * 0.07
        c.scaleBy(x: s, y: s)
        drawWitch(&c, t: t, unit: s)
    }

    private static func drawWitch(_ g: inout GraphicsContext, t: Double, unit: Double) {
        let ink = Color(hex: 0x0D0716).opacity(0.96), rim = Color(hex: 0xB57BFF).opacity(0.5)
        let hair = 1.2 / unit
        func fill(_ path: Path) { g.fill(path, with: .color(ink)); g.stroke(path, with: .color(rim), lineWidth: hair) }
        // The broom: the handle and a fan of bristles that flutters.
        var handle = Path(); handle.move(to: CGPoint(x: -1.6, y: 0.5)); handle.addLine(to: CGPoint(x: 1.3, y: 0.2))
        g.stroke(handle, with: .color(rim), lineWidth: 0.14)
        g.stroke(handle, with: .color(ink), lineWidth: 0.09)
        let flutter = 0.05 * sin(t * 9)
        var bristles = Path()
        bristles.move(to: CGPoint(x: -1.5, y: 0.42))
        for (x, y) in [(-2.4, 0.16), (-2.5, 0.32), (-2.45, 0.5), (-2.5, 0.68), (-2.4, 0.84)] { bristles.addLine(to: CGPoint(x: x, y: y + flutter)) }
        bristles.addLine(to: CGPoint(x: -1.5, y: 0.6)); bristles.closeSubpath()
        fill(bristles)
        // Her cloak streaming out behind.
        var cloak = Path()
        cloak.move(to: CGPoint(x: -0.12, y: -0.5))
        cloak.addQuadCurve(to: CGPoint(x: -1.5, y: -0.15 + 0.12 * sin(t * 4)), control: CGPoint(x: -0.7, y: -0.55))
        cloak.addQuadCurve(to: CGPoint(x: -0.22, y: 0.05), control: CGPoint(x: -0.8, y: -0.05))
        cloak.closeSubpath()
        fill(cloak)
        fill(Path(ellipseIn: CGRect(x: -0.22, y: -0.62, width: 0.42, height: 0.78)))                    // body
        var legs = Path()
        legs.move(to: CGPoint(x: 0, y: 0.15)); legs.addLine(to: CGPoint(x: 0.35, y: 0.33))
        legs.move(to: CGPoint(x: -0.05, y: 0.2)); legs.addLine(to: CGPoint(x: 0.1, y: 0.4))
        g.stroke(legs, with: .color(ink), lineWidth: 0.11)
        var arm = Path(); arm.move(to: CGPoint(x: 0.15, y: -0.35)); arm.addLine(to: CGPoint(x: 0.8, y: 0.15))
        g.stroke(arm, with: .color(ink), lineWidth: 0.09)
        fill(Path(ellipseIn: CGRect(x: -0.1, y: -1.0, width: 0.4, height: 0.4)))                         // head
        fill(Path(ellipseIn: CGRect(x: -0.3, y: -1.03, width: 0.8, height: 0.16)))                       // hat brim
        var hat = Path()
        hat.move(to: CGPoint(x: -0.12, y: -0.95))
        hat.addQuadCurve(to: CGPoint(x: -0.4, y: -1.9), control: CGPoint(x: -0.12, y: -1.5))             // the tip bent back
        hat.addQuadCurve(to: CGPoint(x: 0.32, y: -0.95), control: CGPoint(x: 0.14, y: -1.45))
        hat.closeSubpath()
        fill(hat)
    }
}

// MARK: Eyes in the dark

/// A pair of eyes that opens in a dark corner of the screen, blinks once and closes again. Rare: every half minute or so, for a few seconds.
enum HalloweenEyes {
    private static let spots: [(Double, Double)] = [(0.05, 0.88), (0.04, 0.56), (0.95, 0.87), (0.52, 0.95), (0.965, 0.52), (0.30, 0.96)]

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double, night: Bool) {
        let period = night ? 15.0 : 27.0, visible = 4.2
        let cycle = Int(floor(t / period))
        let local = t - Double(cycle) * period - 6
        guard local >= 0, local < visible else { return }
        let spot = spots[Int(BatFlight.random(cycle, 0, 91) * Double(spots.count)) % spots.count]
        var alpha = min(1, local / 0.5) * min(1, (visible - local) / 0.6)
        if abs(local - 2.0) < 0.1 { alpha *= 0.08 }                                                        // the blink
        let unit = min(size.width, size.height)
        let r = unit * 0.011
        let centre = CGPoint(x: size.width * spot.0, y: size.height * spot.1)
        for side in [-1.0, 1.0] {
            let c = CGPoint(x: centre.x + side * unit * 0.022, y: centre.y)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 3, y: c.y - r * 3, width: r * 6, height: r * 6)), with: .color(Color(hex: 0xFF6A1F).opacity(0.18 * alpha)))
            var eye = Path()
            eye.move(to: CGPoint(x: c.x - r * 1.0, y: c.y + side * 0.0 + r * 0.3))
            eye.addQuadCurve(to: CGPoint(x: c.x + r * 1.0, y: c.y + r * 0.3), control: CGPoint(x: c.x, y: c.y - r * 1.1))
            eye.addQuadCurve(to: CGPoint(x: c.x - r * 1.0, y: c.y + r * 0.3), control: CGPoint(x: c.x, y: c.y + r * 0.9))
            ctx.fill(eye, with: .color(Color(hex: 0xFFC25A).opacity(0.95 * alpha)))
        }
    }
}

// MARK: Bats roosting under the top bar

/// Three bats hang upside down from the lower edge of the top bar with their wings folded. Each one now and then opens its wings, drops, flies off to the side, is gone a while, and
/// comes back to hang again. They are small and sit in the gap under the bar, never over a word.
struct HalloweenRoost: View {
    var barBottom: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Slot { let x: Double, cycle: Double, shift: Double, dir: Double }
    private static let slots = [Slot(x: 0.34, cycle: 70, shift: 0, dir: -1), Slot(x: 0.46, cycle: 83, shift: 31, dir: 1), Slot(x: 0.58, cycle: 97, shift: 58, dir: -1)]

    var body: some View {
        let theme = ThemeStore.shared
        if theme.palette.decor == .halloween, barBottom > 0 {
            let moving = theme.animatedBackground && !reduceMotion
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
                Canvas { ctx, size in
                    let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
                    for (i, slot) in Self.slots.enumerated() { Self.draw(&ctx, slot: i, spec: slot, size: size, barBottom: Double(barBottom), t: t) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func draw(_ ctx: inout GraphicsContext, slot i: Int, spec: Slot, size: CGSize, barBottom: Double, t: Double) {
        let w = size.width
        let s = 9.0
        let hangY = barBottom + 0.62 * s                 // the feet (the end of the body) touch the bar's lower edge once the bat is turned over
        let rx = w * spec.x
        let l = (t + spec.shift).truncatingRemainder(dividingBy: spec.cycle)
        var x = rx, y = hangY, rot = Double.pi, fold = 1.0
        var flap = 0.0
        if l < 36 || l >= 62 {                                           // hanging, swaying a hair
            rot = .pi + 0.05 * sin(t * 0.9 + Double(i))
        } else if l < 37.2 {                                             // wings open as it lets go and swings upright
            let q = (l - 36) / 1.2
            fold = 1 - smooth(q / 0.5)
            rot = .pi * (1 - smooth(q))
            y = hangY + smooth(q) * s * 2.2
            flap = 0.85 * sin(t * 9 + Double(i))
        } else if l < 46 {                                               // away to the side, quicker as it goes
            let q = (l - 37.2) / 8.8
            x = rx + spec.dir * w * 1.2 * pow(q, 1.5)
            y = hangY + s * 2.2 + sin(q * 6 + Double(i)) * s * 1.2 + q * s * 3
            rot = spec.dir * 0.12; fold = 0
            flap = 0.85 * sin(t * 9 + Double(i))
        } else if l < 54 {
            return                                                       // out of sight
        } else {                                                         // back in from the other side, then it turns over and folds to hang
            let q = (l - 54) / 8
            x = rx - spec.dir * w * 1.2 * pow(1 - q, 1.5)
            y = hangY + s * 2.5 * (1 - q) + sin(q * 5 + Double(i)) * s * 1.0 * (1 - q)
            rot = -spec.dir * 0.12 * (1 - q); fold = 0
            flap = 0.85 * sin(t * 9 + Double(i))
            if q > 0.82 {
                let r = smooth((q - 0.82) / 0.18)
                rot = rot * (1 - r) + .pi * r
                fold = r
                y = y * (1 - r) + hangY * r
                x = x * (1 - r) + rx * r
            }
        }
        var c = ctx
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians(rot))
        c.scaleBy(x: s, y: s)
        BatFlight.drawBat(&c, flap: flap, depth: 0.95, eyes: false, unit: s, fold: fold)
    }
}

/// Where the bottom edge of the top bar is, so the roosting bats can hang from it.
struct BarBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: A bat circling the launch porthole

/// One small bat that flies round the ring of the launch screen's porthole, wings beating, while the game starts.
struct HalloweenOrbitBat: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, sz in
                let centre = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let angle = t * 0.7
                let radius = Double(size) * 0.58
                var c = ctx
                c.translateBy(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
                c.rotate(by: .radians(angle + .pi / 2 + 0.15))                      // always flying along the ring
                let s = Double(size) * 0.055
                c.scaleBy(x: s, y: s)
                BatFlight.drawBat(&c, flap: 0.85 * sin(t * 8), depth: 1, eyes: true, unit: s)
            }
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: A pumpkin's light on its card

/// A faint warm flicker along the edge of the card a pumpkin sits on, so it looks lit and not stuck on.
struct HalloweenCardGlow: View {
    var cornerRadius: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = ThemeStore.shared.animatedBackground && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            let flicker = 0.8 + 0.2 * sin(t * 6.3 + 1) * sin(t * 2.7)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RadialGradient(colors: [Color(hex: 0xFF8A1F).opacity(0.12 * flicker), .clear], center: .topTrailing, startRadius: 0, endRadius: 150))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RadialGradient(colors: [Color(hex: 0xFFB04A).opacity(0.7 * flicker), .clear], center: .topTrailing, startRadius: 0, endRadius: 130), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A little feedback when a prop is tapped.
func halloweenTapFeedback() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
