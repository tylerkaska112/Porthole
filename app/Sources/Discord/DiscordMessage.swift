// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A message in a text channel, read from Discord's JSON (the REST list and the gateway's MESSAGE_CREATE / MESSAGE_UPDATE share the shape). The text is already made readable:
/// mentions show names, custom emoji show as :name:.
struct DiscordMessage: Identifiable, Equatable {
    struct Attachment: Equatable, Identifiable {
        var id: String
        var name: String
        var url: URL?
        var isImage: Bool
    }

    var id: String
    var channelID: String
    var author: DiscordUser
    var content: String
    var date: Date
    var edited: Bool
    var attachments: [Attachment]
    /// A short line for what Porthole does not draw yet: "Embed: <title>", "Sticker", "Poll".
    var extras: [String]
    /// The message this one answers: "name: the start of what they said", when Discord included it.
    var replyTo: String?
    /// The server it was said in; nil for a direct message or a group chat.
    var guildID: String? = nil
    /// Who it mentions by name (people, not roles or @everyone), and who wrote the message it answers.
    var mentionedIDs: [String] = []
    var replyToAuthorID: String? = nil
    /// The emoji people reacted with, in the order Discord lists them.
    var reactions: [Reaction] = []
    /// The id of the message this one answers (to answer the same one, or to find it).
    var referenceID: String? = nil

    /// The cards Discord makes of links (and of what bots send): a coloured bar, a title, a text, fields and a picture.
    var embeds: [Embed] = []
    /// Stickers that can be drawn (the picture kinds; Lottie stickers are named in `extras`).
    var stickers: [Sticker] = []

    struct Embed: Equatable, Identifiable {
        struct Field: Equatable { var name: String; var value: String; var inline: Bool }
        var id: String
        /// Discord's own word: rich, link, article, image, video, gifv.
        var kind: String
        var title: String?
        var description: String?
        var provider: String?
        var author: String?
        var footer: String?
        /// The card's colour, as 0xRRGGBB.
        var colour: UInt32?
        var imageURL: URL?
        var thumbnailURL: URL?
        var fields: [Field] = []
        /// A moving picture (its still is drawn; it is not played).
        var isAnimated: Bool { kind == "gifv" }
        /// Nothing in it can be drawn.
        var isEmpty: Bool { title == nil && description == nil && author == nil && imageURL == nil && thumbnailURL == nil && fields.isEmpty }

        /// Reads one embed. A link that is only a picture has its picture in `thumbnail`.
        static func parse(_ e: [String: Any], index: Int) -> Embed? {
            func clean(_ any: Any?) -> String? { (any as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
            func picture(_ any: Any?) -> URL? {
                guard let o = any as? [String: Any] else { return nil }
                return ((o["proxy_url"] as? String) ?? (o["url"] as? String)).flatMap(URL.init(string:))
            }
            let kind = (e["type"] as? String) ?? "rich"
            let fields = (e["fields"] as? [[String: Any]] ?? []).compactMap { f -> Field? in
                guard let n = clean(f["name"]), let v = clean(f["value"]) else { return nil }
                return Field(name: n, value: DiscordMessage.readable(v, mentions: [], channelName: { _ in nil }), inline: (f["inline"] as? Bool) == true)
            }
            var embed = Embed(id: "e\(index)", kind: kind, title: clean(e["title"]), description: clean(e["description"]).map { DiscordMessage.readable($0, mentions: [], channelName: { _ in nil }) },
                              provider: clean((e["provider"] as? [String: Any])?["name"]), author: clean((e["author"] as? [String: Any])?["name"]), footer: clean((e["footer"] as? [String: Any])?["text"]),
                              colour: (e["color"] as? Int).map { UInt32(truncatingIfNeeded: $0) }, imageURL: picture(e["image"]), thumbnailURL: picture(e["thumbnail"]), fields: fields)
            if (kind == "image" || kind == "gifv"), embed.imageURL == nil { embed.imageURL = embed.thumbnailURL; embed.thumbnailURL = nil }
            return embed.isEmpty ? nil : embed
        }
    }

    struct Sticker: Equatable, Identifiable {
        var id: String
        var name: String
        var url: URL

        /// Discord's sticker formats: 1 PNG, 2 APNG, 3 Lottie, 4 GIF. Only the picture ones can be drawn (an APNG shows its first frame).
        static func make(id: String, name: String, format: Int?) -> Sticker? {
            switch format ?? 1 {
            case 1, 2: URL(string: "https://media.discordapp.net/stickers/\(id).png?size=160").map { Sticker(id: id, name: name, url: $0) }
            case 4: URL(string: "https://media.discordapp.net/stickers/\(id).gif?size=160").map { Sticker(id: id, name: name, url: $0) }
            default: nil
            }
        }
    }

    /// One emoji under a message: how many people used it and whether this account did.
    struct Reaction: Equatable, Identifiable {
        /// How Discord names it in a request: the emoji itself, or `name:id` for a server's own emoji.
        var id: String
        /// What is drawn: the emoji, or the name of a server's own emoji.
        var name: String
        var customID: String?
        var animated = false
        var count: Int
        var me: Bool

        static func key(name: String, id: String?) -> String { id.map { "\(name):\($0)" } ?? name }
        /// The picture of a server's own emoji.
        var imageURL: URL? { customID.flatMap { URL(string: "https://cdn.discordapp.com/emojis/\($0).\(animated ? "gif" : "png")?size=48") } }
    }

    /// The emoji of a reaction event or a message's reaction list: `{ "id": null | "123", "name": "\u{1F44D}" | "party", "animated": false }`.
    static func emoji(from d: [String: Any]?) -> (name: String, id: String?, animated: Bool)? {
        guard let d, let name = d["name"] as? String ?? (d["id"] as? String) else { return nil }
        return (name, d["id"] as? String, (d["animated"] as? Bool) == true)
    }

    /// A reaction was added or taken away by somebody: the counts follow. `mine` says it was this account (which already changed the count when it pressed the emoji, so the echo from
    /// Discord changes nothing).
    mutating func apply(emoji: (name: String, id: String?, animated: Bool), add: Bool, mine: Bool) {
        let key = Reaction.key(name: emoji.name, id: emoji.id)
        if let i = reactions.firstIndex(where: { $0.id == key }) {
            if add {
                if mine { if reactions[i].me { return }; reactions[i].me = true }
                reactions[i].count += 1
            } else {
                if mine { guard reactions[i].me else { return }; reactions[i].me = false }
                reactions[i].count -= 1
                if reactions[i].count <= 0 { reactions.remove(at: i) }
            }
        } else if add {
            reactions.append(Reaction(id: key, name: emoji.name, customID: emoji.id, animated: emoji.animated, count: 1, me: mine))
        }
    }

    /// This account presses an emoji: on if it was off, off if it was on. Returns what the request to Discord should do.
    mutating func toggle(emoji: (name: String, id: String?, animated: Bool)) -> Bool {
        let on = !(reactions.first { $0.id == Reaction.key(name: emoji.name, id: emoji.id) }?.me ?? false)
        apply(emoji: emoji, add: on, mine: true)
        return on
    }

    var isDirect: Bool { guildID == nil }
    /// Whether this message is aimed at `me`: it names them, or answers something they wrote (Discord pings a reply's author).
    func mentions(_ me: String) -> Bool { mentionedIDs.contains(me) || replyToAuthorID == me }

    /// Message types shown: 0 is a normal message, 19 a reply. The rest (joins, pins, boosts, calls) are not chat.
    static let shownTypes: Set<Int> = [0, 19]

    static func parse(_ d: [String: Any], channelName: (String) -> String? = { _ in nil }) -> DiscordMessage? {
        guard let id = d["id"] as? String, let channelID = d["channel_id"] as? String, let author = user(d["author"]) else { return nil }
        guard shownTypes.contains(d["type"] as? Int ?? 0) else { return nil }
        let mentions = (d["mentions"] as? [Any] ?? []).compactMap(user)
        let content = readable(d["content"] as? String ?? "", mentions: mentions, channelName: channelName)
        let attachments = (d["attachments"] as? [[String: Any]] ?? []).compactMap { a -> Attachment? in
            guard let aid = a["id"] as? String else { return nil }
            let type = (a["content_type"] as? String) ?? ""
            let name = a["filename"] as? String ?? "file"
            let image = type.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp"].contains((name as NSString).pathExtension.lowercased())
            return Attachment(id: aid, name: name, url: (a["url"] as? String).flatMap(URL.init(string:)), isImage: image)
        }
        // What is drawn as a card or a picture (embeds, stickers) has its own fields; what is not drawn is named in a line.
        var extras: [String] = []
        let embeds = (d["embeds"] as? [[String: Any]] ?? []).enumerated().compactMap { Embed.parse($1, index: $0) }
        var stickers: [Sticker] = []
        for item in d["sticker_items"] as? [[String: Any]] ?? [] {
            guard let sid = item["id"] as? String else { continue }
            let name = (item["name"] as? String) ?? "sticker"
            if let sticker = Sticker.make(id: sid, name: name, format: item["format_type"] as? Int) { stickers.append(sticker) } else { extras.append("Sticker: \(name)") }
        }
        if d["poll"] != nil { extras.append("Poll (open it in Discord)") }
        var reply: String?
        var replyAuthor: String?
        if let ref = d["referenced_message"] as? [String: Any], let who = user(ref["author"]) {
            let text = readable(ref["content"] as? String ?? "", mentions: (ref["mentions"] as? [Any] ?? []).compactMap(user), channelName: channelName)
            reply = "\(who.displayName): \(text.isEmpty ? "an attachment" : String(text.prefix(80)))"
            replyAuthor = who.id
        }
        let reactions = (d["reactions"] as? [[String: Any]] ?? []).compactMap { r -> Reaction? in
            guard let e = emoji(from: r["emoji"] as? [String: Any]), let count = r["count"] as? Int, count > 0 else { return nil }
            return Reaction(id: Reaction.key(name: e.name, id: e.id), name: e.name, customID: e.id, animated: e.animated, count: count, me: (r["me"] as? Bool) == true)
        }
        return DiscordMessage(id: id, channelID: channelID, author: author, content: content, date: date(d["timestamp"] as? String) ?? Date(),
                              edited: (d["edited_timestamp"] as? String) != nil, attachments: attachments, extras: extras, replyTo: reply,
                              guildID: d["guild_id"] as? String, mentionedIDs: mentions.map(\.id), replyToAuthorID: replyAuthor, reactions: reactions,
                              referenceID: (d["message_reference"] as? [String: Any])?["message_id"] as? String, embeds: embeds, stickers: stickers)
    }

    private static func user(_ any: Any?) -> DiscordUser? {
        guard let o = any as? [String: Any], let id = o["id"] as? String, let name = o["username"] as? String else { return nil }
        return DiscordUser(id: id, username: name, globalName: o["global_name"] as? String, avatar: o["avatar"] as? String, discriminator: o["discriminator"] as? String)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// Discord writes mentions, channels and emoji as codes in the text; this turns them into what a person reads.
    static func readable(_ text: String, mentions: [DiscordUser], channelName: (String) -> String?) -> String {
        var out = text
        func replace(_ pattern: String, _ make: ([String]) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = out as NSString
            var result = "", last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                result += make((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        replace("<@!?(\\d+)>") { g in "@" + (mentions.first { $0.id == g[1] }?.displayName ?? "someone") }
        replace("<@&(\\d+)>") { _ in "@role" }
        replace("<#(\\d+)>") { g in "#" + (channelName(g[1]) ?? "channel") }
        replace("<a?:(\\w+):\\d+>") { g in ":\(g[1]):" }
        replace("<t:(\\d+)(?::[a-zA-Z])?>") { g in
            let date = Date(timeIntervalSince1970: Double(g[1]) ?? 0)
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return out
    }
}

/// What a person typed, checked before it is sent: Discord's own limit for a message is 2000 characters, and a message of only spaces is not sent.
enum OutgoingMessage {
    static let maxLength = 2000

    enum Problem: Error, Equatable {
        case empty
        case tooLong(Int)
        var message: String {
            switch self {
            case .empty: "There is nothing to send."
            case .tooLong(let count): "That message is \(count - OutgoingMessage.maxLength) characters too long (Discord allows \(OutgoingMessage.maxLength))."
            }
        }
    }

    static func check(_ raw: String) -> Result<String, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.empty) }
        if text.count > maxLength { return .failure(.tooLong(text.count)) }
        return .success(text)
    }

    /// A number like the ones Discord's own apps put on a message they send (it lets Discord drop a message that is sent twice).
    static func nonce(now: Date = Date()) -> String { String((UInt64(now.timeIntervalSince1970 * 1000) &- 1_420_070_400_000) << 22 | UInt64.random(in: 0..<(1 << 22))) }
}

/// Where reading EARLIER messages of a channel stands (absent: there may be more to read).
enum OlderMessages: Equatable { case loading, done }

/// Where loading a channel's messages stands.
enum MessageLoad: Equatable {
    case loading, loaded
    case failed(String)
}

extension DiscordMessage {
    /// Two lists of one channel's messages as one, oldest first, one entry per message (the second list wins: it is newer news, e.g. an edit), keeping the newest `cap`.
    /// Discord's ids grow with time, so they order the messages.
    static func merged(_ a: [DiscordMessage], _ b: [DiscordMessage], cap: Int = 600) -> [DiscordMessage] {
        var byID: [String: DiscordMessage] = [:]
        for m in a { byID[m.id] = m }
        for m in b { byID[m.id] = m }
        let sorted = byID.values.sorted { (UInt64($0.id) ?? 0, $0.id) < (UInt64($1.id) ?? 0, $1.id) }
        return sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
    }
}

extension DiscordMessageGroup {
    /// The line between two days of a conversation: "Today", "Yesterday", the weekday for the last week, else the date.
    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        let f = DateFormatter()
        f.calendar = calendar; f.locale = Locale.current; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(days > 0 && days < 7 ? "EEEE" : (calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "EEEEMMMd" : "yMMMMd"))
        return f.string(from: date)
    }

    /// Whether a day line goes before this group: it is the first one, or the day changed since the one before.
    static func startsNewDay(_ group: DiscordMessageGroup, after previous: DiscordMessageGroup?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(group.date, inSameDayAs: previous.date)
    }
}

/// Messages by the same person close together are drawn as one block under one name and time, the way Discord does.
struct DiscordMessageGroup: Identifiable, Equatable {
    var id: String { messages[0].id }
    var author: DiscordUser { messages[0].author }
    var date: Date { messages[0].date }
    var messages: [DiscordMessage]

    static let window: TimeInterval = 7 * 60

    /// `list` is oldest first. A reply starts a new block (it carries its own header line).
    static func groups(_ list: [DiscordMessage]) -> [DiscordMessageGroup] {
        var out: [DiscordMessageGroup] = []
        for m in list {
            if var last = out.last, last.author.id == m.author.id, m.replyTo == nil, m.date.timeIntervalSince(last.messages[last.messages.count - 1].date) < window {
                last.messages.append(m)
                out[out.count - 1] = last
            } else {
                out.append(DiscordMessageGroup(messages: [m]))
            }
        }
        return out
    }
}
