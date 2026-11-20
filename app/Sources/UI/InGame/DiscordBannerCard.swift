// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// What a Discord message banner looks like: who, where, the start of the message. A tap answers it, a swipe up sends it away.
struct DiscordBannerCard: View {
    let banner: DiscordBanner
    /// How long it stays (the line along its bottom drains); nil for a still card.
    var lifetime: TimeInterval?
    var open: () -> Void = {}
    var dismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            DiscordAvatar(member: CallMember(id: banner.author.id, name: banner.author.displayName, avatarURL: banner.author.avatarURL, speaking: false, isSelf: false), diameter: 46)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: banner.conversation.isDirect ? "envelope.fill" : "number").font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                        .frame(width: 19, height: 19).background(BannerColors.discord, in: Circle())
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2)).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(banner.author.displayName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    Text(banner.conversation.isDirect ? "Direct message" : banner.conversation.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(BannerColors.discord.opacity(0.95)).lineLimit(1)
                }
                Text(banner.line).font(.system(size: 14)).foregroundStyle(.white.opacity(0.92)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Label("Reply", systemImage: "arrowshape.turn.up.left.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.14), in: Capsule())
        }
        .bannerChrome(accent: BannerColors.discord, lifetime: lifetime)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { open() }
        .gesture(DragGesture(minimumDistance: 8).onEnded { if $0.translation.height < -10 { dismiss() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the conversation in the in-game menu")
    }
}
