// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A game that never asks for a controller while the on-screen game controller is on has no use for it: after a few seconds Porthole offers, once, to switch to the touch controls for
/// keyboard and mouse. Playport makes the same offer (after 20 seconds); the engine's count of the game's controller reads, which PadAuto already uses, is the signal.
///
/// Nothing is changed without a tap: the offer is a card with "Switch" and "Not now", and either answer is remembered for the game so it is never asked again.
struct LayoutSuggestion {
    /// How long a running game gets to read the controller before the offer is made.
    var grace: TimeInterval = 20
    private var startedAt: TimeInterval = 0
    private var baseline: UInt64 = 0
    private var finished = false

    /// A game's session began (or the offer is being re-armed). `reads` is the engine's count of controller reads so far.
    mutating func begin(now: TimeInterval, reads: UInt64) {
        startedAt = now; baseline = reads; finished = false
    }

    /// About once a second. `eligible`: the on-screen game controller is on, no real controller is connected, nothing (the menu, the editor) is in the way and the game was not asked before.
    /// Returns true once, when the offer should be shown. A game that reads the controller at any time ends the matter for this run.
    mutating func update(now: TimeInterval, reads: UInt64, eligible: Bool) -> Bool {
        guard !finished else { return false }
        if reads > baseline { finished = true; return false }          // it reads the controller: the pad is of use
        // The clock only runs while the offer could be made: turning the on-screen controller on, or closing the menu, starts the grace period again, so the card never appears at once.
        guard eligible else { startedAt = now; return false }
        guard now - startedAt >= grace else { return false }
        finished = true
        return true
    }

    // MARK: Remembered answers

    static let askedKey = "f4.layoutSuggested", offKey = "f4.layoutSuggestOff"

    /// Whether the offer may be made at all (the person did not turn it off) and was not made for this game before.
    static func mayAsk(gameID: String, defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: offKey) { return false }
        return !(defaults.stringArray(forKey: askedKey) ?? []).contains(gameID)
    }

    /// The offer was made for this game (answered either way): not again.
    static func remember(gameID: String, defaults: UserDefaults = .standard) {
        var asked = defaults.stringArray(forKey: askedKey) ?? []
        guard !asked.contains(gameID) else { return }
        asked.append(gameID)
        if asked.count > 300 { asked.removeFirst(asked.count - 300) }
        defaults.set(asked, forKey: askedKey)
    }

    /// The words of the offer.
    static func text(gameName: String?) -> String {
        "\(gameName ?? "This game") is not asking for a controller, so the on-screen controller does nothing here. Switch to touch controls for keyboard and mouse?"
    }
}
