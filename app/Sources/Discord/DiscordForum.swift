// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// One post of a forum (or media) channel. Discord makes every post a thread: a channel of its own whose messages are the conversation under the post, and whose first message is the
/// post itself. Read from the reply of the thread search (`threads` and `first_messages`) or the list of active threads.
struct DiscordForumPost: Identifiable, Equatable {
    var id: String
    var title: String
    var ownerID: String?
    var ownerName: String?
    /// Replies, not counting the post's first message.
    var replies: Int
    /// When anything was last said in it (the time in the id of its latest message, else of the post).
    var lastActivity: Date?
    var tags: [String]
    /// The start of the post's first message.
    var preview: String
    /// The first picture in it (a media channel is made of these).
    var thumbnail: URL?
    var pinned: Bool
    var locked: Bool
    var archived: Bool

    /// `tagNames` maps the forum's tag ids to their names. `first` is the post's first message when Discord sent it.
    static func parse(thread t: [String: Any], first: [String: Any]?, tagNames: [String: String] = [:]) -> DiscordForumPost? {
        guard let id = t["id"] as? String else { return nil }
        let meta = t["thread_metadata"] as? [String: Any]
        let owner = ((first?["author"] as? [String: Any]).flatMap { $0["id"] as? String }) ?? (t["owner_id"] as? String)
        let ownerName = (first?["author"] as? [String: Any]).flatMap { ($0["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ($0["username"] as? String) }
        let tags = (t["applied_tags"] as? [Any] ?? []).compactMap { ($0 as? String) ?? ($0 as? Int).map(String.init) }.compactMap { tagNames[$0] }
        let content = ((first?["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var thumb: URL?
        for a in first?["attachments"] as? [[String: Any]] ?? [] {
            let type = (a["content_type"] as? String) ?? ""
            let name = (a["filename"] as? String) ?? ""
            let image = type.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp"].contains((name as NSString).pathExtension.lowercased())
            if image, let url = (a["proxy_url"] as? String ?? a["url"] as? String).flatMap(URL.init(string:)) { thumb = url; break }
        }
        let flags = t["flags"] as? Int ?? 0
        let sent = (t["total_message_sent"] as? Int) ?? (t["message_count"] as? Int) ?? 0
        return DiscordForumPost(id: id, title: (t["name"] as? String) ?? "Post", ownerID: owner, ownerName: ownerName, replies: max(0, sent - 1),
                                lastActivity: DiscordSnowflake.date((t["last_message_id"] as? String) ?? id), tags: tags, preview: String(content.prefix(220)), thumbnail: thumb,
                                pinned: flags & 2 != 0, locked: (meta?["locked"] as? Bool) == true, archived: (meta?["archived"] as? Bool) == true)
    }

    /// The posts of a thread search reply: pinned first, then the most recently active.
    static func posts(fromSearch reply: [String: Any], tagNames: [String: String]) -> [DiscordForumPost] {
        let firsts = Dictionary((reply["first_messages"] as? [[String: Any]] ?? []).compactMap { m in (m["channel_id"] as? String).map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        return order((reply["threads"] as? [[String: Any]] ?? []).compactMap { t in
            (t["id"] as? String).flatMap { parse(thread: t, first: firsts[$0], tagNames: tagNames) }
        })
    }

    /// The posts of a forum from a list of threads (the active threads of a whole server): only the ones whose parent is this forum.
    static func posts(fromThreads list: [[String: Any]], forum: String, tagNames: [String: String]) -> [DiscordForumPost] {
        order(list.filter { ($0["parent_id"] as? String) == forum }.compactMap { parse(thread: $0, first: nil, tagNames: tagNames) })
    }

    static func order(_ posts: [DiscordForumPost]) -> [DiscordForumPost] {
        posts.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let da = a.lastActivity ?? .distantPast, db = b.lastActivity ?? .distantPast
            return da != db ? da > db : a.id > b.id
        }
    }
}
