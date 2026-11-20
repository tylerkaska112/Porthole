// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A connection to Discord's gateway for one signed-in account: it says who this is (identify), keeps the connection alive (heartbeat), and passes on what the account's
/// friends and presence look like. It reads only what the screens need and ignores the rest of Discord's very large messages. The token is never logged.
@MainActor
final class DiscordGateway {
    enum Event {
        case ready(DiscordReady)
        case presence(userID: String, status: DiscordStatus, activity: String?)
        case friendAdded(DiscordUser)
        case friendRemoved(String)
        case guilds([DiscordGuild])
        /// Somebody started or stopped streaming (Go Live) in a voice channel.
        case streaming(userID: String, on: Bool)
        /// Somebody added or took away an emoji under a message.
        case reaction(channelID: String, messageID: String, userID: String, emoji: (name: String, id: String?, animated: Bool), add: Bool)
        /// All the emoji under a message were cleared, or all the votes for one of them (`emojiKey`).
        case reactionsCleared(channelID: String, messageID: String, emojiKey: String?)
        /// Somebody started typing in a channel or conversation.
        case typing(channelID: String, userID: String, user: DiscordUser?)
        /// A thread was made or changed (nil name: it was deleted) in a server.
        case thread(guildID: String, channel: DiscordGuild.Channel?, deletedID: String?)
        /// The order of the servers in this account's own list (empty when Discord did not send it).
        case guildOrder([String])
        /// This account's own voice state changed: the session id Discord wants for the voice connection, and the channel (nil = left).
        case ownVoiceState(userID: String, sessionID: String, guildID: String?, channelID: String?)
        case voiceServer(guildID: String, token: String, endpoint: String?)
        /// A stream (Go Live) of this account was created: its key and the stream server's id.
        case streamCreate(key: String, rtcServerID: String)
        /// Where the stream's own voice connection goes.
        case streamServer(key: String, endpoint: String, token: String)
        /// Discord ended the stream (or refused to start it).
        case streamDelete(key: String, reason: String)
        /// Someone's voice state changed (anyone in a server this account is in): the channel they are in now (nil = none), and who they are when Discord said.
        case voiceState(userID: String, channelID: String?, user: DiscordUser?)
        /// Who is in which voice channel of a server when the server was loaded.
        case voiceStates(states: [(userID: String, channelID: String?)], users: [DiscordUser])
        /// The direct messages and group chats of this account (from the loading message, and when a new one is made).
        case directChannels([DiscordDirectChannel])
        /// A call in a direct message or group chat started or changed (who it rings for, who is in it), or ended.
        case call(DiscordCallState)
        case callEnded(channelID: String)
        /// A message in a text channel (the raw JSON: the session knows the names needed to make it readable).
        case messageCreate([String: Any])
        case messageUpdate([String: Any])
        case messageDelete(channelID: String, id: String)
        /// The connection ended. `authFailed`: Discord said the token is no good (sign in again).
        case disconnected(authFailed: Bool, code: Int)
    }

    var onEvent: ((Event) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var sequence: Int?
    private var acknowledged = true
    private var stopped = false
    /// Every connect starts a new generation; an older connection's loop that is still winding down must not touch the new one.
    private var generation = 0
    /// When the last message arrived (the screens use it to tell a connection that went stale while the app was in the background).
    private(set) var lastMessage = Date()
    private var messages = 0, acks = 0
    /// For the log: how alive this connection is.
    var summary: String { "\(messages) message(s) since it connected, \(acks) heartbeat answer(s), last one \(Int(Date().timeIntervalSince(lastMessage))) s ago" }

    func connect(token: String) {
        generation += 1
        let mine = generation
        task?.cancel(with: .goingAway, reason: nil)
        heartbeat?.cancel()
        sequence = nil
        messages = 0; acks = 0
        lastMessage = Date()
        stopped = false
        var request = URLRequest(url: URL(string: "wss://gateway.discord.gg/?v=9&encoding=json")!)
        request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20     // READY of an account in many servers is large
        self.task = task
        task.resume()
        Task { await receiveLoop(task, token: token, generation: mine) }
    }

    func disconnect() {
        generation += 1
        stopped = true
        heartbeat?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// The app is being closed (force-closed from the app switcher, or ended by iOS): say goodbye properly, because a connection that just vanishes is kept by Discord for a while (the
    /// account stays online, and a voice call or a stream stays up). Ends the stream, leaves the voice channel, shows invisible, waits a moment for the messages to leave, and closes the
    /// connection with a normal close, which makes Discord end the session at once. Blocks for at most `wait` seconds.
    func goodbye(streamKey: String?, leaveVoice: Bool, wait: TimeInterval = 1.0) {
        guard let task else { return }
        var messages: [[String: Any]] = []
        if let streamKey { messages.append(["op": 19, "d": ["stream_key": streamKey]]) }
        if leaveVoice { messages.append(["op": 4, "d": ["guild_id": NSNull(), "channel_id": NSNull(), "self_mute": selfMute, "self_deaf": selfDeaf] as [String: Any]]) }
        messages.append(["op": 3, "d": ["status": "invisible", "since": 0, "activities": [], "afk": false] as [String: Any]])
        let done = DispatchSemaphore(value: 0)
        for (i, object) in messages.enumerated() {
            guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { continue }
            let last = i == messages.count - 1
            task.send(.string(text)) { _ in if last { done.signal() } }
        }
        let sent = done.wait(timeout: .now() + wait) == .success
        LogStore.shared.log("[discord] goodbye: \(messages.count) message(s) \(sent ? "sent" : "not confirmed in time"), closing the connection")
        generation += 1
        stopped = true
        heartbeat?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        Thread.sleep(forTimeInterval: 0.2)        // the close message has to leave before the process ends
        self.task = nil
    }

    /// What this account tells Discord about its own microphone and hearing (other people see the crossed-out icons).
    var selfMute = false
    var selfDeaf = false

    /// Join (or leave, with a nil channel) a voice channel of a server. Asking again for the channel this account is already in only changes the mute and deafen flags.
    func setVoiceChannel(guildID: String?, channelID: String?) {
        send(["op": 4, "d": ["guild_id": guildID as Any? ?? NSNull(), "channel_id": channelID as Any? ?? NSNull(), "self_mute": selfMute, "self_deaf": selfDeaf] as [String: Any]])
    }

    /// The activity to show ("Playing <game>"), kept so a new connection starts with it. Nil: none.
    private(set) var activity: [String: Any]?

    /// Changes the activity: remembered for the next connection, and sent now when connected.
    func setActivity(_ new: [String: Any]?) {
        activity = new
        send(["op": 3, "d": DiscordActivity.presence(activity: new)])
    }

    /// What this account's id is, once known: it is how its roles are found in a server's member list.
    private var myID: String?

    static func guild(from d: [String: Any], myID: String? = nil, mergedRoles: [String]? = nil) -> DiscordGuild? {
        guard let id = d["id"] as? String, (d["unavailable"] as? Bool) != true else { return nil }
        let properties = d["properties"] as? [String: Any]
        let name = (d["name"] as? String) ?? (properties?["name"] as? String) ?? "Server"
        let icon = (d["icon"] as? String) ?? (properties?["icon"] as? String)
        let channels = (d["channels"] as? [[String: Any]] ?? []).compactMap { c -> DiscordGuild.Channel? in
            guard let number = c["type"] as? Int, let kind = DiscordGuild.Channel.Kind(rawValue: number), let cid = c["id"] as? String else { return nil }
            let fallback = kind == .voice || kind == .stage ? "Voice" : "channel"
            return DiscordGuild.Channel(id: cid, name: c["name"] as? String ?? fallback, kind: kind, parentID: c["parent_id"] as? String,
                                        position: c["position"] as? Int ?? 0, topic: (c["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                        overwrites: DiscordPermissions.overwrites(from: c["permission_overwrites"]), tags: tags(of: c))
        }
        var guild = DiscordGuild(id: id, name: name, icon: icon, channels: channels + (d["threads"] as? [[String: Any]] ?? []).compactMap(thread(from:)))
        guild.ownerID = (d["owner_id"] as? String) ?? (properties?["owner_id"] as? String)
        for role in d["roles"] as? [[String: Any]] ?? [] { if let rid = role["id"] as? String { guild.roles[rid] = DiscordPermissions.parse(role["permissions_new"] ?? role["permissions"]) } }
        // This account's roles: the member record of the loading message (READY's merged_members), or its own entry in the server's member list.
        if let mergedRoles { guild.myRoles = mergedRoles }
        else if let myID, let mine = (d["members"] as? [[String: Any]])?.first(where: { (($0["user"] as? [String: Any])?["id"] as? String) == myID }) {
            guild.myRoles = mine["roles"] as? [String] ?? []
        }
        return guild
    }

    /// A forum's tags: id -> name.
    private static func tags(of channel: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for t in channel["available_tags"] as? [[String: Any]] ?? [] { if let id = t["id"] as? String, let name = t["name"] as? String { result[id] = name } }
        return result
    }

    /// An open thread as a channel (an archived one is not listed: it is read from its forum or found by search).
    static func thread(from t: [String: Any]) -> DiscordGuild.Channel? {
        guard let number = t["type"] as? Int, let kind = DiscordGuild.Channel.Kind(rawValue: number), kind == .announcementThread || kind == .publicThread || kind == .privateThread,
              let id = t["id"] as? String, let parent = t["parent_id"] as? String else { return nil }
        if ((t["thread_metadata"] as? [String: Any])?["archived"] as? Bool) == true { return nil }
        return DiscordGuild.Channel(id: id, name: (t["name"] as? String) ?? "thread", kind: kind, parentID: parent)
    }

    /// This account's roles in each server of the loading message, by the server's position in it (`merged_members` is a list per server).
    private func mergedRoles(in d: [String: Any], index: Int) -> [String]? {
        guard let me = myID, let all = d["merged_members"] as? [[[String: Any]]], index < all.count else { return nil }
        guard let mine = all[index].first(where: { ($0["user_id"] as? String) == me || (($0["user"] as? [String: Any])?["id"] as? String) == me }) else { return nil }
        return mine["roles"] as? [String] ?? []
    }

    /// Go Live: start a stream in a voice channel, or end it.
    func startStream(guildID: String, channelID: String, key: String) {
        LogStore.shared.log("[discord-stream] asking Discord to start a stream")
        send(["op": 18, "d": ["type": "guild", "guild_id": guildID, "channel_id": channelID, "preferred_region": NSNull()] as [String: Any]])
        send(["op": 22, "d": ["stream_key": key, "paused": false] as [String: Any]])
    }

    /// Watch somebody's Go Live. Discord answers with the stream's server and token (STREAM_CREATE, STREAM_SERVER_UPDATE).
    func watchStream(key: String) {
        LogStore.shared.log("[discord-watch] asking Discord to let this account watch a stream")
        send(["op": 20, "d": ["stream_key": key]])
    }

    func stopStream(key: String) {
        LogStore.shared.log("[discord-stream] asking Discord to end the stream")
        send(["op": 19, "d": ["stream_key": key]])
    }

    private func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else {
            if (object["op"] as? Int) == 4 { LogStore.shared.log("[discord-voice] the join request could not be sent: no open connection to Discord") }
            return
        }
        let op = object["op"] as? Int
        task.send(.string(text)) { error in
            if op == 4 { LogStore.shared.log(error == nil ? "[discord-voice] join request sent to Discord" : "[discord-voice] join request failed to send: \(error!.localizedDescription)") }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, token: String, generation mine: Int) async {
        while !stopped, mine == generation {
            do {
                let message = try await task.receive()
                guard mine == generation else { return }
                lastMessage = Date()
                messages += 1
                switch message {
                case .string(let text): handle(text, token: token)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { handle(text, token: token) }
                @unknown default: break
                }
            } catch {
                if stopped || mine != generation { return }
                let code = task.closeCode.rawValue
                heartbeat?.cancel()
                self.task = nil
                // 4004: authentication failed. Anything else is a dropped connection.
                onEvent?(.disconnected(authFailed: code == 4004, code: code))
                return
            }
        }
    }

    private func handle(_ text: String, token: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let op = object["op"] as? Int else { return }
        if let s = object["s"] as? Int { sequence = s }
        switch op {
        case 10:   // hello
            let interval = ((object["d"] as? [String: Any])?["heartbeat_interval"] as? Double ?? 41250) / 1000
            startHeartbeat(interval: interval)
            send(["op": 2, "d": [
                "token": token,
                "properties": DiscordIdentity.gatewayProperties,
                "presence": DiscordActivity.presence(activity: activity),
                "compress": false,
            ] as [String: Any]])
        case 11: acknowledged = true; acks += 1
        case 1: send(["op": 1, "d": sequence as Any? ?? NSNull()])
        case 7, 9:   // reconnect / invalid session: start over from the caller
            LogStore.shared.log("[discord] Discord asked for a new connection (op \(op))")
            heartbeat?.cancel()
            task?.cancel(with: .goingAway, reason: nil)
        case 0: dispatch(object["t"] as? String, object["d"])
        default: break
        }
    }

    private func startHeartbeat(interval: Double) {
        heartbeat?.cancel()
        acknowledged = true
        heartbeat = Task { [weak self] in
            // The first beat comes after a random part of the interval, as the gateway's documentation asks.
            try? await Task.sleep(nanoseconds: UInt64(interval * Double.random(in: 0.2...1) * 1_000_000_000))
            while !Task.isCancelled {
                let alive: Bool = await MainActor.run {
                    guard let self else { return false }
                    if !self.acknowledged {
                        LogStore.shared.log("[discord] Discord did not answer the last heartbeat: the connection is dead (\(self.summary))")
                        self.task?.cancel(with: .goingAway, reason: nil); return false
                    }
                    self.acknowledged = false
                    self.send(["op": 1, "d": self.sequence as Any? ?? NSNull()])
                    return true
                }
                if !alive { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private static func user(from object: Any?) -> DiscordUser? {
        guard let object, let json = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(DiscordUser.self, from: json)
    }

    /// Who is in a server's voice channels (its loading message lists them), with the names of the members it came with.
    private func emitVoiceStates(of guild: [String: Any]) {
        let states = (guild["voice_states"] as? [[String: Any]] ?? []).compactMap { v -> (userID: String, channelID: String?)? in
            guard let id = v["user_id"] as? String else { return nil }
            return (id, v["channel_id"] as? String)
        }
        for v in guild["voice_states"] as? [[String: Any]] ?? [] { if let id = v["user_id"] as? String, (v["self_stream"] as? Bool) == true { onEvent?(.streaming(userID: id, on: true)) } }
        guard !states.isEmpty else { return }
        let ids = Set(states.map(\.userID))
        var users: [DiscordUser] = []
        for v in guild["voice_states"] as? [[String: Any]] ?? [] { if let u = Self.user(from: (v["member"] as? [String: Any])?["user"]) { users.append(u) } }
        for m in guild["members"] as? [[String: Any]] ?? [] { if let u = Self.user(from: m["user"]), ids.contains(u.id) { users.append(u) } }
        onEvent?(.voiceStates(states: states, users: users))
    }

    private func dispatch(_ type: String?, _ data: Any?) {
        guard let type, let data else { return }
        switch type {
        case "READY":
            guard let json = try? JSONSerialization.data(withJSONObject: data), let ready = try? JSONDecoder().decode(DiscordReady.self, from: json) else {
                LogStore.shared.log("[discord] READY arrived but this version could not read it")
                return
            }
            myID = ready.user.id
            onEvent?(.ready(ready))
            if let d = data as? [String: Any] {
                let order = DiscordPermissions.serverOrder(fromSettings: d["user_settings"] as? [String: Any])
                LogStore.shared.log("[discord] server order: \(order.isEmpty ? "not sent (sorted by name)" : "\(order.count) in the account's own order")")
                if !order.isEmpty { onEvent?(.guildOrder(order)) }
            }
            if let d = data as? [String: Any], let list = d["guilds"] as? [[String: Any]] {
                let guilds = list.enumerated().compactMap { Self.guild(from: $1, myID: myID, mergedRoles: mergedRoles(in: d, index: $0)) }.filter { !$0.channels.isEmpty }
                LogStore.shared.log("[discord] \(guilds.count) server(s); roles known for \(guilds.filter { $0.myRoles != nil }.count) of them")
                onEvent?(.guilds(guilds))
                for g in list { emitVoiceStates(of: g) }
            }
            if let d = data as? [String: Any], let list = d["private_channels"] as? [[String: Any]] {
                let direct = list.compactMap(DiscordDirectChannel.parse)
                if !direct.isEmpty { onEvent?(.directChannels(direct)) }
            }
        case "GUILD_CREATE":
            if let d = data as? [String: Any], let g = Self.guild(from: d, myID: myID), !g.channels.isEmpty { onEvent?(.guilds([g])) }
            if let d = data as? [String: Any] { emitVoiceStates(of: d) }
        case "THREAD_CREATE", "THREAD_UPDATE":
            if let d = data as? [String: Any], let guild = d["guild_id"] as? String, let id = d["id"] as? String {
                // An archived or locked-away thread leaves the list; an open one joins it.
                onEvent?(.thread(guildID: guild, channel: Self.thread(from: d), deletedID: Self.thread(from: d) == nil ? id : nil))
            }
        case "THREAD_DELETE":
            if let d = data as? [String: Any], let guild = d["guild_id"] as? String, let id = d["id"] as? String { onEvent?(.thread(guildID: guild, channel: nil, deletedID: id)) }
        case "VOICE_STATE_UPDATE":
            if let d = data as? [String: Any], let who = d["user_id"] as? String {
                onEvent?(.streaming(userID: who, on: d["channel_id"] is String && (d["self_stream"] as? Bool) == true))
                onEvent?(.voiceState(userID: who, channelID: d["channel_id"] as? String, user: Self.user(from: (d["member"] as? [String: Any])?["user"])))
            }
            if let d = data as? [String: Any], let user = d["user_id"] as? String, let session = d["session_id"] as? String {
                if d["guild_id"] != nil { LogStore.shared.log("[discord-voice] voice state update, channel \((d["channel_id"] as? String) == nil ? "none" : "set")") }
                onEvent?(.ownVoiceState(userID: user, sessionID: session, guildID: d["guild_id"] as? String, channelID: d["channel_id"] as? String))
            }
        case "CHANNEL_CREATE":
            if let d = data as? [String: Any], let channel = DiscordDirectChannel.parse(d) { onEvent?(.directChannels([channel])) }
        case "CALL_CREATE", "CALL_UPDATE":
            if let d = data as? [String: Any], let call = DiscordCallState.parse(d) { onEvent?(.call(call)) }
        case "CALL_DELETE":
            if let d = data as? [String: Any], let channel = d["channel_id"] as? String { onEvent?(.callEnded(channelID: channel)) }
        case "VOICE_SERVER_UPDATE":
            // A server's voice update names its server; a direct message's or group chat's call names the channel instead (which stands in for the server).
            if let d = data as? [String: Any], let guild = (d["guild_id"] as? String) ?? (d["channel_id"] as? String), let token = d["token"] as? String {
                LogStore.shared.log("[discord-voice] voice server update, endpoint \((d["endpoint"] as? String) == nil ? "none yet" : "given")")
                onEvent?(.voiceServer(guildID: guild, token: token, endpoint: d["endpoint"] as? String))
            }
        case "STREAM_CREATE":
            if let d = data as? [String: Any], let key = d["stream_key"] as? String {
                LogStore.shared.log("[discord-stream] stream created, fields: \(d.keys.sorted().joined(separator: ",")); paused \(d["paused"] ?? "?"), viewers \((d["viewer_ids"] as? [Any])?.count ?? -1), region \(d["region"] ?? "?")")
                let rtc = (d["rtc_server_id"] as? String) ?? (d["rtc_server_id"] as? Int).map(String.init) ?? ""
                onEvent?(.streamCreate(key: key, rtcServerID: rtc))
            }
        case "STREAM_SERVER_UPDATE":
            if let d = data as? [String: Any], let key = d["stream_key"] as? String, let endpoint = d["endpoint"] as? String, let token = d["token"] as? String {
                LogStore.shared.log("[discord-stream] stream server given, fields: \(d.keys.sorted().filter { $0 != "token" }.joined(separator: ","))")
                onEvent?(.streamServer(key: key, endpoint: endpoint, token: token))
            }
        case "STREAM_DELETE":
            if let d = data as? [String: Any], let key = d["stream_key"] as? String {
                onEvent?(.streamDelete(key: key, reason: (d["reason"] as? String) ?? "no reason given"))
            }
        case "STREAM_UPDATE":
            let d = data as? [String: Any]
            LogStore.shared.log("[discord-stream] stream update: paused \(d?["paused"] ?? "?"), viewers \((d?["viewer_ids"] as? [Any])?.count ?? -1)")
        case "PRESENCE_UPDATE":
            guard let d = data as? [String: Any], let user = d["user"] as? [String: Any], let id = user["id"] as? String else { return }
            var activity: String?
            if let list = d["activities"] as? [[String: Any]], let json = try? JSONSerialization.data(withJSONObject: list),
               let activities = try? JSONDecoder().decode([DiscordReady.Presence.Activity].self, from: json) { activity = DiscordReady.line(activities) }
            onEvent?(.presence(userID: id, status: DiscordStatus(raw: d["status"] as? String), activity: activity))
        case "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE":
            if let d = data as? [String: Any], let channel = d["channel_id"] as? String, let message = d["message_id"] as? String, let user = d["user_id"] as? String,
               let emoji = DiscordMessage.emoji(from: d["emoji"] as? [String: Any]) {
                onEvent?(.reaction(channelID: channel, messageID: message, userID: user, emoji: emoji, add: type == "MESSAGE_REACTION_ADD"))
            }
        case "MESSAGE_REACTION_REMOVE_ALL":
            if let d = data as? [String: Any], let channel = d["channel_id"] as? String, let message = d["message_id"] as? String { onEvent?(.reactionsCleared(channelID: channel, messageID: message, emojiKey: nil)) }
        case "MESSAGE_REACTION_REMOVE_EMOJI":
            if let d = data as? [String: Any], let channel = d["channel_id"] as? String, let message = d["message_id"] as? String, let e = DiscordMessage.emoji(from: d["emoji"] as? [String: Any]) {
                onEvent?(.reactionsCleared(channelID: channel, messageID: message, emojiKey: DiscordMessage.Reaction.key(name: e.name, id: e.id)))
            }
        case "TYPING_START":
            if let d = data as? [String: Any], let channel = d["channel_id"] as? String, let user = d["user_id"] as? String {
                onEvent?(.typing(channelID: channel, userID: user, user: Self.user(from: (d["member"] as? [String: Any])?["user"])))
            }
        case "MESSAGE_CREATE":
            if let d = data as? [String: Any] { onEvent?(.messageCreate(d)) }
        case "MESSAGE_UPDATE":
            if let d = data as? [String: Any] { onEvent?(.messageUpdate(d)) }
        case "MESSAGE_DELETE":
            if let d = data as? [String: Any], let channel = d["channel_id"] as? String, let id = d["id"] as? String { onEvent?(.messageDelete(channelID: channel, id: id)) }
        case "RELATIONSHIP_ADD":
            guard let d = data as? [String: Any], (d["type"] as? Int) == 1, let u = d["user"], let json = try? JSONSerialization.data(withJSONObject: u),
                  let user = try? JSONDecoder().decode(DiscordUser.self, from: json) else { return }
            onEvent?(.friendAdded(user))
        case "RELATIONSHIP_REMOVE":
            if let d = data as? [String: Any], let id = d["id"] as? String { onEvent?(.friendRemoved(id)) }
        default:
            break
        }
    }
}
