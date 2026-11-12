// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// When the on-screen controls get out of the way: they hide after `seconds` with no finger on the screen, and a touch anywhere brings them back. The idea of controls that fade when
/// they are not used is the same as in BCD's touch layer and Playport's overlay; this is Porthole's own small state machine so it can be tested without a screen.
///
/// Nothing hides while a finger is down (a stick held for a while is not idle), while a menu or the editor is open, or while the game is not running; `seconds` 0 means never.
struct TouchAutoHide: Equatable {
    /// The choices the in-game menu offers (0 = never).
    static let choices = [0, 5, 10, 20]

    /// Seconds without a touch after which the controls hide. 0 = never.
    var seconds = 0
    private(set) var hidden = false
    private var lastActivity: TimeInterval = 0
    private var fingers = 0

    /// A touch began, moved or ended somewhere on the screen; `fingers` is how many are down now. Returns true when the controls came back because of it.
    @discardableResult
    mutating func touch(now: TimeInterval, fingers: Int) -> Bool {
        lastActivity = now
        self.fingers = max(0, fingers)
        let was = hidden
        hidden = false
        return was
    }

    /// About twice a second. `suspended`: the game is not running, or a menu or the editor is open (the controls show and the clock starts again when that ends).
    /// Returns true when `hidden` changed.
    @discardableResult
    mutating func tick(now: TimeInterval, suspended: Bool) -> Bool {
        let before = hidden
        if seconds <= 0 || suspended {
            hidden = false
            lastActivity = now
            fingers = 0
        } else if fingers == 0, now - lastActivity >= Double(seconds) {
            hidden = true
        }
        return hidden != before
    }

    /// The words for a choice in the menu.
    static func title(_ seconds: Int) -> String { seconds <= 0 ? "Never" : "After \(seconds) seconds" }
}
