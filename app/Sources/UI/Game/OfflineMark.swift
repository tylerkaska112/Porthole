// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Game page, Play: whether a Steam game that Valve's client starts can start without a connection (DockOffline.Mark). Steam's offline sign-in belongs to the account: once Valve's
/// client has reported that it can sign the account in offline, every installed game can start that way, and the client answers the licence question from the list it cached. Only a
/// game whose per-user program Steam prepares on its first start still needs that one start online. Tapping the row explains it; an offline start is always Steam's decision at that moment.
struct OfflineMarkRow: View {
    let appID: Int
    @State private var explain = false
    /// The game's install record lists per-user executables (read once; it scans the library).
    @State private var preparedOnline = false
    /// Bumped when the note of the last online start changes, so the row redraws.
    @State private var tick = 0

    var body: some View {
        let mark = DockOffline.mark(appID, preparedOnline: preparedOnline)
        let ready: Bool = { if case .ready = mark { return true } else { return false } }()
        ValueRow(id: "gp-offline", symbol: ready ? "checkmark.circle.fill" : "wifi.exclamationmark", title: "Offline play", value: Self.line(mark),
                 statusColor: ready ? Theme.good : nil) { explain = true }
            .id(tick)
            .task { preparedOnline = MadeiraDock.games(drive: AppModel.driveC).first { $0.id == appID }?.customExecutables ?? false }
            .onReceive(NotificationCenter.default.publisher(for: DockOffline.changed)) { _ in tick += 1 }
            .alert(ready ? "Can be played offline" : "Not ready for offline play yet", isPresented: $explain) {
                Button("OK", role: .cancel) {}
            } message: { Text(Self.explanation(mark)) }
    }

    static func line(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready: return "Ready"
        case .needsFirstStart: return "Start once online"
        case .needsOnline: return "Start a game online first"
        }
    }

    static func explanation(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready(let saved):
            return "Steam signed in online on this device on \(saved.formatted(date: .abbreviated, time: .omitted)) and can now sign this account in without a connection. With no internet, Porthole asks Steam to start the game offline; Steam checks its saved sign-in and its saved list of your licences each time. Its offline sign-in expires after a while, so start a game online now and then. A game that needs its own servers still needs them."
        case .needsFirstStart:
            return "Steam can sign this account in offline, but it prepares this game's program for your account the first time it starts, and that needs a connection. Start this game once while you are online."
        case .needsOnline:
            return "Steam has not saved an offline sign-in on this device yet. Start any Steam game once while you are online (through Steam, not Run directly); after that, installed games can start without a connection."
        }
    }
}
