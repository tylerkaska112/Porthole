// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// How loud the microphone is right now, with a tick where it starts to count as talking: green past the tick, grey below it. Lets the sensitivity be set by looking
/// instead of guessing.
struct MicLevelBar: View {
    @ObservedObject private var discord = DiscordSession.shared

    private var inCall: Bool { if case .ready = discord.voiceState { return true }; return false }

    var body: some View {
        let level = inCall && !discord.micMuted ? CGFloat(discord.micLevel) : 0
        let tick = CGFloat(MicSensitivity.thresholdPosition(percent: discord.micSensitivity))
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelHigh)
                    Capsule().fill(level >= tick ? Theme.good : Theme.textDim).frame(width: max(6, geo.size.width * level))
                    Rectangle().fill(Theme.text).frame(width: 2).offset(x: geo.size.width * tick - 1)
                }
                .animation(.linear(duration: 0.1), value: level)
            }
            .frame(height: 8)
            Text(caption).font(.caption).foregroundStyle(Theme.textDim)
        }
        .onAppear { discord.watchMicLevel(true) }
        .onDisappear { discord.watchMicLevel(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
    }

    private var caption: String {
        if !inCall { return "Join a voice channel to see your microphone's level here." }
        if discord.micMuted { return "The microphone is muted." }
        return "Talk normally: the bar should go past the line when you speak and stay under it when you do not."
    }
}
