// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A call ringing over the game: who is calling, with Decline and Join right on it, so answering does not need the menu.
struct DiscordCallBannerCard: View {
    let call: DiscordIncomingCall
    var join: () -> Void = {}
    var decline: () -> Void = {}
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(BannerColors.call.opacity(0.7), lineWidth: 2).frame(width: 50, height: 50).scaleEffect(pulse ? 1.45 : 1).opacity(pulse ? 0 : 0.9)
                DiscordAvatar(member: CallMember(id: call.caller?.id ?? call.channelID, name: call.title, avatarURL: call.caller?.avatarURL, speaking: false, isSelf: false), diameter: 46)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(call.headline).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Label(call.isGroup ? "Group call" : "Incoming call", systemImage: "phone.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(BannerColors.call)
            }
            Spacer(minLength: 4)
            Button(action: decline) {
                Label("Decline", systemImage: "phone.down.fill").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 12).frame(height: 38).background(BannerColors.decline, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel("Decline")
            Button(action: join) {
                Label("Join", systemImage: "phone.fill").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 14).frame(height: 38).background(BannerColors.call, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel("Join")
        }
        .bannerChrome(accent: BannerColors.call)
        .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
    }
}
