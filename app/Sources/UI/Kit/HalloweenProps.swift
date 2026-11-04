// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The small things that dress the app for Halloween: jack-o'-lanterns that sit on the edge of a card or the shelf, cobwebs in the corners with a spider on a thread, a ghost.
// All of it is drawn in code (no pictures), is only a picture (never takes a touch, never read out), and shows only while the Halloween look is on.

private func wave(_ v: Double) -> Double { v - floor(v) }
private func smooth(_ v: Double) -> Double { let x = max(0, min(1, v)); return x * x * (3 - 2 * x) }

var halloweenOn: Bool { ThemeStore.shared.palette.decor == .halloween }

// MARK: Jack-o'-lantern

enum PumpkinFace { case grin, cute, angry, plain }       // plain: uncarved and unlit, the harvest one

/// A glowing jack-o'-lantern: three lobes, a stem with a curl, a carved face that flickers like a candle behind it.
struct HalloweenPumpkin: View {
    var size: CGFloat = 40
    var face: PumpkinFace = .grin
    /// A tap makes it hop and flare (with a small tap of feedback); off where the pumpkin sits over something that has to take the touch.
    var interactive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pokedAt: Double?

    var body: some View {
        let animated = ThemeStore.shared.animatedBackground && !reduceMotion
        let reacting = pokedAt != nil
        let moving = (animated && face != .plain) || reacting
        TimelineView(.animation(minimumInterval: reacting ? 1.0 / 30 : 1.0 / 10, paused: !moving)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let t = moving ? now : 0
            let since = pokedAt.map { now - $0 } ?? 99
            // Two slow waves that never line up, so the light wavers instead of pulsing; a tap makes it flare and fade back.
            let flicker = 0.84 + 0.16 * sin(t * 6.3 + Double(size)) * sin(t * 2.7 + 1.1) + (since < 1.2 ? 0.7 * exp(-since * 3) : 0)
            let hop = since < 0.4 ? sin(.pi * since / 0.4) * 0.14 * Double(size) : 0
            // The canvas is larger than the pumpkin so its glow fades out inside it instead of ending in a square edge; the layout size stays the pumpkin's.
            let pad = size * 0.45
            Canvas { g, _ in
                var c = g
                c.translateBy(x: pad, y: pad)
                Self.draw(&c, CGSize(width: size, height: size * 0.92), face: face, flicker: flicker)
            }
            .frame(width: size + 2 * pad, height: size * 0.92 + 2 * pad)
            .offset(y: -hop)
        }
        .frame(width: size, height: size * 0.92)
        .contentShape(Rectangle())
        .onTapGesture {
            guard interactive else { return }
            pokedAt = Date().timeIntervalSinceReferenceDate
            halloweenTapFeedback()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { pokedAt = nil }
        }
        .allowsHitTesting(interactive)
        .accessibilityHidden(true)
    }

    private static func draw(_ g: inout GraphicsContext, _ sz: CGSize, face: PumpkinFace, flicker: Double) {
        let w = sz.width, h = sz.height
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        // The glow it throws on whatever it sits on (a plain pumpkin has only a faint warmth).
        g.fill(Path(ellipseIn: CGRect(x: -0.25 * w, y: 0.05 * h, width: 1.5 * w, height: 1.3 * h)),
               with: .radialGradient(Gradient(colors: [Color(hex: 0xFF8A1F).opacity((face == .plain ? 0.10 : 0.34) * flicker), .clear]), center: pt(0.5, 0.62), startRadius: 0, endRadius: 0.78 * w))
        // Lobes: the two outer ones sit a little darker and behind the middle one.
        let dark = Color(hex: 0xD2530A), mid = Color(hex: 0xF2750F)
        g.fill(Path(ellipseIn: CGRect(x: 0.03 * w, y: 0.24 * h, width: 0.48 * w, height: 0.74 * h)), with: .color(dark))
        g.fill(Path(ellipseIn: CGRect(x: 0.49 * w, y: 0.24 * h, width: 0.48 * w, height: 0.74 * h)), with: .color(dark))
        let centre = Path(ellipseIn: CGRect(x: 0.2 * w, y: 0.17 * h, width: 0.6 * w, height: 0.81 * h))
        g.fill(centre, with: .radialGradient(Gradient(colors: [Color(hex: 0xFFA23A), mid, Color(hex: 0xDE5E0C)]), center: pt(0.42, 0.4), startRadius: 0, endRadius: 0.6 * w))
        // Ribs.
        for x in [0.2, 0.8] {
            var rib = Path()
            rib.move(to: pt(x, 0.2)); rib.addQuadCurve(to: pt(x, 0.96), control: pt(x + (x < 0.5 ? -0.06 : 0.06), 0.58))
            g.stroke(rib, with: .color(Color(hex: 0xA83D04).opacity(0.7)), lineWidth: max(0.8, 0.018 * w))
        }
        g.fill(Path(ellipseIn: CGRect(x: 0.3 * w, y: 0.26 * h, width: 0.16 * w, height: 0.1 * h)), with: .color(.white.opacity(0.22)))   // a shine
        // Stem and its curl.
        var stem = Path()
        stem.move(to: pt(0.44, 0.22)); stem.addQuadCurve(to: pt(0.5, 0.02), control: pt(0.4, 0.09))
        stem.addLine(to: pt(0.6, 0.04)); stem.addQuadCurve(to: pt(0.57, 0.22), control: pt(0.6, 0.12)); stem.closeSubpath()
        g.fill(stem, with: .color(Color(hex: 0x5E7B2A)))
        g.stroke(stem, with: .color(Color(hex: 0x3B5217)), lineWidth: max(0.6, 0.012 * w))
        guard face != .plain else { return }
        // The carved face, lit from inside: a soft glow under a sharp copy.
        let lit = facePath(face, w: w, h: h)
        let glow = Color(hex: 0xFFD25A)
        g.drawLayer { layer in
            layer.addFilter(.blur(radius: max(1, 0.05 * w)))
            layer.fill(lit, with: .color(glow.opacity(0.9 * flicker)))
        }
        g.fill(lit, with: .color(Color(hex: 0xFFE08A).opacity(0.55 + 0.4 * flicker)))
    }

    private static func facePath(_ face: PumpkinFace, w: Double, h: Double) -> Path {
        func poly(_ pts: [(Double, Double)]) -> Path {
            var p = Path()
            for (i, q) in pts.enumerated() { let c = CGPoint(x: q.0 * w, y: q.1 * h); if i == 0 { p.move(to: c) } else { p.addLine(to: c) } }
            p.closeSubpath(); return p
        }
        var path = Path()
        switch face {
        case .grin:
            path.addPath(poly([(0.27, 0.47), (0.41, 0.47), (0.34, 0.33)]))
            path.addPath(poly([(0.59, 0.47), (0.73, 0.47), (0.66, 0.33)]))
            path.addPath(poly([(0.5, 0.52), (0.45, 0.6), (0.55, 0.6)]))
            path.addPath(poly([(0.24, 0.63), (0.32, 0.70), (0.38, 0.66), (0.44, 0.74), (0.5, 0.68), (0.56, 0.74), (0.62, 0.66), (0.68, 0.70), (0.76, 0.63), (0.70, 0.81), (0.5, 0.88), (0.30, 0.81)]))
        case .cute:
            for x in [0.34, 0.66] { path.addEllipse(in: CGRect(x: (x - 0.065) * w, y: 0.36 * h, width: 0.13 * w, height: 0.17 * h)) }
            path.addPath(poly([(0.5, 0.56), (0.46, 0.62), (0.54, 0.62)]))
            var smile = Path()
            smile.move(to: CGPoint(x: 0.32 * w, y: 0.68 * h))
            smile.addQuadCurve(to: CGPoint(x: 0.68 * w, y: 0.68 * h), control: CGPoint(x: 0.5 * w, y: 0.92 * h))
            smile.addQuadCurve(to: CGPoint(x: 0.32 * w, y: 0.68 * h), control: CGPoint(x: 0.5 * w, y: 0.78 * h))
            path.addPath(smile)
        case .plain:
            break
        case .angry:
            path.addPath(poly([(0.25, 0.36), (0.43, 0.46), (0.27, 0.52)]))
            path.addPath(poly([(0.75, 0.36), (0.57, 0.46), (0.73, 0.52)]))
            path.addPath(poly([(0.5, 0.53), (0.46, 0.62), (0.54, 0.62)]))
            path.addPath(poly([(0.22, 0.68), (0.36, 0.64), (0.42, 0.72), (0.5, 0.64), (0.58, 0.72), (0.64, 0.64), (0.78, 0.68), (0.66, 0.84), (0.5, 0.78), (0.34, 0.84)]))
        }
        return path
    }
}

// MARK: Ghost

/// A small ghost that bobs a little.
struct HalloweenGhost: View {
    var size: CGFloat = 34
    /// A tap: it swells, says "Boo!", fades away upward and drifts back.
    var interactive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pokedAt: Double?

    var body: some View {
        let animated = ThemeStore.shared.animatedBackground && !reduceMotion
        let reacting = pokedAt != nil
        let moving = animated || reacting
        TimelineView(.animation(minimumInterval: 1.0 / (reacting ? 30 : 20), paused: !moving)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let t = moving ? now : 0
            let since = pokedAt.map { now - $0 } ?? 99
            // 0-0.25 s swells, to 1.2 s fades out rising, to 1.9 s fades back in.
            let swell = since < 0.25 ? 1 + 0.35 * smooth(since / 0.25) : 1
            let opacity = since < 0.25 ? 1 : since < 1.2 ? max(0, 1 - (since - 0.25) / 0.5) : since < 1.9 ? (since - 1.2) / 0.7 : 1
            let rise = since < 1.2 ? -Double(size) * 0.5 * smooth((since - 0.25) / 0.95) : 0
            let pad = size * 0.4
            ZStack {
                Canvas { g, _ in
                    var c = g
                    c.translateBy(x: pad, y: pad)
                    Self.draw(&c, CGSize(width: size, height: size * 1.1), t: t)
                }
                .frame(width: size + 2 * pad, height: size * 1.1 + 2 * pad)
                .scaleEffect(swell)
                .opacity(opacity)
                .offset(y: CGFloat(sin(t * 1.6)) * size * 0.06 + rise)
                if since > 0.1, since < 1.0 {
                    Text("Boo!").font(.system(size: size * 0.4, weight: .heavy, design: .rounded)).foregroundStyle(Color(hex: 0xFF8A1F))
                        .shadow(color: Color(hex: 0xFF8A1F).opacity(0.7), radius: 4)
                        .offset(y: -size * 0.75 - rise * 0.2).opacity(since < 0.8 ? 1 : (1.0 - since) / 0.2)
                }
            }
        }
        .frame(width: size, height: size * 1.1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard interactive else { return }
            pokedAt = Date().timeIntervalSinceReferenceDate
            halloweenTapFeedback()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { pokedAt = nil }
        }
        .allowsHitTesting(interactive)
        .accessibilityHidden(true)
    }

    private static func draw(_ g: inout GraphicsContext, _ sz: CGSize, t: Double) {
        let w = sz.width, h = sz.height
        var body = Path()
        body.move(to: CGPoint(x: 0.1 * w, y: 0.95 * h))
        body.addLine(to: CGPoint(x: 0.1 * w, y: 0.42 * h))
        body.addCurve(to: CGPoint(x: 0.9 * w, y: 0.42 * h), control1: CGPoint(x: 0.1 * w, y: -0.12 * h), control2: CGPoint(x: 0.9 * w, y: -0.12 * h))
        body.addLine(to: CGPoint(x: 0.9 * w, y: 0.95 * h))
        // A hem of three waves that sways.
        let sway = 0.03 * sin(t * 2.2)
        for k in 0..<3 {
            let x1 = 0.9 - Double(k) * 0.267, x0 = x1 - 0.267
            body.addQuadCurve(to: CGPoint(x: x0 * w, y: 0.95 * h), control: CGPoint(x: (x0 + x1) / 2 * w + sway * w, y: (k % 2 == 0 ? 1.1 : 0.8) * h))
        }
        body.closeSubpath()
        g.fill(Path(ellipseIn: CGRect(x: -0.2 * w, y: 0.1 * h, width: 1.4 * w, height: 1.2 * h)),
               with: .radialGradient(Gradient(colors: [Color(hex: 0xB9A8FF).opacity(0.25), .clear]), center: CGPoint(x: 0.5 * w, y: 0.55 * h), startRadius: 0, endRadius: 0.7 * w))
        g.fill(body, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.95), Color(hex: 0xD9D2F7).opacity(0.82)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        for x in [0.36, 0.64] { g.fill(Path(ellipseIn: CGRect(x: (x - 0.055) * w, y: 0.36 * h, width: 0.11 * w, height: 0.16 * h)), with: .color(Color(hex: 0x241338))) }
        g.fill(Path(ellipseIn: CGRect(x: 0.44 * w, y: 0.58 * h, width: 0.12 * w, height: 0.12 * h)), with: .color(Color(hex: 0x241338)))
    }
}

// MARK: Cobweb and spider

enum WebCorner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

/// A cobweb across a corner, faint enough to sit behind anything, and optionally a spider lowering itself on a thread and climbing back.
struct HalloweenWeb: View {
    var corner: WebCorner = .topLeading
    var size: CGFloat = 120
    var spider = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = spider && ThemeStore.shared.animatedBackground && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { g, sz in
                // Draw as if the corner were top-left, then flip into place.
                var c = g
                switch corner {
                case .topLeading: break
                case .topTrailing: c.translateBy(x: sz.width, y: 0); c.scaleBy(x: -1, y: 1)
                case .bottomLeading: c.translateBy(x: 0, y: sz.height); c.scaleBy(x: 1, y: -1)
                case .bottomTrailing: c.translateBy(x: sz.width, y: sz.height); c.scaleBy(x: -1, y: -1)
                }
                Self.draw(&c, r: Double(size), spider: spider, t: t)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ g: inout GraphicsContext, r: Double, spider: Bool, t: Double) {
        let strands = 5
        let silk = Color(hex: 0xE6E0FF)
        func point(_ k: Int, _ ring: Double) -> CGPoint {
            let a = Double(k) / Double(strands - 1) * .pi / 2
            return CGPoint(x: cos(a) * r * ring, y: sin(a) * r * ring)
        }
        var lines = Path()
        for k in 0..<strands { lines.move(to: .zero); lines.addLine(to: point(k, 1)) }
        g.stroke(lines, with: .color(silk.opacity(0.22)), lineWidth: 0.8)
        var rings = Path()
        for ring in [0.22, 0.42, 0.62, 0.82] {
            rings.move(to: point(0, ring))
            for k in 1..<strands {
                let a = point(k - 1, ring), b = point(k, ring)
                let mid = CGPoint(x: (a.x + b.x) / 2 * 0.86, y: (a.y + b.y) / 2 * 0.86)      // each span sags toward the corner
                rings.addQuadCurve(to: b, control: mid)
            }
        }
        g.stroke(rings, with: .color(silk.opacity(0.17)), lineWidth: 0.7)
        guard spider else { return }
        // The spider: down the thread and up again, slowly.
        let x = r * 0.3          // near the screen's edge, so it hangs beside the logo and not behind it
        let drop = r * (0.34 + 0.17 * sin(t * 0.45))
        var thread = Path(); thread.move(to: CGPoint(x: x, y: 0)); thread.addLine(to: CGPoint(x: x, y: drop))
        g.stroke(thread, with: .color(silk.opacity(0.35)), lineWidth: 0.7)
        let s = r * 0.045
        let ink = Color(hex: 0x120A1C)
        var legs = Path()
        for side in [1.0, -1.0] {
            for k in 0..<4 {
                let spreadY = (Double(k) - 1.5) * s * 0.55
                let knee = CGPoint(x: x + side * s * 1.5, y: drop + spreadY - s * 0.8 + sin(t * 3 + Double(k)) * s * 0.12)
                let foot = CGPoint(x: x + side * s * 2.5, y: drop + spreadY + s * 0.5)
                legs.move(to: CGPoint(x: x, y: drop + spreadY * 0.3)); legs.addLine(to: knee); legs.addLine(to: foot)
            }
        }
        g.stroke(legs, with: .color(ink), lineWidth: max(0.7, s * 0.28))
        g.fill(Path(ellipseIn: CGRect(x: x - s, y: drop - s * 0.8, width: s * 2, height: s * 1.7)), with: .color(ink))
        g.fill(Path(ellipseIn: CGRect(x: x - s * 0.6, y: drop - s * 1.5, width: s * 1.2, height: s * 1.0)), with: .color(ink))
        g.fill(Path(ellipseIn: CGRect(x: x - s * 0.3, y: drop - s * 1.2, width: s * 0.25, height: s * 0.25)), with: .color(Color(hex: 0xFF4B2B)))
        g.fill(Path(ellipseIn: CGRect(x: x + s * 0.05, y: drop - s * 1.2, width: s * 0.25, height: s * 0.25)), with: .color(Color(hex: 0xFF4B2B)))
    }
}

// MARK: A patch for the end of a shelf

/// A couple of pumpkins and a ghost: it fills the empty space at the end of the games shelf. `height` is the height of the tiles beside it.
struct HalloweenPatch: View {
    var height: CGFloat

    var body: some View {
        if halloweenOn {
            ZStack(alignment: .bottomLeading) {
                HalloweenPumpkin(size: height * 0.95, face: .grin, interactive: true).offset(x: 0, y: 0)
                HalloweenPumpkin(size: height * 0.58, face: .cute, interactive: true).rotationEffect(.degrees(8)).offset(x: height * 0.88, y: 0)
                HalloweenGhost(size: height * 0.42, interactive: true).offset(x: height * 0.62, y: -height * 0.66)
            }
            .frame(width: height * 1.5, height: height, alignment: .bottomLeading)
            .padding(.trailing, 6)
        }
    }
}

// MARK: Placing them

private struct HalloweenSitter: ViewModifier {
    let alignment: Alignment, size: CGFloat, dx: CGFloat, dy: CGFloat, tilt: Double, face: PumpkinFace, enabled: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if enabled, halloweenOn {
                HalloweenPumpkin(size: size, face: face).rotationEffect(.degrees(tilt)).offset(x: dx, y: dy).allowsHitTesting(false)
            }
        }
    }
}

private struct HalloweenCorner: ViewModifier {
    let corner: WebCorner, size: CGFloat, spider: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if halloweenOn { HalloweenWeb(corner: corner, size: size, spider: spider) }
        }
    }
    private var alignment: Alignment {
        switch corner { case .topLeading: .topLeading; case .topTrailing: .topTrailing; case .bottomLeading: .bottomLeading; case .bottomTrailing: .bottomTrailing }
    }
}

extension View {
    /// A jack-o'-lantern sitting on this view's edge while the Halloween look is on. `dx`/`dy` move it from the corner it sits in (negative `dy` is up, so half of it is outside).
    func halloweenSitter(_ alignment: Alignment = .topTrailing, size: CGFloat = 34, dx: CGFloat = -14, dy: CGFloat = -16, tilt: Double = 6, face: PumpkinFace = .grin, enabled: Bool = true) -> some View {
        modifier(HalloweenSitter(alignment: alignment, size: size, dx: dx, dy: dy, tilt: tilt, face: face, enabled: enabled))
    }
    /// A cobweb across one corner of this view while the Halloween look is on.
    func halloweenWeb(_ corner: WebCorner, size: CGFloat = 90, spider: Bool = false) -> some View {
        modifier(HalloweenCorner(corner: corner, size: size, spider: spider))
    }
}
