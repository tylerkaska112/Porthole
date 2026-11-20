// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// How big the on-screen buttons of a touch layout are drawn, as a factor of the size each control has in its layout: one setting for the device (Settings > Controls > Touch screen, and the
/// layout editor's Options), because how big a button should be depends on the hands and the screen, not on the game. Layouts are drawn for a phone, so "Automatic" makes them a little
/// larger on an iPad, where the same size looks small. The on-screen game controller has its own size and is not affected.
enum TouchButtonSize {
    static let key = "f4.touchButtonSize"
    /// The choices a person sees, as (stored value, name). "" is Automatic.
    static let choices: [(value: String, title: String)] = [("", "Automatic"), ("0.85", "Smaller"), ("1", "Normal"), ("1.1", "Larger"), ("1.2", "Largest")]
    static let range = 0.5...2.0

    /// The factor for a stored setting on a phone or an iPad.
    static func factor(setting: String?, isPad: Bool) -> Double {
        if let setting, let v = Double(setting), range.contains(v) { return v }
        return isPad ? 1.2 : 1
    }

    /// What the stored setting is called ("Larger"); a value that is not one of the choices (a hand-edited default) reads as Automatic.
    static func title(setting: String?) -> String {
        choices.first { $0.value == (setting ?? "") }?.title ?? "Automatic"
    }
}

/// Left-handed: every touch layout is shown flipped left to right on this device (see ControlSpace.mirrored). A display switch, not an edit of the layouts.
enum TouchHandedness {
    static let key = "f4.leftHanded"
    static let changed = Notification.Name("f4.touchHandednessChanged")
    static var leftHanded: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Sets it and tells whatever is showing a layout to draw it again.
    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// The edge a person means when the layout is flipped: "left" on the screen is the layout's own right edge (the editor's Align left / right).
    static func storedEdge<E>(_ edge: E, left: E, right: E, flipped: Bool) -> E where E: Equatable { flipped ? (edge == left ? right : (edge == right ? left : edge)) : edge }
}
