// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// When a Steam game may start from Steam's saved (offline) sign-in although a network is there: the rule only, so a host test can check it. DockOffline asks it.
enum SavedSignInRule {
    /// How long after a game's last online start the saved sign-in is used; the next start goes online and renews it.
    static let maxAge: TimeInterval = 14 * 24 * 3600

    /// `override`: the game's own choice (0 saved sign-in when ready, 1 online every time, 2 offline every time); nil follows Settings.
    /// `alwaysOffline`: Settings > Steam > "Start Steam games offline". It only means "use the offline sign-in whenever Steam can": a start Steam cannot do offline
    /// (nothing saved yet, the game never started online, the saved sign-in is old, Steam refused it last time) goes online, which saves a new one.
    static func decide(enabled: Bool, override: Int?, settingOn: Bool, alwaysOffline: Bool = false, forcedOnline: Bool, accountSaved: Bool, verified: Date?, now: Date = Date()) -> (use: Bool, why: String) {
        guard enabled else { return (false, "offline logon is off") }
        if override == 1 { return (false, "the game asks for an online sign-in") }
        let chosen = override == 2 || (override == nil && alwaysOffline)
        if override == nil, !settingOn, !chosen { return (false, "switched off in Settings") }
        if forcedOnline { return (false, "Steam could not use its saved sign-in last time") }
        guard accountSaved else { return (false, "Steam has no offline sign-in saved yet") }
        guard let when = verified else { return (false, "this game has not started online yet") }
        let age = now.timeIntervalSince(when)
        if age > maxAge { return (false, "the last online start was \(Int(age / 86400)) days ago") }
        return (true, (chosen ? "offline start chosen; " : "") + "this game started online \(max(0, Int(age / 3600))) hours ago")
    }
}
