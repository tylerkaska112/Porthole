// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A person's picture from Discord, or their initial on a circle; green ring while they talk.
struct DiscordAvatar: View {
    let member: CallMember
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
            Text(String(member.name.prefix(1)).uppercased()).font(.system(size: diameter * 0.5, weight: .bold)).foregroundStyle(.white)
            if let url = member.avatarURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().strokeBorder(Color.green, lineWidth: max(2, diameter * 0.1)).opacity(member.speaking ? 1 : 0))
        .animation(.easeOut(duration: 0.12), value: member.speaking)
    }
}
