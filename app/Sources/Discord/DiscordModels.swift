// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What Porthole tells Discord about itself. It says what it is, everywhere it can: an iOS app called Porthole. It does not copy the official app's identity.
enum DiscordIdentity {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var userAgent: String { "Porthole/\(version) (iOS; unofficial Discord client)" }
    /// The gateway's `properties`.
    static let gatewayProperties: [String: String] = ["os": "iOS", "browser": "Porthole", "device": "Porthole"]
}

struct DiscordUser: Codable, Equatable, Hashable {
    var id: String
    var username: String
    var globalName: String?
    var avatar: String?
    var discriminator: String?

    enum CodingKeys: String, CodingKey { case id, username, avatar, discriminator; case globalName = "global_name" }

    /// The name people see: the display name, else the user name.
    var displayName: String { (globalName?.isEmpty == false ? globalName : nil) ?? username }
}

extension DiscordUser {
    /// Discord's picture for this person (nil when they have none; the screens then draw their initial).
    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png?size=64")
    }
}

/// Someone in the voice call this account is in.
struct CallMember: Identifiable, Equatable {
    var id: String
    var name: String
    var avatarURL: URL?
    var speaking: Bool
    var isSelf: Bool
    /// They are sharing their screen or game with Go Live (Discord says so in their voice state).
    var streaming = false
}

/// A voice channel somebody is in: where "join their call" goes.
struct FriendCall: Equatable {
    var guild: DiscordGuild
    var channel: DiscordGuild.Channel
    /// "Lounge, Porthole Testers".
    var label: String { "\(channel.name), \(guild.name)" }

    /// The call a person is in, from who the servers say is in each voice channel. nil when they are in none, or in one of a server this account cannot see.
    static func of(person id: String, roster: [String: [CallMember]], guilds: [DiscordGuild]) -> FriendCall? {
        for (channelID, members) in roster where members.contains(where: { $0.id == id }) {
            for guild in guilds { if let channel = guild.channel(channelID), channel.isVoice { return FriendCall(guild: guild, channel: channel) } }
        }
        return nil
    }
}

enum DiscordStatus: String, Codable, Equatable {
    case online, idle, dnd, offline, invisible
    init(raw: String?) { self = DiscordStatus(rawValue: raw ?? "offline") ?? .offline }
    var title: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do not disturb"
        case .offline, .invisible: "Offline"
        }
    }
    var isOnline: Bool { self == .online || self == .idle || self == .dnd }
}

struct DiscordFriend: Identifiable, Equatable {
    var user: DiscordUser
    var status: DiscordStatus = .offline
    /// What they are playing or doing, as one line ("Playing Terraria").
    var activity: String?
    var id: String { user.id }
}

/// The parts of Discord's READY message this client reads. Everything else in it is ignored.
struct DiscordReady: Decodable {
    struct Relationship: Decodable {
        var id: String
        var type: Int
        var user: DiscordUser?
    }
    struct Presence: Decodable {
        struct Who: Decodable { var id: String }
        struct Activity: Decodable { var name: String?; var type: Int? }
        var user: Who?
        var status: String?
        var activities: [Activity]?
    }
    var user: DiscordUser
    var relationships: [Relationship]?
    var presences: [Presence]?
    var sessionID: String?

    enum CodingKeys: String, CodingKey { case user, relationships, presences; case sessionID = "session_id" }

    /// Friends only (relationship type 1), with the presence that came with READY.
    var friends: [DiscordFriend] {
        let byID = Dictionary((presences ?? []).compactMap { p in p.user.map { ($0.id, p) } }, uniquingKeysWith: { a, _ in a })
        return (relationships ?? []).filter { $0.type == 1 }.compactMap { rel -> DiscordFriend? in
            guard let user = rel.user else { return nil }
            var friend = DiscordFriend(user: user)
            if let p = byID[rel.id] { friend.status = DiscordStatus(raw: p.status); friend.activity = Self.line(p.activities) }
            return friend
        }
    }

    static func line(_ activities: [Presence.Activity]?) -> String? {
        guard let a = activities?.first(where: { ($0.type ?? 0) != 4 }), let name = a.name, !name.isEmpty else { return nil }
        switch a.type ?? 0 {
        case 0: return "Playing \(name)"
        case 1: return "Streaming \(name)"
        case 2: return "Listening to \(name)"
        case 3: return "Watching \(name)"
        default: return name
        }
    }
}

/// A server (Discord calls it a guild) with the channels the account can see in it: the text and voice channels, grouped by the categories the server made.
struct DiscordGuild: Identifiable, Equatable {
    struct Channel: Identifiable, Equatable {
        /// The kinds of channel the screens show (Discord's numbers).
        enum Kind: Int { case text = 0, voice = 2, category = 4, announcement = 5, announcementThread = 10, publicThread = 11, privateThread = 12, stage = 13, forum = 15, media = 16 }
        var id: String
        var name: String
        var kind: Kind = .voice
        var parentID: String?
        var position = 0
        var topic: String?
        /// The rules that allow or deny people in this channel (what decides whether this account may open it).
        var overwrites: [DiscordPermissions.Overwrite] = []
        /// A forum's tags (id -> name), which its posts carry.
        var tags: [String: String] = [:]

        var isVoice: Bool { kind == .voice || kind == .stage }
        /// A thread: a conversation under a message or a forum post. It is a channel of its own, listed under the channel it belongs to.
        var isThread: Bool { kind == .announcementThread || kind == .publicThread || kind == .privateThread }
        /// A forum or media channel: a list of posts, each a thread.
        var isForum: Bool { kind == .forum || kind == .media }
        var isCategory: Bool { kind == .category }
        /// A channel of words (text, announcements, a forum, media): something that is read, not joined.
        var isTextual: Bool { !isVoice && !isCategory }
        /// Channels whose messages Porthole reads: text and announcement channels (a forum or media channel is a list of threads).
        var readsMessages: Bool { kind == .text || kind == .announcement || isThread }
        var symbol: String {
            switch kind {
            case .text: "number"
            case .announcement: "megaphone.fill"
            case .voice: "speaker.wave.2.fill"
            case .stage: "person.2.wave.2.fill"
            case .forum: "text.bubble.fill"
            case .media: "photo.on.rectangle.angled"
            case .announcementThread, .publicThread, .privateThread: "bubble.left.and.bubble.right"
            case .category: "chevron.down"
            }
        }
        var kindTitle: String {
            switch kind {
            case .text: "Text channel"
            case .announcement: "Announcement channel"
            case .voice: "Voice channel"
            case .stage: "Stage channel"
            case .forum: "Forum"
            case .media: "Media channel"
            case .announcementThread, .publicThread, .privateThread: "Thread"
            case .category: "Category"
            }
        }
    }

    /// One category of the channel list, with its channels in the order Discord shows them. `category` is nil for the channels that sit above every category.
    struct Section: Identifiable, Equatable {
        var category: Channel?
        var channels: [Channel]
        var id: String { category?.id ?? "top" }
    }

    var id: String
    var name: String
    var icon: String?
    var channels: [Channel] = []
    /// Who owns the server, the permission bits of each of its roles, and the roles this account has (nil when Discord did not say: no channel is hidden then).
    var ownerID: String?
    var roles: [String: UInt64] = [:]
    var myRoles: [String]?

    init(id: String, name: String, icon: String? = nil, channels: [Channel] = []) {
        self.id = id; self.name = name; self.icon = icon; self.channels = channels
    }

    /// The server as this account sees it: the channels it may not open are left out. A category stays (a category with nothing left in it is not listed by `sections`).
    func visible(for me: String) -> DiscordGuild {
        // Without the server's role list (or its @everyone role) nothing can be worked out: every channel stays, rather than none.
        guard roles[id] != nil else { return self }
        let standing = DiscordPermissions.Standing(guildID: id, ownerID: ownerID, me: me, roles: roles, myRoles: myRoles)
        var copy = self
        var shown = channels.filter { $0.isCategory || $0.isThread || DiscordPermissions.canView($0.overwrites, standing) }
        // A thread can be opened when its channel can (it has no rules of its own).
        let open = Set(shown.map(\.id))
        shown.removeAll { $0.isThread && !open.contains($0.parentID ?? "") }
        // A server that would be left with nothing to open is more likely a gap in what Discord sent than a server this account cannot use at all: it keeps its channels.
        guard shown.contains(where: { !$0.isCategory }) || !channels.contains(where: { !$0.isCategory }) else { return self }
        copy.channels = shown
        return copy
    }

    /// The open threads under a text or announcement channel, the newest first. (A forum's posts are shown in the forum itself, not here.)
    func threads(of parent: String) -> [Channel] {
        guard let p = channel(parent), !p.isForum else { return [] }
        return channels.filter { $0.isThread && $0.parentID == parent }.sorted { $0.id.count != $1.id.count ? $0.id.count > $1.id.count : $0.id > $1.id }
    }

    /// The voice (and stage) channels, which is what a call can join.
    var voiceChannels: [Channel] { channels.filter(\.isVoice) }
    func channel(_ id: String) -> Channel? { channels.first { $0.id == id } }

    var iconURL: URL? {
        guard let icon, !icon.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).png?size=96")
    }

    /// Up to two letters for a server without a picture: the first letters of its first words.
    var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    /// Discord's order: the channels that sit above every category first, then each category by position; inside one, words before voice, then by position. A category with nothing
    /// in it is left out.
    var sections: [Section] {
        func ordered(_ list: [Channel]) -> [Channel] {
            list.sorted { a, b in
                if a.isVoice != b.isVoice { return !a.isVoice }
                if a.position != b.position { return a.position < b.position }
                return a.id < b.id
            }
        }
        let categories = channels.filter(\.isCategory).sorted { $0.position != $1.position ? $0.position < $1.position : $0.id < $1.id }
        let categoryIDs = Set(categories.map(\.id))
        var result: [Section] = []
        let top = ordered(channels.filter { !$0.isCategory && !$0.isThread && ($0.parentID == nil || !categoryIDs.contains($0.parentID!)) })
        if !top.isEmpty { result.append(Section(category: nil, channels: top)) }
        for category in categories {
            let inside = ordered(channels.filter { !$0.isCategory && !$0.isThread && $0.parentID == category.id })
            if !inside.isEmpty { result.append(Section(category: category, channels: inside)) }
        }
        return result
    }
}
