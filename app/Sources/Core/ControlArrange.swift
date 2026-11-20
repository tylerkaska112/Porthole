// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// What the controls editor does to several controls at once: move them together, line them up, space them evenly, flip them, scale them and size them alike. Pure
/// maths on a layout's controls (positions are fractions of the screen, sizes are points), so it is tested without a screen. Every function takes the controls and
/// the ids it applies to and returns the controls with those changed (same order); the rest are returned as they were.
enum ControlArrange {
    enum Edge { case left, centreX, right, top, centreY, bottom }
    enum Axis { case across, down }

    /// Where a control's centre may be: the same limits dragging uses, so nothing ends up off the screen.
    static let xRange = 0.02...0.98, yRange = 0.04...0.96

    /// How big a control is drawn, in points: round and square controls are `size` each way; the spot for an overlay is a chip, `size` wide and a little over a third as tall.
    /// `scale` is the button size setting (TouchButtonSize): the controls are drawn that much bigger than their stored size; an overlay's spot is not a button and stays as it is.
    static func extent(_ s: TouchControlSpec, scale: Double = 1) -> CGSize {
        s.isOverlay ? CGSize(width: s.size, height: max(34, s.size * 0.42)) : CGSize(width: s.size * scale, height: s.size * scale)
    }

    static func frame(_ s: TouchControlSpec, in field: CGSize, scale: Double = 1) -> CGRect {
        let e = extent(s, scale: scale), c = CGPoint(x: s.x * Double(field.width), y: s.y * Double(field.height))
        return CGRect(x: c.x - e.width / 2, y: c.y - e.height / 2, width: e.width, height: e.height)
    }

    /// The rectangle round the chosen controls, in points (nil: none chosen).
    static func bounds(_ specs: [TouchControlSpec], ids: Set<UUID>, in field: CGSize, scale: Double = 1) -> CGRect? {
        let frames = specs.filter { ids.contains($0.id) }.map { frame($0, in: field, scale: scale) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func clamp(_ s: inout TouchControlSpec) {
        s.x = min(max(s.x, xRange.lowerBound), xRange.upperBound); s.y = min(max(s.y, yRange.lowerBound), yRange.upperBound)
    }

    /// Lines the controls up on one edge or one centre line of the group's own rectangle.
    static func align(_ specs: [TouchControlSpec], ids: Set<UUID>, edge: Edge, in field: CGSize, scale: Double = 1) -> [TouchControlSpec] {
        guard ids.count > 1, let box = bounds(specs, ids: ids, in: field, scale: scale), field.width > 0, field.height > 0 else { return specs }
        return specs.map { spec in
            guard ids.contains(spec.id) else { return spec }
            var s = spec; let e = extent(s, scale: scale)
            switch edge {
            case .left: s.x = Double((box.minX + e.width / 2) / field.width)
            case .centreX: s.x = Double(box.midX / field.width)
            case .right: s.x = Double((box.maxX - e.width / 2) / field.width)
            case .top: s.y = Double((box.minY + e.height / 2) / field.height)
            case .centreY: s.y = Double(box.midY / field.height)
            case .bottom: s.y = Double((box.maxY - e.height / 2) / field.height)
            }
            clamp(&s); return s
        }
    }

    /// Spaces three or more controls so the gaps between neighbours are equal, the first and last staying where they are.
    static func distribute(_ specs: [TouchControlSpec], ids: Set<UUID>, axis: Axis, in field: CGSize, scale: Double = 1) -> [TouchControlSpec] {
        guard ids.count > 2, field.width > 0, field.height > 0 else { return specs }
        let chosen = specs.filter { ids.contains($0.id) }
        func centre(_ s: TouchControlSpec) -> Double { axis == .across ? s.x : s.y }
        func length(_ s: TouchControlSpec) -> Double { Double(axis == .across ? extent(s, scale: scale).width : extent(s, scale: scale).height) }
        let span = Double(axis == .across ? field.width : field.height)
        let order = chosen.sorted { centre($0) < centre($1) }
        let first = order.first!, last = order.last!
        let start = centre(first) * span - length(first) / 2, end = centre(last) * span + length(last) / 2
        let gap = (end - start - order.reduce(0) { $0 + length($1) }) / Double(order.count - 1)
        var at = start, placed: [UUID: Double] = [:]
        for s in order { placed[s.id] = (at + length(s) / 2) / span; at += length(s) + gap }
        return specs.map { spec in
            guard let c = placed[spec.id] else { return spec }
            var s = spec
            if axis == .across { s.x = c } else { s.y = c }
            clamp(&s); return s
        }
    }

    /// Flips the controls left to right: about the middle of the screen (`wholeScreen`, for a left-handed layout) or about the middle of their own centres (a cluster turned in place).
    static func mirror(_ specs: [TouchControlSpec], ids: Set<UUID>, wholeScreen: Bool, in field: CGSize) -> [TouchControlSpec] {
        guard field.width > 0, !ids.isEmpty else { return specs }
        let mid: Double
        if wholeScreen { mid = 0.5 }
        else {
            let xs = specs.filter { ids.contains($0.id) }.map(\.x)
            guard let low = xs.min(), let high = xs.max() else { return specs }
            mid = (low + high) / 2
        }
        return specs.map { spec in
            guard ids.contains(spec.id) else { return spec }
            var s = spec; s.x = 2 * mid - s.x; clamp(&s); return s
        }
    }

    /// Moves the controls together by a fraction of the screen each way, less if one of them would leave the screen (the group keeps its shape).
    static func moved(_ specs: [TouchControlSpec], ids: Set<UUID>, dx: Double, dy: Double) -> [TouchControlSpec] {
        let chosen = specs.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return specs }
        let lowX = xRange.lowerBound - chosen.map(\.x).min()!, highX = xRange.upperBound - chosen.map(\.x).max()!
        let lowY = yRange.lowerBound - chosen.map(\.y).min()!, highY = yRange.upperBound - chosen.map(\.y).max()!
        let mx = lowX > highX ? 0 : min(max(dx, lowX), highX), my = lowY > highY ? 0 : min(max(dy, lowY), highY)
        return specs.map { spec in
            guard ids.contains(spec.id) else { return spec }
            var s = spec; s.x += mx; s.y += my; return s
        }
    }

    /// Makes the group bigger or smaller about the middle of its centres: the controls and the space between them scale together.
    static func scaled(_ specs: [TouchControlSpec], ids: Set<UUID>, by factor: Double, in field: CGSize) -> [TouchControlSpec] {
        let chosen = specs.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, factor > 0, field.width > 0, field.height > 0 else { return specs }
        let px = (chosen.map(\.x).min()! + chosen.map(\.x).max()!) / 2, py = (chosen.map(\.y).min()! + chosen.map(\.y).max()!) / 2
        return specs.map { spec in
            guard ids.contains(spec.id) else { return spec }
            var s = spec
            s.x = px + (s.x - px) * factor; s.y = py + (s.y - py) * factor
            s.size = min(max((s.size * factor).rounded(), TouchLayout.sizeRange.lowerBound), TouchLayout.sizeRange.upperBound)
            clamp(&s); return s
        }
    }

    /// Gives every chosen control the same width.
    static func sized(_ specs: [TouchControlSpec], ids: Set<UUID>, to size: Double) -> [TouchControlSpec] {
        let clamped = min(max(size.rounded(), TouchLayout.sizeRange.lowerBound), TouchLayout.sizeRange.upperBound)
        return specs.map { spec in
            guard ids.contains(spec.id) else { return spec }
            var s = spec; s.size = clamped; return s
        }
    }

    /// Copies of the chosen controls with new ids, moved a little so they can be told from the originals (as far as the screen allows).
    static func copies(of specs: [TouchControlSpec], ids: Set<UUID>, dx: Double = 0.05, dy: Double = 0.08) -> [TouchControlSpec] {
        let chosen = specs.filter { ids.contains($0.id) }
        let ids = Set(chosen.map(\.id))
        return moved(chosen, ids: ids, dx: dx, dy: dy).map { var c = $0; c.id = UUID(); return c }
    }

    /// The width all the controls share, if they do (what the size slider shows for several controls); nil when they differ.
    static func commonSize(_ specs: [TouchControlSpec]) -> Double? {
        guard let first = specs.first, specs.allSatisfy({ $0.size == first.size }) else { return nil }
        return first.size
    }

    /// The ids of the controls whose centres lie inside a rectangle in points (a box drawn across the screen).
    static func inside(_ rect: CGRect, specs: [TouchControlSpec], in field: CGSize) -> [UUID] {
        specs.filter { rect.contains(CGPoint(x: $0.x * Double(field.width), y: $0.y * Double(field.height))) }.map(\.id)
    }
}

/// Where a layout's fractions land on a screen of a given size. A layout is drawn for a phone: control sizes are points, so on a bigger screen (an iPad) plain
/// fractions would push the controls far apart while the buttons stayed the same size. Instead the layout lives in a phone-sized "design" area (a little bigger on
/// a big screen) whose left part is pinned to the left edge and whose right part to the right edge, and whose top row is pinned to the top edge and everything else to the bottom (where
/// the thumbs are); only the strip in between, where controls are rare and the right thumb's look zone sits, takes up the extra room. On a phone the design area is the whole screen and nothing moves.
struct ControlSpace: Equatable {
    /// The area a phone layout was drawn for (the screen without its safe-area insets).
    static let reference = CGSize(width: 750, height: 380)
    /// Across, fractions up to `acrossLeft` keep their distance from the left edge and those from `acrossRight` on from the right edge; the few between stretch.
    /// Down, only the top row (up to `downTop`) hangs from the top: everything else hangs from the bottom, where the thumbs are.
    static let acrossLeft = 0.45, acrossRight = 0.55, downTop = 0.25, downBottom = 0.30
    /// How much of a big screen's extra size the controls' spacing takes up (0 = none, 1 = all, which is plain fractions).
    static let growth = 0.3, growthLimit = 1.25

    let field: CGSize
    /// Left-handed: the layout is shown flipped left to right (a switch in Settings and the in-game menu). Only the display flips: what is stored is not changed, so the same layout
    /// serves both hands and a layout shared with someone else is not turned round.
    let mirrored: Bool
    /// The size the layout's own maths (align, space, flip, scale) works in: fractions of this are points, so spacing between controls is true to their size.
    let design: CGSize

    init(field: CGSize, mirrored: Bool = false) {
        self.field = field
        self.mirrored = mirrored
        guard field.width > 0, field.height > 0 else { design = field; return }
        let r = min(field.width / Self.reference.width, field.height / Self.reference.height)
        let k = r > 1 ? min(1 + Self.growth * (r - 1), Self.growthLimit) : 1
        design = CGSize(width: min(field.width, Self.reference.width * k), height: min(field.height, Self.reference.height * k))
    }

    private static func place(_ f: Double, length l: Double, design d: Double, start a: Double, end b: Double) -> Double {
        if f <= a { return f * d }
        if f >= b { return l - (1 - f) * d }
        return a * d + (f - a) / (b - a) * (l - (1 - b) * d - a * d)
    }
    private static func fraction(_ p: Double, length l: Double, design d: Double, start a: Double, end b: Double) -> Double {
        guard d > 0 else { return 0 }
        if p <= a * d { return p / d }
        if p >= l - (1 - b) * d { return 1 - (l - p) / d }
        let band = l - (1 - b) * d - a * d
        return band > 0 ? a + (p - a * d) / band * (b - a) : (a + b) / 2
    }

    /// Where a layout position is, in points from the field's top left corner.
    func point(x: Double, y: Double) -> CGPoint {
        let x = mirrored ? 1 - x : x
        return CGPoint(x: Self.place(x, length: Double(field.width), design: Double(design.width), start: Self.acrossLeft, end: Self.acrossRight),
                y: Self.place(y, length: Double(field.height), design: Double(design.height), start: Self.downTop, end: Self.downBottom))
    }
    /// The layout position of a point in points from the field's top left corner (the other way round).
    func fractions(of p: CGPoint) -> (x: Double, y: Double) {
        let x = Self.fraction(Double(p.x), length: Double(field.width), design: Double(design.width), start: Self.acrossLeft, end: Self.acrossRight)
        return (mirrored ? 1 - x : x,
                Self.fraction(Double(p.y), length: Double(field.height), design: Double(design.height), start: Self.downTop, end: Self.downBottom))
    }
    /// A rectangle in field points as a rectangle in design points (a box drawn across the screen, for `ControlArrange.inside`).
    func designRect(_ r: CGRect) -> CGRect {
        let a = fractions(of: CGPoint(x: r.minX, y: r.minY)), b = fractions(of: CGPoint(x: r.maxX, y: r.maxY))
        // Flipped, the left edge of the box on the screen is the right edge in the layout's own terms: the rectangle is the same either way.
        return CGRect(x: min(a.x, b.x) * Double(design.width), y: min(a.y, b.y) * Double(design.height),
                      width: abs(b.x - a.x) * Double(design.width), height: abs(b.y - a.y) * Double(design.height))
    }
}

/// Controls taken from a layout to be put into another (Options > Copy to another layout, Paste here). It lives as long as the app does.
enum ControlClipboard {
    nonisolated(unsafe) static var specs: [TouchControlSpec] = []
    static var count: Int { specs.count }
    static func copy(_ chosen: [TouchControlSpec]) { specs = chosen }
    /// Fresh copies with new ids, ready to add (an overlay spot the layout already has is left out).
    static func paste(into existing: [TouchControlSpec], room: Int) -> [TouchControlSpec] {
        let taken = Set(existing.map(\.action))
        return specs.filter { !($0.isOverlay && taken.contains($0.action)) }.prefix(max(room, 0)).map { var c = $0; c.id = UUID(); return c }
    }
}
