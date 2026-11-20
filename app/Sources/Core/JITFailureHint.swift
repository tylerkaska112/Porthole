// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What to tell a person whose JIT could not be switched on, from what Porthole knows about their setup.
///
/// The JIT helper only knows that it could not reach the device ("the device is not ready for debugging", or a timeout after a minute or more). Hub reports show the usual
/// cause is one the app can see: this copy was signed without the VPN permission, so Porthole's own private link cannot start, and the person has not switched on
/// "Use LocalDevVPN instead" (or LocalDevVPN is not actually running). Naming that saves them a wait and a guess. Pure text and decisions: the facts come from the caller.
enum JITFailureHint {
    struct Facts: Equatable {
        /// This install cannot start Porthole's own tunnel: no tunnel extension in it, or it was signed without the VPN (packet tunnel) permission, by another team, or expired.
        var ownTunnelCannotStart: Bool
        /// "Use LocalDevVPN instead" is on.
        var useLocalDevVPN: Bool
        /// Some VPN is up right now (a tunnel interface is listed). It cannot say which one.
        var vpnInterfaceUp: Bool
    }

    /// The JIT helper's failures that are about reaching the device (the others, such as a missing signature, already say what is wrong).
    static func applies(to message: String) -> Bool {
        message.hasPrefix("JIT failed") || message.hasPrefix("JIT timed out")
    }

    static let noOwnTunnel = "Porthole's own private link cannot start on this install (it was signed without the VPN permission), so JIT has no way to reach the device. Install LocalDevVPN, turn it on, then switch on \u{201C}Use LocalDevVPN instead\u{201D} in Settings \u{203A} JIT and connection, and start the game again."
    static let localDevNotUp = "\u{201C}Use LocalDevVPN instead\u{201D} is on, but no VPN looks switched on. Open LocalDevVPN and tap Connect (a VPN symbol shows in the status bar), then start the game again."
    static let localDevOffByChoice = "Porthole's own private link cannot start on this install, and no VPN looks switched on. Turn on LocalDevVPN, and switch on \u{201C}Use LocalDevVPN instead\u{201D} in Settings \u{203A} JIT and connection."

    /// The sentence to add after the helper's message, or nil when nothing more is known.
    static func hint(for message: String, facts: Facts) -> String? {
        guard applies(to: message) else { return nil }
        if facts.useLocalDevVPN { return facts.vpnInterfaceUp ? nil : localDevNotUp }
        if facts.ownTunnelCannotStart { return facts.vpnInterfaceUp ? noOwnTunnel : localDevOffByChoice }
        return nil
    }

    /// The message to show: the helper's, with the hint after it.
    static func message(_ message: String, facts: Facts) -> String {
        hint(for: message, facts: facts).map { message + " " + $0 } ?? message
    }

    /// Whether to stop before trying JIT at all: the in-app method needs a tunnel, this install cannot start its own, and nothing else is providing one. (When some VPN is up,
    /// it may be LocalDevVPN used without the setting, and trying costs nothing.)
    static func shouldFailBeforeTrying(_ facts: Facts) -> Bool {
        facts.ownTunnelCannotStart && !facts.useLocalDevVPN && !facts.vpnInterfaceUp
    }
}
