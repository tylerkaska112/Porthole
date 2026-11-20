// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A direct message or group chat (Discord's "private channels"). Calls ring here; a server's voice channels never ring.
struct DiscordDirectChannel: Equatable, Identifiable {
    var id: String
    var isGroup: Bool
    /// The name somebody gave a group chat.
    var name: String?
    /// Who else is in it. Discord sometimes sends whole users and sometimes only their ids; the ids are looked up when a name is needed.
    var recipientIDs: [String]
    var users: [DiscordUser]
    /// The id of the latest message in it, which orders the conversations (newest first).
    var lastMessageID: String?

    /// A direct message (type 1) or a group chat (type 3); anything else is not one.
    static func parse(_ d: [String: Any]) -> DiscordDirectChannel? {
        guard let id = d["id"] as? String, let type = d["type"] as? Int, type == 1 || type == 3 else { return nil }
        let users = (d["recipients"] as? [[String: Any]] ?? []).compactMap { u -> DiscordUser? in
            guard let uid = u["id"] as? String, let name = u["username"] as? String else { return nil }
            return DiscordUser(id: uid, username: name, globalName: u["global_name"] as? String, avatar: u["avatar"] as? String, discriminator: u["discriminator"] as? String)
        }
        let ids = (d["recipient_ids"] as? [String]) ?? users.map(\.id)
        let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DiscordDirectChannel(id: id, isGroup: type == 3, name: name, recipientIDs: ids, users: users, lastMessageID: d["last_message_id"] as? String)
    }

    /// What to call it: a group's name, else the others' names ("Alex, Sam and 2 more"), else a plain word.
    func title(me: String?, nameOf: (String) -> String?) -> String {
        if let name { return name }
        let names = recipientIDs.filter { $0 != me }.compactMap { id in users.first { $0.id == id }?.displayName ?? nameOf(id) }
        switch names.count {
        case 0: return isGroup ? "Group chat" : "Direct message"
        case 1, 2: return names.joined(separator: " and ")
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// What Discord says about a call in a direct message or group chat (CALL_CREATE and CALL_UPDATE share the shape).
struct DiscordCallState: Equatable {
    var channelID: String
    /// Who it is ringing for.
    var ringing: [String]
    /// Who is in the call now.
    var inCall: [String]

    static func parse(_ d: [String: Any]) -> DiscordCallState? {
        guard let channel = d["channel_id"] as? String else { return nil }
        let inCall = (d["voice_states"] as? [[String: Any]] ?? []).compactMap { $0["user_id"] as? String }
        return DiscordCallState(channelID: channel, ringing: d["ringing"] as? [String] ?? [], inCall: inCall)
    }

    func rings(_ me: String) -> Bool { ringing.contains(me) }
}

/// A call that is ringing for this account.
struct DiscordIncomingCall: Equatable, Identifiable {
    var id: String { channelID }
    var channelID: String
    /// Who is calling, as it reads: "Alex", "Alex and Sam", or a group chat's name.
    var title: String
    /// Whose picture to show: the first person who is in the call.
    var caller: DiscordUser?
    var isGroup: Bool
    var since = Date()

    /// "Alex is calling"; a group is named under the "Group call" label ("Game night", "Alex, Sam and 2 more").
    var headline: String { isGroup ? title : "\(title) is calling" }
}
