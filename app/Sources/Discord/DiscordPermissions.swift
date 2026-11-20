// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What this account may do in a server's channels, worked out the way Discord documents it (permission bits, the roles this account has, and each channel's overwrites). The gateway sends
/// every channel of a server whether the account may open it or not; this decides which ones to show. Pure arithmetic and parsing, so it is tested without a network (Tests/DiscordPermissions).
enum DiscordPermissions {
    static let administrator: UInt64 = 1 << 3
    static let viewChannel: UInt64 = 1 << 10
    static let sendMessages: UInt64 = 1 << 11
    static let readMessageHistory: UInt64 = 1 << 16
    static let connect: UInt64 = 1 << 20
    static let all: UInt64 = ~0

    /// One rule on a channel: it applies to a role or to one member, and turns permissions on (`allow`) or off (`deny`).
    struct Overwrite: Equatable {
        var id: String
        var isMember: Bool
        var allow: UInt64
        var deny: UInt64
    }

    /// Who this account is in one server.
    struct Standing: Equatable {
        var guildID: String
        var ownerID: String?
        var me: String
        /// Every role of the server and the permission bits it grants (the role whose id is the server's id is @everyone).
        var roles: [String: UInt64]
        /// The roles this account has. Nil when it is not known: nothing can be hidden then.
        var myRoles: [String]?
    }

    /// Discord sends permission bits as a decimal string (they no longer fit a 32-bit number), sometimes as a number.
    static func parse(_ value: Any?) -> UInt64 {
        if let s = value as? String { return UInt64(s) ?? 0 }
        if let n = value as? UInt64 { return n }
        if let n = value as? Int { return n < 0 ? 0 : UInt64(n) }
        if let n = value as? NSNumber { return n.uint64Value }
        return 0
    }

    /// A channel's `permission_overwrites`. `type` is 0 for a role and 1 for a member (older replies spelled it out).
    static func overwrites(from list: Any?) -> [Overwrite] {
        (list as? [[String: Any]] ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            let member: Bool
            if let t = o["type"] as? Int { member = t == 1 } else if let t = o["type"] as? String { member = t == "member" || t == "1" } else { member = false }
            let allow = parse(o["allow_new"] ?? o["allow"]), deny = parse(o["deny_new"] ?? o["deny"])
            return Overwrite(id: id, isMember: member, allow: allow, deny: deny)
        }
    }

    /// The server-wide permissions: all of them for the owner, otherwise what @everyone and this account's roles grant together (and all of them for an administrator).
    static func base(_ s: Standing) -> UInt64 {
        if s.ownerID == s.me { return all }
        var bits = s.roles[s.guildID] ?? 0
        for role in s.myRoles ?? [] { bits |= s.roles[role] ?? 0 }
        return bits & administrator != 0 ? all : bits
    }

    /// The permissions in one channel: the server-wide ones, then @everyone's overwrite, then all of this account's roles' overwrites together, then its own overwrite. An overwrite takes
    /// away what it denies and then gives what it allows, so an allow wins over a deny of the same level.
    static func permissions(in overwrites: [Overwrite], _ s: Standing) -> UInt64 {
        var bits = base(s)
        if bits & administrator != 0 { return all }
        if let everyone = overwrites.first(where: { !$0.isMember && $0.id == s.guildID }) { bits &= ~everyone.deny; bits |= everyone.allow }
        var deny: UInt64 = 0, allow: UInt64 = 0
        for o in overwrites where !o.isMember && o.id != s.guildID && (s.myRoles ?? []).contains(o.id) { deny |= o.deny; allow |= o.allow }
        bits &= ~deny; bits |= allow
        if let mine = overwrites.first(where: { $0.isMember && $0.id == s.me }) { bits &= ~mine.deny; bits |= mine.allow }
        return bits
    }

    /// Whether a channel is shown. With no knowledge of this account's roles every channel is shown: hiding on a guess would hide channels it can open.
    static func canView(_ overwrites: [Overwrite], _ s: Standing) -> Bool {
        guard s.myRoles != nil || s.ownerID == s.me else { return true }
        return permissions(in: overwrites, s) & viewChannel != 0
    }

    // MARK: The order of servers

    /// The order of the servers in the account's own list. Discord keeps it in the user settings, as folders (each with the servers in it) in newer accounts, or as a plain list of ids.
    /// Servers the settings do not name come after, in the order they were sent.
    static func serverOrder(fromSettings settings: [String: Any]?) -> [String] {
        var order: [String] = []
        if let folders = settings?["guild_folders"] as? [[String: Any]] {
            for folder in folders { for id in folder["guild_ids"] as? [Any] ?? [] { if let s = (id as? String) ?? (id as? Int).map(String.init) { order.append(s) } } }
        }
        if order.isEmpty, let positions = settings?["guild_positions"] as? [Any] { order = positions.compactMap { ($0 as? String) ?? ($0 as? Int).map(String.init) } }
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }
    }

    static func sort<T>(_ items: [T], id: (T) -> String, by order: [String]) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
