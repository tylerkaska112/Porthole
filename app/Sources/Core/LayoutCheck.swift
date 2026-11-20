// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// A look at a touch layout for what makes it hard to use: buttons that sit on top of each other (a thumb hits the wrong one) and buttons too small to hit. Pure maths on where the
/// controls are drawn on a screen of a given size, so the game page can say so without starting the game and the editor can outline the culprits. The overlay spots (performance
/// numbers, the call) are not buttons and are left out.
struct LayoutCheck: Equatable {
    /// The controls that touch another control, in layout order.
    var overlapping: [UUID] = []
    /// The controls drawn narrower than `smallest` points.
    var small: [UUID] = []
    /// A button narrower than this is hard to hit with a thumb (Apple's own guidance is 44 points; a few of the layouts' small keys are 38 to 40).
    static let smallest: Double = 34
    /// Two buttons may touch rim to rim: they only count as overlapping when their circles share more than this many points.
    static let slack: Double = 3

    var isClean: Bool { overlapping.isEmpty && small.isEmpty }

    /// One sentence for the person ("2 buttons overlap and 1 is very small."), or nil when the layout is clean.
    var summary: String? {
        guard !isClean else { return nil }
        func buttons(_ n: Int) -> String { n == 1 ? "1 button" : "\(n) buttons" }
        var parts: [String] = []
        if !overlapping.isEmpty { parts.append("\(buttons(overlapping.count)) overlap\(overlapping.count == 1 ? "s" : "") another") }
        if !small.isEmpty { parts.append("\(buttons(small.count)) \(small.count == 1 ? "is" : "are") very small") }
        return parts.joined(separator: " and ") + "."
    }

    /// `field` is the screen's usable size; `scale` the button size setting; `mirrored` left-handed (which changes nothing about overlap, and is only here so a caller can pass what it uses).
    static func run(_ layout: TouchLayout, field: CGSize, scale: Double = 1, mirrored: Bool = false) -> LayoutCheck {
        let space = ControlSpace(field: field, mirrored: mirrored)
        let buttons = layout.controls.filter { !$0.isOverlay }
        let centres = buttons.map { space.point(x: $0.x, y: $0.y) }
        let radii = buttons.map { CGFloat($0.size * scale / 2) }
        var out = LayoutCheck()
        var touching = Set<Int>()
        for i in buttons.indices {
            if buttons[i].size * scale < smallest { out.small.append(buttons[i].id) }
            for j in buttons.indices where j > i {
                let d = hypot(centres[i].x - centres[j].x, centres[i].y - centres[j].y)
                if d < radii[i] + radii[j] - CGFloat(slack) { touching.insert(i); touching.insert(j) }
            }
        }
        out.overlapping = buttons.indices.filter { touching.contains($0) }.map { buttons[$0].id }
        return out
    }
}
