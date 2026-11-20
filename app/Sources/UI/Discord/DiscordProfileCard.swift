// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A person's card, opened by tapping their picture or name: their banner and picture, their name, what they are doing, what they wrote about themselves, how long they have had the
/// account and which servers you share, with Message and Call. It is drawn from plain values (the profile is read by `load` when the card opens), so the preview app can show it.
struct DiscordProfileCard: View {
    let user: DiscordUser
    /// This is the signed-in account itself: no Message or Call.
    var isSelf = false
    /// What is known of them already (friends only): their status and the game they are playing.
    var status: DiscordStatus?
    var activity: String?
    /// The name of a server by its id (only the servers this account shows).
    var serverName: (String) -> String? = { _ in nil }
    /// Asks for the full profile; the closure is called with it, or nil when Discord would not say.
    var load: (@escaping (DiscordProfile?) -> Void) -> Void = { $0(nil) }
    var message: () -> Void = {}
    var call: () -> Void = {}
    var close: () -> Void = {}

    @State private var profile: DiscordProfile?
    @State private var loading = true
    @State private var scope = FocusScope()
    @Environment(\.verticalSizeClass) private var vSize

    private var accent: Color { profile?.accent.map { Color(hex: $0) } ?? Theme.accent }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    PillButton(id: "pf-close", title: "Close", symbol: "xmark") { close() }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if !isSelf { actions }
                        details
                    }
                    .padding(.horizontal, 20).padding(.bottom, 30)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear {
            scope.defaultFocus = isSelf ? "pf-close" : "pf-message"; scope.focused = scope.defaultFocus
            scope.onBack = { close() }
            load { p in profile = p; loading = false }
        }
        .preferredColorScheme(Theme.scheme)
    }

    // MARK: Pieces

    /// The banner (their picture or their colour), their picture over it, and their names.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                banner.frame(height: vSize == .compact ? 90 : 130)
                DiscordFace(url: user.avatarURL, name: user.displayName, size: 84)
                    .overlay(Circle().strokeBorder(Theme.backgroundTop, lineWidth: 5))
                    .overlay(alignment: .bottomTrailing) { if let status { statusDot(status) } }
                    .offset(x: 18, y: 42)
            }
            .padding(.bottom, 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayName).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2)
                HStack(spacing: 8) {
                    Text(user.username).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textDim)
                    if let p = profile?.pronouns, !p.isEmpty { Text("\u{00B7} \(p)").font(.system(size: 15)).foregroundStyle(Theme.textDim) }
                }
                if let line = activity ?? status?.title {
                    HStack(spacing: 6) {
                        if let status { Circle().fill(status.isOnline ? Theme.good : Theme.textDim).frame(width: 8, height: 8) }
                        Text(line).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(2)
                    }.padding(.top, 4)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var banner: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url = profile?.bannerURL {
                AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFill() } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }

    private func statusDot(_ status: DiscordStatus) -> some View {
        Circle().fill(status.isOnline ? Theme.good : Theme.textDim).frame(width: 20, height: 20).overlay(Circle().strokeBorder(Theme.backgroundTop, lineWidth: 4))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            PillButton(id: "pf-message", title: "Message", symbol: "bubble.left.fill", style: .primary) { message() }
            PillButton(id: "pf-call", title: "Call", symbol: "phone.fill") { call() }
        }
    }

    @ViewBuilder private var details: some View {
        if loading {
            HStack(spacing: 10) { ProgressView(); Text("Reading their profile").font(.subheadline).foregroundStyle(Theme.textDim) }
                .frame(maxWidth: .infinity).padding(20)
        } else if let p = profile {
            if !p.bio.isEmpty { section("About me") { Text(p.bio).font(.system(size: 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) } }
            section("Member since") {
                Text(p.createdAt?.formatted(date: .long, time: .omitted) ?? "Unknown").font(.system(size: 15)).foregroundStyle(Theme.text)
            }
            let servers = p.mutualServerIDs.compactMap(serverName)
            if !servers.isEmpty || p.mutualFriendCount > 0 {
                section("In common") {
                    VStack(alignment: .leading, spacing: 6) {
                        if p.mutualFriendCount > 0 { Label("\(p.mutualFriendCount) mutual friend\(p.mutualFriendCount == 1 ? "" : "s")", systemImage: "person.2.fill").font(.system(size: 15)).foregroundStyle(Theme.text) }
                        if !servers.isEmpty {
                            Label("\(servers.prefix(8).joined(separator: ", "))\(servers.count > 8 ? " and \(servers.count - 8) more" : "")", systemImage: "server.rack").font(.system(size: 15)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } else {
            section("Profile") {
                Text(isSelf ? "This is you." : "Discord did not share more about this person. You can still message them.").font(.system(size: 15)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(0.6).foregroundStyle(Theme.textDim)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One conversation in the Messages list: the other person's picture (a group's pictures overlap), its name, and the start of the latest message when it has been read.
struct DiscordConversationRow: View {
    let title: String
    let users: [DiscordUser]
    var isGroup = false
    var preview: String?
    var selected = false
    /// Messages waiting in it (0: none); the name is bold while there are some.
    var unread = 0

    var body: some View {
        HStack(spacing: 12) {
            faces
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: unread > 0 ? .heavy : .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if let preview, !preview.isEmpty { Text(preview).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1) }
                else if isGroup { Text("\(users.count + 1) people").font(.footnote).foregroundStyle(Theme.textDim) }
            }
            Spacer(minLength: 4)
            if unread > 0 { DiscordCountBadge(count: unread) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 54)
        .background(selected ? Theme.panelHigh : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var faces: some View {
        if users.count <= 1 {
            DiscordFace(url: users.first?.avatarURL, name: users.first?.displayName ?? title, size: 40)
        } else {
            ZStack {
                DiscordFace(url: users[0].avatarURL, name: users[0].displayName, size: 28).offset(x: -7, y: -7)
                DiscordFace(url: users[1].avatarURL, name: users[1].displayName, size: 28).overlay(Circle().strokeBorder(Theme.backgroundTop, lineWidth: 2)).offset(x: 7, y: 7)
            }
            .frame(width: 40, height: 40)
        }
    }
}

/// A small "LIVE" mark on somebody who is streaming in a voice channel.
struct DiscordLiveBadge: View {
    var small = false
    var body: some View {
        Text("LIVE").font(.system(size: small ? 9 : 10, weight: .heavy, design: .rounded)).tracking(0.5).foregroundStyle(.white)
            .padding(.horizontal, small ? 4 : 6).padding(.vertical, 2).background(Theme.bad, in: Capsule()).accessibilityLabel("Streaming")
    }
}

/// The little red number on a conversation, a channel, or a server: how many messages are waiting.
struct DiscordCountBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.white).monospacedDigit()
            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20).background(Theme.bad, in: Capsule())
            .accessibilityLabel("\(count) unread")
    }
}
