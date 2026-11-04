// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

/// A holiday the app dresses up for: a colour scheme of its own and a light decoration drifting behind every screen. The app picks it by the date, from a week before the day to two days after it (Settings > Theme and colours >
/// Festive themes turns that off), so nobody has to remember to change anything, and a person's own colours come back when the holiday ends.
enum Season: String, CaseIterable, Identifiable {
    case halloween, thanksgiving

    var id: String { rawValue }
    var title: String { switch self { case .halloween: "Halloween"; case .thanksgiving: "Thanksgiving" } }
    var symbol: String { switch self { case .halloween: "moon.stars.fill"; case .thanksgiving: "leaf.fill" } }

    /// The day itself in a year: 31 October, and the fourth Thursday of November (the United States' Thanksgiving).
    func day(in year: Int, calendar: Calendar = .current) -> Date? {
        switch self {
        case .halloween: return calendar.date(from: DateComponents(year: year, month: 10, day: 31))
        case .thanksgiving: return calendar.date(from: DateComponents(year: year, month: 11, weekday: 5, weekdayOrdinal: 4))
        }
    }

    /// Every holiday is on from a week before it to two days after it (Halloween: 24 October to 2 November).
    static let daysBefore = 7
    static let daysAfter = 2

    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let day = day(in: calendar.component(.year, from: date), calendar: calendar) else { return false }
        let apart = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: date)).day ?? Int.max
        return apart >= -Self.daysBefore && apart <= Self.daysAfter
    }

    static func active(on date: Date = Date()) -> Season? { allCases.first { $0.isActive(on: date) } }

    var palette: Palette {
        switch self {
        // Pumpkin orange over a purple-black night, with a witchy violet as the second light.
        case .halloween: return Palette(id: "halloween", name: "Halloween", bgTop: 0x211033, bgBottom: 0x0B0613, accent: 0xFF7A1A, accent2: 0x9B5CFF, decor: .halloween)
        // A warm harvest: deep brown, harvest gold, and the rust of a cranberry for the second light.
        case .thanksgiving: return Palette(id: "thanksgiving", name: "Thanksgiving", bgTop: 0x2B170B, bgBottom: 0x120A06, accent: 0xF0A030, accent2: 0xC4452D, decor: .thanksgiving)
        }
    }
}

/// What drifts behind the screens of a scheme.
enum Decor: Equatable {
    case none, halloween, thanksgiving
}

/// The decoration of the current scheme that stays behind the screens: embers rising and a pale moon in the corner. Drawn with one Canvas a dozen times a second, and still
/// (embers frozen) when motion is off. (The bats are `BatsLayer`, which flies behind the text.)
struct SeasonalDecor: View {
    let decor: Decor
    let time: Double
    let moving: Bool

    var body: some View {
        switch decor {
        case .none: EmptyView()
        case .halloween: HalloweenDecor(time: time, moving: moving)
        case .thanksgiving: HarvestDecor(time: time, moving: moving)
        }
    }
}

private struct HalloweenDecor: View {
    let time: Double
    let moving: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // The moon: a soft pale glow and a disc, top right.
            let moon = CGPoint(x: w * 0.9, y: h * 0.3), r = min(w, h) * 0.05
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - r * 3.2, y: moon.y - r * 3.2, width: r * 6.4, height: r * 6.4)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xFFE9B0).opacity(0.22), .clear]), center: moon, startRadius: r * 0.4, endRadius: r * 3.2))
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - r, y: moon.y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: 0xFFF1C9).opacity(0.85)))
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - r * 0.35, y: moon.y - r * 0.55, width: r * 0.5, height: r * 0.5)), with: .color(Color(hex: 0xE9D3A0).opacity(0.5)))
            // Low mist: a few soft pale bands drifting slowly along the bottom of the screen.
            for k in 0..<3 {
                let t = moving ? time : 0
                let cx = w * (frac(t * 0.006 + Double(k) * 0.37) * 1.5 - 0.25)
                let cy = h * (0.9 + 0.03 * sin(t * 0.17 + Double(k) * 2))
                let radius = w * 0.5
                var c = ctx
                c.translateBy(x: cx, y: cy)
                c.scaleBy(x: 1, y: h * 0.13 / radius)
                c.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                       with: .radialGradient(Gradient(colors: [Color(hex: 0xCDB8FF).opacity(0.08), .clear]), center: .zero, startRadius: 0, endRadius: radius))
            }
            // Embers: each one rises on its own loop and flickers.
            for i in 0..<26 {
                let seed = Double(i) * 12.9898
                let speed = 0.012 + 0.016 * frac(sin(seed) * 43758.5453)
                let phase = frac(sin(seed * 1.7) * 91423.7)
                let t = moving ? time : 0
                let y = h * (1.05 - frac(phase + t * speed) * 1.15)
                let x = w * (frac(sin(seed * 3.1) * 12345.6) + 0.025 * sin(t * 0.7 + seed))
                let flicker = 0.55 + 0.45 * sin(t * (1.5 + frac(seed)) + seed)
                let s = 1.6 + 2.6 * frac(sin(seed * 5.3) * 777.7)
                ctx.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s, width: s * 2, height: s * 2)), with: .color(Color(hex: i % 3 == 0 ? 0xFFB347 : 0xFF7A1A).opacity(0.5 * flicker)))
            }
        }
        .allowsHitTesting(false)
    }
}

private func frac(_ v: Double) -> Double { v - floor(v) }

/// Where the bats are drawn. They fly in the backdrop, BEHIND every screen's text and panels (the panels are nearly clear, so a bat shows through a card and never covers
/// a word). Home has a picture behind its page that would hide them, so Home draws them itself, above that picture, and the backdrop leaves them out meanwhile.
@Observable
final class BatsPlacement {
    nonisolated(unsafe) static let shared = BatsPlacement()
    var homeDrawsThem = false
}

/// A few bats crossing the screen one at a time, wings folding as they flap. Touches pass straight through (it is only a picture). It keeps moving while a list is scrolled.
struct BatsLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ThemeStore.shared
        let alive = theme.palette.decor == .halloween && theme.animatedBackground && !reduceMotion
        let night = HalloweenNight.isTonight
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !alive)) { context in
            Canvas { ctx, size in
                guard alive else { return }
                let t = context.date.timeIntervalSinceReferenceDate
                HalloweenEyes.draw(&ctx, size: size, time: t, night: night)          // furthest back: out of the dark
                BatFlight.draw(&ctx, size: size, time: t)
                HalloweenWitch.draw(&ctx, size: size, time: t, night: night)         // and now and then a witch across the moon
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}

/// The flight paths and the bat itself. Everything is a function of the time, so nothing is stored. Three bats are always on their way across, one after another, and two more come and go
/// on a longer round of their own, so there are three to five on screen (measured over a long run: three about a quarter of the time, four half, five a fifth). Each crossing is its own random one (a hash of which bat and which round): where it comes in, whether it
/// drifts up or down on the way, which way it flies, how big and how far away it is. The pace stays calm and even.
enum BatFlight {
    struct Slot {
        var period: Double        // seconds between the starts of one crossing and the next
        var offset: Double
        var minDuration: Double   // a crossing lasts this long to this long, drawn anew each round
        var maxDuration: Double
    }

    static let slots: [Slot] = [
        Slot(period: 17, offset: 0,   minDuration: 17.6, maxDuration: 18.6),     // these three are always crossing (a new one comes in as the last leaves)
        Slot(period: 17, offset: 5.7, minDuration: 17.6, maxDuration: 18.6),
        Slot(period: 17, offset: 11.3, minDuration: 17.6, maxDuration: 18.6),
        Slot(period: 29, offset: 4,   minDuration: 16, maxDuration: 22),          // and these two come and go on rounds of their own, of different lengths,
        Slot(period: 47, offset: 17,  minDuration: 16, maxDuration: 22),          // so they drift in and out of step: about a quarter of the time three, half four, a fifth five
    ]

    /// A number from 0 to 1 that is always the same for the same three numbers, and looks random.
    static func random(_ a: Int, _ b: Int, _ c: Int) -> Double { frac(sin(Double(a) * 127.1 + Double(b) * 311.7 + Double(c) * 74.7) * 43758.5453) }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width, h = size.height, unit = min(w, h)
        for (i, slot) in slots.enumerated() {
            let phase = t + slot.offset
            let round = Int(floor(phase / slot.period))
            for r in [round, round - 1] {              // the one before may still be on its way out
                let local = phase - Double(r) * slot.period
                let duration = slot.minDuration + (slot.maxDuration - slot.minDuration) * random(i, r, 1)
                guard local >= 0, local < duration else { continue }
                crossing(&ctx, slot: i, round: r, progress: local / duration, w: w, h: h, unit: unit, t: t)
            }
        }
    }

    private static func crossing(_ ctx: inout GraphicsContext, slot i: Int, round r: Int, progress: Double, w: Double, h: Double, unit: Double, t: Double) {
        func rnd(_ k: Int) -> Double { random(i, r, k) }
        let leftward = rnd(2) < 0.5
        let lane0 = 0.08 + 0.78 * rnd(3)
        let lane1 = max(0.06, min(0.92, lane0 + (rnd(4) - 0.5) * 0.4))          // drifts up or down on the way across
        let kind = rnd(5)
        let (scale, depth, eyes) = kind < 0.35 ? (0.050, 1.0, true) : kind < 0.75 ? (0.036, 0.75, false) : (0.026, 0.5, false)
        let flapRate = 6 + 3 * rnd(6)                                            // about one beat a second
        let weave = rnd(7) * 6.28
        let x = leftward ? w * (1.1 - progress * 1.2) : w * (-0.1 + progress * 1.2)
        let s = unit * scale
        let phase = t * flapRate + weave
        // The body rises a little as the wings come down and sinks as they come up, which is most of what makes a flap look like a flap.
        let bob = cos(phase) * s * 0.22
        let y = h * (lane0 + (lane1 - lane0) * progress) + h * 0.025 * sin(t * 0.6 + weave) + bob
        var c = ctx
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians((leftward ? -0.07 : 0.07) + 0.03 * sin(t * 0.8 + weave)))     // a slight lean into the way it is going
        c.scaleBy(x: s, y: s)
        drawBat(&c, flap: 0.85 * sin(phase), depth: depth, eyes: eyes, unit: s)
    }

    /// One bat in its own units (the wing span is about 4.4). The wing is an arm that swings from the shoulder, three fingers fanned off the wrist and a membrane scalloped between
    /// their tips; the fingers trail behind the arm, which is what makes it look like it flaps rather than slides.
    /// `fold` 0 is wings spread, 1 is wings folded against the body (a bat hanging from a ledge).
    static func drawBat(_ g: inout GraphicsContext, flap openFlap: Double, depth: Double, eyes: Bool, unit: Double, fold: Double = 0) {
        let flap = openFlap + (-1.0 - openFlap) * fold
        let body = Color(hex: 0x0D0716).opacity(0.94 * depth)
        let rim = Color(hex: 0xB57BFF).opacity(0.42 * depth)
        let halo = Color(hex: 0x9B5CFF).opacity(0.10 * depth)
        let hair = 1.1 / unit

        for side in [1.0, -1.0] {
            let shoulder = CGPoint(x: 0.14 * side, y: -0.12)
            let alpha = -(0.30 + 0.62 * flap)
            let wrist = CGPoint(x: shoulder.x + side * 0.95 * cos(alpha), y: shoulder.y + 0.95 * sin(alpha))
            let lag = 0.40 * flap
            let lengths = [1.20, 1.05, 0.80], spread = [-0.10, 0.38, 0.80]
            let tips: [CGPoint] = (0..<3).map { k in
                let a = alpha + spread[k] + lag
                return CGPoint(x: wrist.x + side * lengths[k] * cos(a), y: wrist.y + lengths[k] * sin(a))
            }
            let hip = CGPoint(x: 0.11 * side, y: 0.42)
            func scallop(_ a: CGPoint, _ b: CGPoint, pull: Double) -> CGPoint {
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                return CGPoint(x: m.x + (wrist.x - m.x) * pull, y: m.y + (wrist.y - m.y) * pull)
            }
            var wing = Path()
            wing.move(to: shoulder)
            wing.addLine(to: wrist)
            wing.addLine(to: tips[0])
            wing.addQuadCurve(to: tips[1], control: scallop(tips[0], tips[1], pull: 0.30))
            wing.addQuadCurve(to: tips[2], control: scallop(tips[1], tips[2], pull: 0.30))
            wing.addQuadCurve(to: hip, control: scallop(tips[2], hip, pull: 0.22))
            wing.closeSubpath()
            var wg = g
            wg.scaleBy(x: 1 - 0.8 * fold, y: 1)
            if fold < 0.5 { wg.stroke(wing, with: .color(halo), lineWidth: 5 / unit) }
            wg.fill(wing, with: .color(body))
            wg.stroke(wing, with: .color(rim), lineWidth: hair)
        }
        // Body, head and two pointed ears.
        let torso = Path(ellipseIn: CGRect(x: -0.2, y: -0.38, width: 0.4, height: 1.0))
        let head = Path(ellipseIn: CGRect(x: -0.2, y: -0.7, width: 0.4, height: 0.4))
        var ears = Path()
        for side in [1.0, -1.0] {
            ears.move(to: CGPoint(x: 0.17 * side, y: -0.52))
            ears.addLine(to: CGPoint(x: 0.14 * side, y: -1.02))
            ears.addLine(to: CGPoint(x: 0.02 * side, y: -0.66))
            ears.closeSubpath()
        }
        for part in [torso, head, ears] {
            g.fill(part, with: .color(body))
            g.stroke(part, with: .color(rim), lineWidth: hair)
        }
        if eyes {
            for side in [1.0, -1.0] {
                let eye = CGRect(x: 0.075 * side - 0.035, y: -0.55 - 0.035, width: 0.07, height: 0.07)
                g.fill(Path(ellipseIn: eye.insetBy(dx: -0.05, dy: -0.05)), with: .color(Color(hex: 0xFF5A1F).opacity(0.25 * depth)))
                g.fill(Path(ellipseIn: eye), with: .color(Color(hex: 0xFFB347).opacity(0.95 * depth)))
            }
        }
    }
}
