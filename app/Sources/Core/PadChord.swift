// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The controller buttons that open Porthole's in-game menu: two buttons held together for half a second. Menu + View (Options + Create on a DualSense) by default, because
/// games hardly ever want both at once; `env.PORTHOLE_PAD_MENU` = `l3r3` (both stick clicks), `home` (the PS / Xbox button, which iOS keeps for itself on some pads) or `off` changes it.
/// Xbox-pad button masks as the XInput state uses them.
struct PadChordSetting {
    static let menuView: UInt16 = 0x0030, l3r3: UInt16 = 0x00C0, home: UInt16 = 0x0400

    /// The buttons that must all be down; 0 = the chord is switched off.
    static func mask(for option: String) -> UInt16 {
        switch option.lowercased() {
        case "off", "0", "no": 0
        case "l3r3", "l3+r3": l3r3
        case "home", "ps", "guide": home
        default: menuView
        }
    }

    /// What the chord is called for the controller in the player's hands.
    static func name(mask: UInt16, kind: ControllerKind) -> String {
        switch mask {
        case menuView: kind.menuChordName
        case l3r3: "both stick clicks"
        case home: kind.homeName
        default: ""
        }
    }
}

/// Fires once when all of `mask`'s buttons have been down for `hold` seconds, and not again until they have been let go.
struct PadChord {
    var hold: TimeInterval = 0.5
    private var since: TimeInterval?
    private var fired = false

    /// `held`: the buttons down right now. Returns true on the call where the chord completes.
    mutating func update(held: UInt16, mask: UInt16, now: TimeInterval) -> Bool {
        guard mask != 0, held & mask == mask else { since = nil; fired = false; return false }
        if since == nil { since = now }
        guard !fired, let s = since, now - s >= hold else { return false }
        fired = true
        return true
    }

    /// The chord's buttons are down together (they are kept from the game while that lasts).
    func isDown(held: UInt16, mask: UInt16) -> Bool { mask != 0 && held & mask == mask }
}

/// After the in-game menu closes, the buttons that were down at that moment (the B that closed it) are kept from the game until they are let go.
struct PadReleaseMask {
    private(set) var mask: UInt16 = 0
    mutating func latch(_ held: UInt16) { mask = held }
    /// Removes the latched buttons from `buttons`, and forgets the ones that have been let go.
    mutating func apply(_ buttons: UInt16) -> UInt16 {
        guard mask != 0 else { return buttons }
        mask &= buttons
        return buttons & ~mask
    }
}

extension Notification.Name {
    /// The chord was held: the in-game menu opens or closes.
    static let padMenuChord = Notification.Name("PortholePadMenuChord")
    /// The running Steam game asked for Steam's overlay (its Workshop or Store button, Shift+Tab): the HUD shows the app's Steam menu instead.
    static let steamOverlayRequested = Notification.Name("PortholeSteamOverlayRequested")
}
