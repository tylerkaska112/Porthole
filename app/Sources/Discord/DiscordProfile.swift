// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What Discord shows on a person's profile card: their name, a short text about them, how long they have had the account and which servers (and how many friends) you share. Read from
/// Discord's profile reply when a person opened the card; every field is optional because Discord leaves out what the person did not fill in or what this account may not see.
struct DiscordProfile: Equatable {
    var user: DiscordUser
    var bio: String
    var pronouns: String
    var bannerURL: URL?
    /// The colour the person chose for their card, as 0xRRGGBB.
    var accent: UInt32?
    var mutualServerIDs: [String]
    var mutualFriendCount: Int
    var createdAt: Date?

    /// Reads Discord's `GET /users/<id>/profile` reply (`user`, `user_profile`, `mutual_guilds`, `mutual_friends_count`). Returns nil when there is no user in it.
    static func parse(_ d: [String: Any]) -> DiscordProfile? {
        guard let u = d["user"] as? [String: Any], let id = u["id"] as? String, let name = u["username"] as? String else { return nil }
        let user = DiscordUser(id: id, username: name, globalName: u["global_name"] as? String, avatar: u["avatar"] as? String, discriminator: u["discriminator"] as? String)
        let profile = d["user_profile"] as? [String: Any]
        let bio = ((profile?["bio"] as? String) ?? (u["bio"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pronouns = ((profile?["pronouns"] as? String) ?? (u["pronouns"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var banner: URL?
        if let hash = u["banner"] as? String, !hash.isEmpty { banner = URL(string: "https://cdn.discordapp.com/banners/\(id)/\(hash).png?size=480") }
        let accent = (u["accent_color"] as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? (profile?["accent_color"] as? Int).map { UInt32(truncatingIfNeeded: $0) }
        let mutual = (d["mutual_guilds"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return DiscordProfile(user: user, bio: bio, pronouns: pronouns, bannerURL: banner, accent: accent, mutualServerIDs: mutual,
                              mutualFriendCount: d["mutual_friends_count"] as? Int ?? 0, createdAt: DiscordSnowflake.date(id))
    }
}

/// Discord ids ("snowflakes") carry the time they were made: the milliseconds since the start of 2015 are in the bits above the lowest 22.
enum DiscordSnowflake {
    static let epochMilliseconds: UInt64 = 1_420_070_400_000

    static func date(_ id: String) -> Date? {
        guard let n = UInt64(id), n > 0 else { return nil }
        return Date(timeIntervalSince1970: Double((n >> 22) + epochMilliseconds) / 1000)
    }

    /// Whether `a` was made after `b` (ids compared as numbers: a longer id is later). Used to order conversations by their latest message.
    static func isLater(_ a: String?, than b: String?) -> Bool {
        switch (a.flatMap { UInt64($0) }, b.flatMap { UInt64($0) }) {
        case let (x?, y?): return x > y
        case (_?, nil): return true
        default: return false
        }
    }
}
