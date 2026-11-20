// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The performance numbers and the people in the call, in the room between the controller's trigger columns while the game's picture is moved up on an iPad (BandOverlayStack lays them out).
/// It stands in for both overlays then, and each still follows its own settings: on or off, the metrics, the size and opacity, only the people who are talking.
struct BandOverlayView: View {
    @ObservedObject var perfSettings: PerfOverlaySettings
    @ObservedObject var perfModel: PerfOverlayModel
    @ObservedObject var discordSettings: DiscordOverlaySettings
    @ObservedObject var discord: DiscordSession

    var body: some View {
        GeometryReader { geo in
            let members = discordSettings.enabled ? (discordSettings.onlySpeaking ? discord.callMembers.filter(\.speaking) : discord.callMembers) : []
            BandOverlayStack(room: geo.size,
                             perf: perfSettings.enabled ? PerfOverlayView.bandCard(settings: perfSettings, model: perfModel) : nil,
                             members: members, fontSize: discordSettings.size.font, opacity: discordSettings.opacity)
        }
    }
}
