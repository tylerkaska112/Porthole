// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Which messages are worth a banner over the game. The person picks.
enum DiscordNotifyKind: String, CaseIterable, Identifiable {
    case mentions, direct, everything
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mentions: "Mentions"
        case .direct: "Direct messages"
        case .everything: "Everything"
        }
    }
    var detail: String {
        switch self {
        case .mentions: "Messages that name you or answer something you wrote."
        case .direct: "Messages sent to you alone or in a group chat, not in a server."
        case .everything: "Mentions, direct messages and every message in your servers. Busy servers make this a lot."
        }
    }
}

enum DiscordNotifyRule {
    /// Whether a message gets a banner. Never for what this account wrote itself. (@everyone and role mentions do not count as mentions: they are not about you alone.)
    static func shouldNotify(_ message: DiscordMessage, me: String, kind: DiscordNotifyKind) -> Bool {
        guard message.author.id != me else { return false }
        switch kind {
        case .mentions: return message.mentions(me)
        case .direct: return message.isDirect
        case .everything: return true
        }
    }
}

/// Where a message came from, as the banner and the in-game menu show it.
struct DiscordConversation: Equatable, Identifiable {
    /// The channel's id (a direct message has one too).
    var id: String
    /// "#general", or the person's name for a direct message.
    var title: String
    /// The server's name; nil for a direct message.
    var place: String?
    var isDirect: Bool { place == nil }
}

/// What a banner says.
struct DiscordBanner: Equatable, Identifiable {
    var id = UUID()
    var conversation: DiscordConversation
    var author: DiscordUser
    var text: String
    /// How many messages this banner stands for (a second message of the same conversation joins its banner instead of making another).
    var count = 1

    var headline: String { conversation.isDirect ? author.displayName : "\(author.displayName) in \(conversation.title)" }
    var line: String { count > 1 ? "\(count) new messages" : text }
}

/// Banners waiting to be shown, one at a time. A conversation has at most one waiting banner (a newer message joins it), and only a few wait at all, so a busy channel cannot
/// build up a long string of banners over the game.
struct DiscordBannerQueue: Equatable {
    static let limit = 3
    private(set) var waiting: [DiscordBanner] = []

    mutating func push(_ banner: DiscordBanner) {
        if let i = waiting.firstIndex(where: { $0.conversation.id == banner.conversation.id }) {
            var merged = banner
            merged.count = waiting[i].count + banner.count
            waiting[i] = merged
        } else {
            waiting.append(banner)
            if waiting.count > Self.limit { waiting.removeFirst(waiting.count - Self.limit) }
        }
    }

    mutating func pop() -> DiscordBanner? { waiting.isEmpty ? nil : waiting.removeFirst() }
    mutating func clear() { waiting = [] }
    var isEmpty: Bool { waiting.isEmpty }
}
