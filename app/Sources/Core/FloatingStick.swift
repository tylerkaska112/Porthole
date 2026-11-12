// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// Floating sticks: the stick's base appears where the thumb lands, near the stick's own place, instead of the thumb having to find a fixed circle. Playport and BCD both do this for
/// their on-screen sticks; this is Porthole's own geometry, kept apart from the views so it can be tested.
///
/// A stick takes a touch that lands in its ZONE (its own frame grown a little) unless a neighbouring control is there; the base is then centred on the thumb, moved only as far as it
/// takes to keep the whole base on the screen's usable area (inside the safe area).
enum FloatingStick {
    /// The setting: on or off for every on-screen stick (the in-game menu's Controls tab).
    static let key = "f4.floatingSticks"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// How far the zone reaches beyond the stick's frame, in sticks' sizes.
    static let reachAcross: CGFloat = 1.0, reachUpDown: CGFloat = 0.8

    /// The area in which a floating stick takes a touch.
    static func zone(of frame: CGRect) -> CGRect {
        frame.insetBy(dx: -frame.width * reachAcross, dy: -frame.height * reachUpDown)
    }

    /// Whether a touch at `point` belongs to the floating stick: in its zone and not on a neighbour (a neighbour's own area, grown by `slop`).
    static func takes(_ point: CGPoint, frame: CGRect, neighbours: [CGRect], slop: CGFloat = 6) -> Bool {
        guard zone(of: frame).contains(point) else { return false }
        return !neighbours.contains { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// Where the base is centred when a thumb lands at `touch`: on it, or the nearest place that keeps the whole base (a circle of `diameter`) inside `field`.
    /// With no field, or one too small for the base, the thumb's own point is used (a base is never moved to a place that is not on the screen at all).
    static func centre(touch: CGPoint, diameter: CGFloat, field: CGRect?) -> CGPoint {
        guard let field, field.width >= diameter, field.height >= diameter else { return touch }
        let r = diameter / 2
        return CGPoint(x: min(max(touch.x, field.minX + r), field.maxX - r), y: min(max(touch.y, field.minY + r), field.maxY - r))
    }
}
