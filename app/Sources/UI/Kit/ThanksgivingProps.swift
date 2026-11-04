// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Thanksgiving: leaves falling behind the screens, a harvest moon and drifting gold dust in the backdrop, and small things that sit about the app: a turkey in a pilgrim hat, plain
// pumpkins, acorns, a leaf hanging on a thread, leaf piles in the corners. All drawn in code, only pictures (no touches, not read out), and shown only while the Thanksgiving look is on.

private func fraction(_ v: Double) -> Double { v - floor(v) }

private var thanksgivingOn: Bool { ThemeStore.shared.palette.decor == .thanksgiving }

/// The colours of the leaves, from rust to gold.
private enum Autumn {
    static let leaves: [UInt32] = [0xC4452D, 0xE0662A, 0xF0A030, 0xD9902F, 0x9C3A22, 0xB8601F]
}

// MARK: The leaf

enum MapleLeaf {
    /// A maple leaf in its own units (about -1...1 each way, tip up, stem down): the right half as points, mirrored for the left.
    private static let half: [(Double, Double)] = [
        (0, -1.0), (0.16, -0.66), (0.34, -0.74), (0.30, -0.40), (0.62, -0.52), (0.56, -0.26),
        (0.92, -0.18), (0.66, 0.08), (0.74, 0.30), (0.38, 0.28), (0.12, 0.58), (0.10, 0.95),
    ]

    static func path() -> Path {
        var p = Path()
        let right = half.dropFirst()
        p.move(to: CGPoint(x: 0, y: -1.0))
        for q in right { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.addLine(to: CGPoint(x: 0, y: 1.02))
        for q in right.reversed() { p.addLine(to: CGPoint(x: -q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }

    /// The veins and the stem, in the same units.
    static func veins() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -0.9)); p.addLine(to: CGPoint(x: 0, y: 1.25))             // the middle vein and the stem
        for side in [1.0, -1.0] {
            p.move(to: CGPoint(x: 0, y: 0.1)); p.addLine(to: CGPoint(x: 0.62 * side, y: -0.16))
            p.move(to: CGPoint(x: 0, y: -0.2)); p.addLine(to: CGPoint(x: 0.38 * side, y: -0.54))
        }
        return p
    }

    /// One leaf drawn at the origin at `size` units, in a colour, as if seen at an angle (`flip` squeezes its width).
    static func draw(_ g: inout GraphicsContext, size: Double, color: UInt32, flip: Double = 1, alpha: Double = 1) {
        var c = g
        c.scaleBy(x: size * flip, y: size)
        let body = path()
        c.fill(body, with: .color(Color(hex: color).opacity(alpha)))
        c.stroke(body, with: .color(Color(hex: 0x3B1A0C).opacity(0.35 * alpha)), lineWidth: 0.05)
        c.stroke(veins(), with: .color(Color(hex: 0xFFE2A0).opacity(0.38 * alpha)), lineWidth: 0.07)
    }
}

// MARK: Falling leaves

/// Leaves drifting down behind the screens: each sways, turns and tips over as it falls (its width squeezes and opens like a leaf seen edge-on). Behind every word, in front of the
/// backdrop, the way the Halloween bats are.
struct LeavesLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Leaf { let x: Double, size: Double, depth: Double, period: Double, phase: Double, sway: Double, swayRate: Double, turn: Double, spin: Double, flipRate: Double, color: UInt32 }
    private static let leaves: [Leaf] = (0..<14).map { i in
        func r(_ k: Int) -> Double { BatFlight.random(i, 0, 40 + k) }
        let depth = 0.45 + 0.55 * r(1)
        return Leaf(x: r(0), size: 0.020 + 0.022 * depth, depth: depth, period: 24 + 22 * (1.2 - depth) + 8 * r(2), phase: r(3), sway: 0.03 + 0.05 * r(4), swayRate: 0.5 + 0.6 * r(5),
                    turn: 0.5 + 0.5 * r(6), spin: (r(7) - 0.5) * 0.5, flipRate: 0.8 + 1.2 * r(8), color: Autumn.leaves[Int(r(9) * Double(Autumn.leaves.count)) % Autumn.leaves.count])
    }

    var body: some View {
        let theme = ThemeStore.shared
        let alive = theme.palette.decor == .thanksgiving && theme.animatedBackground && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !alive)) { context in
            Canvas { ctx, size in
                guard alive else { return }
                let t = context.date.timeIntervalSinceReferenceDate
                let w = size.width, h = size.height, unit = min(w, h)
                for (i, leaf) in Self.leaves.enumerated() {
                    let progress = fraction(t / leaf.period + leaf.phase)
                    let x = w * leaf.x + w * leaf.sway * sin(t * leaf.swayRate + Double(i)) + w * 0.06 * progress
                    let y = h * (-0.08 + 1.2 * progress)
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(leaf.turn * sin(t * leaf.swayRate * 0.9 + Double(i) * 2) + t * leaf.spin))
                    let flip = 0.35 + 0.65 * abs(cos(t * leaf.flipRate + Double(i)))
                    MapleLeaf.draw(&c, size: unit * leaf.size, color: leaf.color, flip: flip, alpha: 0.5 + 0.45 * leaf.depth)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}

// MARK: Backdrop

/// A low harvest moon, a warm glow along the bottom and gold dust drifting up, behind everything.
struct HarvestDecor: View {
    let time: Double
    let moving: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let moon = CGPoint(x: w * 0.88, y: h * 0.62), r = min(w, h) * 0.06
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - r * 3.6, y: moon.y - r * 3.6, width: r * 7.2, height: r * 7.2)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xFFB04A).opacity(0.26), .clear]), center: moon, startRadius: r * 0.5, endRadius: r * 3.6))
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - r, y: moon.y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: 0xFFC46B).opacity(0.9)))
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - r * 0.4, y: moon.y - r * 0.5, width: r * 0.5, height: r * 0.45)), with: .color(Color(hex: 0xE8A04A).opacity(0.5)))
            // Gold dust.
            for i in 0..<22 {
                let seed = Double(i) * 17.31
                let speed = 0.006 + 0.010 * fraction(sin(seed) * 43758.5453)
                let phase = fraction(sin(seed * 1.7) * 91423.7)
                let t = moving ? time : 0
                let y = h * (1.05 - fraction(phase + t * speed) * 1.15)
                let x = w * (fraction(sin(seed * 3.1) * 12345.6) + 0.03 * sin(t * 0.5 + seed))
                let twinkle = 0.5 + 0.5 * sin(t * (1.0 + fraction(seed)) + seed)
                let s = 1.2 + 2.0 * fraction(sin(seed * 5.3) * 777.7)
                ctx.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s, width: s * 2, height: s * 2)), with: .color(Color(hex: 0xFFD27A).opacity(0.42 * twinkle)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Turkey

/// A cartoon turkey with a fan of feathers and a small pilgrim hat; it rocks gently from side to side.
struct HarvestTurkey: View {
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = ThemeStore.shared.animatedBackground && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            let pad = size * 0.2
            Canvas { g, _ in
                var c = g
                c.translateBy(x: pad, y: pad)
                Self.draw(&c, CGSize(width: size, height: size))
            }
            .frame(width: size + 2 * pad, height: size + 2 * pad)
            .rotationEffect(.degrees(3 * sin(t * 1.3)), anchor: .bottom)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ g: inout GraphicsContext, _ sz: CGSize) {
        let w = sz.width, h = sz.height
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        // The tail: a fan of seven feathers, each a long rounded bar in its own colour with a lighter stripe.
        let colors: [UInt32] = [0x9C3A22, 0xC4452D, 0xE0662A, 0xF0A030, 0xE0662A, 0xC4452D, 0x9C3A22]
        for (k, color) in colors.enumerated() {
            var c = g
            c.translateBy(x: 0.5 * w, y: 0.58 * h)
            c.rotate(by: .radians(Double(k - 3) * 0.37))
            let feather = Path(roundedRect: CGRect(x: -0.085 * w, y: -0.56 * h, width: 0.17 * w, height: 0.44 * h), cornerRadius: 0.085 * w)
            c.fill(feather, with: .color(Color(hex: color)))
            c.stroke(feather, with: .color(Color(hex: 0x3B1A0C).opacity(0.35)), lineWidth: max(0.6, 0.012 * w))
            c.fill(Path(roundedRect: CGRect(x: -0.025 * w, y: -0.52 * h, width: 0.05 * w, height: 0.3 * h), cornerRadius: 0.025 * w), with: .color(Color(hex: 0xFFE2A0).opacity(0.4)))
        }
        // Feet.
        var feet = Path()
        for x in [0.4, 0.6] {
            feet.move(to: pt(x, 0.84)); feet.addLine(to: pt(x, 0.95))
            feet.move(to: pt(x - 0.05, 0.97)); feet.addLine(to: pt(x, 0.93)); feet.addLine(to: pt(x + 0.05, 0.97))
        }
        g.stroke(feet, with: .color(Color(hex: 0xF0A030)), lineWidth: max(1, 0.03 * w))
        // Body, with a lighter belly.
        g.fill(Path(ellipseIn: CGRect(x: 0.25 * w, y: 0.42 * h, width: 0.5 * w, height: 0.46 * h)), with: .color(Color(hex: 0x9A5B34)))
        g.fill(Path(ellipseIn: CGRect(x: 0.33 * w, y: 0.55 * h, width: 0.34 * w, height: 0.3 * h)), with: .color(Color(hex: 0xC98B58)))
        // Head, beak, wattle, eyes.
        g.fill(Path(ellipseIn: CGRect(x: 0.4 * w, y: 0.27 * h, width: 0.2 * w, height: 0.2 * h)), with: .color(Color(hex: 0xA9643A)))
        var beak = Path(); beak.move(to: pt(0.46, 0.38)); beak.addLine(to: pt(0.54, 0.38)); beak.addLine(to: pt(0.5, 0.46)); beak.closeSubpath()
        g.fill(beak, with: .color(Color(hex: 0xF2B632)))
        g.fill(Path(ellipseIn: CGRect(x: 0.475 * w, y: 0.43 * h, width: 0.05 * w, height: 0.1 * h)), with: .color(Color(hex: 0xD23B2E)))
        for x in [0.455, 0.545] {
            g.fill(Path(ellipseIn: CGRect(x: (x - 0.022) * w, y: 0.325 * h, width: 0.044 * w, height: 0.05 * h)), with: .color(.white))
            g.fill(Path(ellipseIn: CGRect(x: (x - 0.01) * w, y: 0.335 * h, width: 0.022 * w, height: 0.03 * h)), with: .color(Color(hex: 0x1B0F0A)))
        }
        // The pilgrim hat: a black crown, a brim and a gold buckle.
        g.fill(Path(roundedRect: CGRect(x: 0.42 * w, y: 0.12 * h, width: 0.16 * w, height: 0.17 * h), cornerRadius: 0.012 * w), with: .color(Color(hex: 0x1F1612)))
        g.fill(Path(roundedRect: CGRect(x: 0.36 * w, y: 0.27 * h, width: 0.28 * w, height: 0.04 * h), cornerRadius: 0.02 * w), with: .color(Color(hex: 0x1F1612)))
        g.fill(Path(roundedRect: CGRect(x: 0.42 * w, y: 0.235 * h, width: 0.16 * w, height: 0.03 * h), cornerRadius: 0.004 * w), with: .color(Color(hex: 0x8A5A2B)))
        g.fill(Path(roundedRect: CGRect(x: 0.475 * w, y: 0.225 * h, width: 0.05 * w, height: 0.05 * h), cornerRadius: 0.006 * w), with: .color(Color(hex: 0xF2B632)))
    }
}

// MARK: Acorn

struct HarvestAcorn: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { g, _ in
            var c = g
            let pad = size * 0.2
            c.translateBy(x: pad, y: pad)
            let w = Double(size), h = Double(size)
            c.fill(Path(ellipseIn: CGRect(x: 0.24 * w, y: 0.3 * h, width: 0.52 * w, height: 0.66 * h)), with: .color(Color(hex: 0xC98A4B)))
            c.fill(Path(ellipseIn: CGRect(x: 0.32 * w, y: 0.44 * h, width: 0.12 * w, height: 0.3 * h)), with: .color(.white.opacity(0.22)))
            c.fill(Path(ellipseIn: CGRect(x: 0.14 * w, y: 0.18 * h, width: 0.72 * w, height: 0.42 * h)), with: .color(Color(hex: 0x7B4A24)))
            for k in 0..<5 { c.fill(Path(ellipseIn: CGRect(x: (0.24 + Double(k) * 0.12) * w, y: (0.3 + 0.05 * Double(k % 2)) * h, width: 0.05 * w, height: 0.05 * h)), with: .color(Color(hex: 0x4F2E14).opacity(0.7))) }
            c.fill(Path(roundedRect: CGRect(x: 0.46 * w, y: 0.04 * h, width: 0.08 * w, height: 0.18 * h), cornerRadius: 0.03 * w), with: .color(Color(hex: 0x5A3418)))
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: A patch for the end of a shelf

/// A plain pumpkin, a smaller one, and a small turkey on top: it fills the empty space at the end of the games shelf. `height` is the height of the tiles beside it.
struct HarvestPatch: View {
    var height: CGFloat

    var body: some View {
        if thanksgivingOn {
            ZStack(alignment: .bottomLeading) {
                HalloweenPumpkin(size: height * 0.95, face: .plain)
                HalloweenPumpkin(size: height * 0.58, face: .plain).rotationEffect(.degrees(8)).offset(x: height * 0.88, y: 0)
                HarvestAcorn(size: height * 0.26).offset(x: height * 0.58, y: -height * 0.02)
                HarvestTurkey(size: height * 0.5).offset(x: height * 0.88, y: -height * 0.5)
            }
            .frame(width: height * 1.5, height: height, alignment: .bottomLeading)
            .padding(.trailing, 6)
        }
    }
}

// MARK: Corners

/// A heap of leaves in a corner, and in the top corner a leaf that hangs from a thread and sways.
struct HarvestCorner: View {
    var corner: WebCorner = .bottomLeading
    var size: CGFloat = 120
    var hanging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = hanging && ThemeStore.shared.animatedBackground && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { g, sz in
                var c = g
                switch corner {            // drawn as if the corner were top-left, then flipped into place
                case .topLeading: break
                case .topTrailing: c.translateBy(x: sz.width, y: 0); c.scaleBy(x: -1, y: 1)
                case .bottomLeading: c.translateBy(x: 0, y: sz.height); c.scaleBy(x: 1, y: -1)
                case .bottomTrailing: c.translateBy(x: sz.width, y: sz.height); c.scaleBy(x: -1, y: -1)
                }
                Self.draw(&c, r: Double(size), hanging: hanging, t: t)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ g: inout GraphicsContext, r: Double, hanging: Bool, t: Double) {
        if hanging {
            // A leaf on a thread from the top edge, swinging like a pendulum.
            let anchor = CGPoint(x: r * 0.3, y: 0), length = r * 0.42
            let swing = 0.22 * sin(t * 1.1)
            let end = CGPoint(x: anchor.x + sin(swing) * length, y: anchor.y + cos(swing) * length)
            var thread = Path(); thread.move(to: anchor); thread.addLine(to: end)
            g.stroke(thread, with: .color(Color(hex: 0xE6D2B0).opacity(0.4)), lineWidth: 0.8)
            var c = g
            c.translateBy(x: end.x, y: end.y + r * 0.05)
            c.rotate(by: .radians(swing + .pi))          // hangs by its stem
            MapleLeaf.draw(&c, size: r * 0.1, color: 0xE0662A, flip: 0.9)
            return
        }
        // The heap: leaves fanned over each other around the corner, the darker ones underneath.
        let heap: [(x: Double, y: Double, a: Double, s: Double, c: UInt32)] = [
            (0.06, 0.20, 0.7, 0.13, 0x9C3A22), (0.20, 0.11, -0.5, 0.12, 0xB8601F), (0.30, 0.22, 1.9, 0.11, 0xC4452D),
            (0.12, 0.34, 2.6, 0.12, 0xD9902F), (0.26, 0.05, 0.2, 0.10, 0xE0662A), (0.38, 0.12, -1.2, 0.09, 0xF0A030),
        ]
        for l in heap {
            var c = g
            c.translateBy(x: l.x * r, y: l.y * r)
            c.rotate(by: .radians(l.a))
            MapleLeaf.draw(&c, size: l.s * r, color: l.c, alpha: 0.85)
        }
    }
}
