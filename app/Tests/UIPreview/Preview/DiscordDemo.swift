// Mock servers, channels and people for the Discord browser preview (no connection to Discord).
import SwiftUI

enum DiscordDemo {
    private static func ch(_ id: String, _ name: String, _ kind: DiscordGuild.Channel.Kind, parent: String? = nil, _ position: Int = 0, topic: String? = nil) -> DiscordGuild.Channel {
        DiscordGuild.Channel(id: id, name: name, kind: kind, parentID: parent, position: position, topic: topic)
    }
    private static func person(_ id: String, _ name: String, speaking: Bool = false, me: Bool = false) -> CallMember {
        CallMember(id: id, name: name, avatarURL: nil, speaking: speaking, isSelf: me)
    }

    static let guilds: [DiscordGuild] = [
        DiscordGuild(id: "g1", name: "Porthole Testers", channels: [
            ch("c1", "welcome", .text, 0, topic: "Say hi and read the rules."), ch("c2", "announcements", .announcement, 1),
            ch("cat-chat", "Chat", .category, 1), ch("c3", "general", .text, parent: "cat-chat", 0, topic: "Anything about Porthole."), ch("c4", "bug-reports", .text, parent: "cat-chat", 1),
            ch("c5", "screenshots", .media, parent: "cat-chat", 2), ch("c6", "ideas", .forum, parent: "cat-chat", 3),
            ch("cat-voice", "Voice", .category, 2), ch("v1", "Lounge", .voice, parent: "cat-voice", 0), ch("v2", "Game night", .voice, parent: "cat-voice", 1), ch("v3", "AFK", .voice, parent: "cat-voice", 2),
        ]),
        DiscordGuild(id: "g2", name: "Factorio Friends", channels: [
            ch("f1", "factory-talk", .text, 0), ch("f2", "blueprints", .text, 1), ch("fv1", "Build session", .voice, 2),
        ]),
        DiscordGuild(id: "g3", name: "Late Night Raiders", channels: [ch("r1", "plans", .text, 0), ch("rv1", "Raid", .voice, 1), ch("rv2", "Chill", .voice, 2)]),
        DiscordGuild(id: "g4", name: "iPad Gaming", channels: [ch("i1", "chat", .text, 0), ch("iv1", "Voice", .voice, 1)]),
    ]

    static let friends: [DiscordFriend] = [
        DiscordFriend(user: DiscordUser(id: "u1", username: "alex", globalName: "Alex"), status: .online, activity: "Playing Factorio"),
        DiscordFriend(user: DiscordUser(id: "u2", username: "sam", globalName: "Sam"), status: .idle, activity: nil),
        DiscordFriend(user: DiscordUser(id: "u3", username: "jo", globalName: "Jo"), status: .dnd, activity: "Playing Terraria"),
        DiscordFriend(user: DiscordUser(id: "u4", username: "mika", globalName: "Mika"), status: .offline, activity: nil),
        DiscordFriend(user: DiscordUser(id: "u5", username: "robin", globalName: "Robin"), status: .offline, activity: nil),
    ]

    static let roster: [String: [CallMember]] = [
        "v1": [CallMember(id: "u1", name: "Alex", avatarURL: nil, speaking: true, isSelf: false, streaming: true), person("u3", "Jo")],
        "v2": [person("u2", "Sam"), person("u4", "Mika"), person("u5", "Robin"), person("u6", "Dani"), person("u7", "Kit"), person("u8", "Lee"), person("u9", "Noor")],
        "fv1": [person("u1", "Alex")],
    ]

    private static func say(_ id: String, _ who: String, _ name: String, _ minutesAgo: Double, _ text: String, reply: String? = nil, files: [String] = [], extras: [String] = [], channel: String = "c1", reactions: [DiscordMessage.Reaction] = [], embeds: [DiscordMessage.Embed] = []) -> DiscordMessage {
        DiscordMessage(id: id, channelID: channel, author: DiscordUser(id: who, username: name.lowercased(), globalName: name), content: text, date: Date().addingTimeInterval(-minutesAgo * 60), edited: id == "1005",
                       attachments: files.map { DiscordMessage.Attachment(id: $0, name: $0, url: nil, isImage: false) }, extras: extras, replyTo: reply, reactions: reactions, referenceID: reply == nil ? nil : "1003", embeds: embeds)
    }

    static let messages: [String: [DiscordMessage]] = [
        "c1": [
            say("1001", "u1", "Alex", 3000, "Welcome to the Porthole testers! Read the **rules** first, then say hi."),
            say("1002", "u1", "Alex", 2999, "Bug reports go in #bug-reports with the log attached."),
            say("1003", "u2", "Sam", 60, "hi all, just got 1.4.21 running on my iPad"),
            say("1004", "u3", "Jo", 42, "Nice! Does Factorio hold 60 fps for you?", reply: "Sam: hi all, just got 1.4.21 running on my iPad"),
            say("1005", "u2", "Sam", 41, "mostly yes, drops in the big factory", files: ["factory-log.txt"],
                reactions: [.init(id: "\u{1F44D}", name: "\u{1F44D}", count: 3, me: true), .init(id: "\u{1F680}", name: "\u{1F680}", count: 1, me: false), .init(id: "\u{1F62E}", name: "\u{1F62E}", count: 2, me: false)]),
            say("1006", "u2", "Sam", 40, "here is the overlay while it dropped", extras: ["Image link"]),
            say("1007", "u1", "Alex", 3, "Thanks, I will look at the log tonight. A much longer message follows so the line breaks onto several lines and shows how the text wraps inside the pane when somebody writes a whole paragraph in one go."),
        ],
    ]

    static let conversations: [DiscordBrowserData.Conversation] = [
        .init(id: "dm1", title: "Alex", isGroup: false, users: [DiscordUser(id: "u1", username: "alex", globalName: "Alex")]),
        .init(id: "dm3", title: "Weekend Factorio", isGroup: true, users: [DiscordUser(id: "u1", username: "alex", globalName: "Alex"), DiscordUser(id: "u2", username: "sam", globalName: "Sam"), DiscordUser(id: "u3", username: "jo", globalName: "Jo")]),
        .init(id: "dm2", title: "Sam", isGroup: false, users: [DiscordUser(id: "u2", username: "sam", globalName: "Sam")]),
    ]

    static let directMessages: [String: [DiscordMessage]] = [
        "dm1": [say("2001", "u1", "Alex", 50, "Did the new build work on your iPad?", channel: "dm1"), say("2002", "me", "You", 48, "Yes! The menu is much nicer now.", channel: "dm1"),
                say("2003", "u1", "Alex", 5, "Great, send me a screenshot when you can.", channel: "dm1")],
        "dm3": [say("2101", "u2", "Sam", 120, "Saturday 8pm?", channel: "dm3"), say("2102", "u3", "Jo", 118, "I am in.", channel: "dm3")],
    ]

    /// What a profile card reads for people (the preview has no connection to Discord).
    static func profile(_ id: String) -> DiscordProfile? {
        guard let f = friends.first(where: { $0.id == id }) else { return nil }
        return DiscordProfile(user: f.user, bio: "I build factories and then rebuild them. Ask me about trains.", pronouns: "they/them", bannerURL: nil, accent: 0x4CB8F5,
                              mutualServerIDs: ["g1", "g2"], mutualFriendCount: 4, createdAt: Date(timeIntervalSince1970: 1_500_000_000))
    }

    static var actions: DiscordBrowserActions {
        var a = DiscordBrowserActions()
        a.loadProfile = { id, done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(profile(id)) } }
        a.openDirect = { id, done in done(id == "u1" ? "dm1" : "dm2") }
        return a
    }

    static let forumPosts: [String: [DiscordForumPost]] = [
        "c6": [
            DiscordForumPost(id: "p1", title: "Read this before posting", ownerID: "u1", ownerName: "Alex", replies: 0, lastActivity: Date().addingTimeInterval(-86_400 * 9), tags: ["Rules"],
                             preview: "One idea per post, search first, and say which device you use.", thumbnail: nil, pinned: true, locked: true, archived: false),
            DiscordForumPost(id: "p2", title: "Dark mode for the Discord screen", ownerID: "u2", ownerName: "Sam", replies: 12, lastActivity: Date().addingTimeInterval(-3_600), tags: ["Idea", "Discord"],
                             preview: "It would be nice to follow the theme colours, and the unread badges could use the accent.", thumbnail: nil, pinned: false, locked: false, archived: false),
            DiscordForumPost(id: "p3", title: "Game sound in Go Live", ownerID: "u3", ownerName: "Jo", replies: 3, lastActivity: Date().addingTimeInterval(-86_400), tags: ["Idea"],
                             preview: "Right now the stream is silent. Any chance of the game's audio?", thumbnail: nil, pinned: false, locked: false, archived: false),
        ],
    ]

    static var data: DiscordBrowserData {
        var all = messages
        if let i = all["c1"]?.firstIndex(where: { $0.id == "1007" }) {
            all["c1"]![i].embeds = [.init(id: "e0", kind: "rich", title: "Porthole 1.4.91 released", description: "Reactions, replies, editing and deleting your own messages, typing indicators and earlier messages.\n**Try it** on your iPad.",
                                          provider: "Porthole", author: nil, footer: "Private channel", colour: 0x4CB8F5, imageURL: nil, thumbnailURL: nil,
                                          fields: [.init(name: "Fixed", value: "Empty replies from Discord", inline: true), .init(name: "Added", value: "Reactions", inline: true)])]
        }
        for (k, v) in directMessages { all[k] = v }
        return DiscordBrowserData(guilds: guilds, friends: friends, roster: roster, meName: "You", messages: all, messageLoad: ["c1": .loaded, "dm1": .loaded, "dm3": .loaded],
                                  meID: "me", conversations: conversations, forumPosts: forumPosts, forumLoad: ["c6": .loaded],
                                  unread: ["dm1": 2, "dm3": 14, "c3": 3], typing: ["c1": ["Sam", "Jo"]])
    }

    static var inCall: DiscordBrowserData {
        var d = data
        d.roster["v1"] = [person("me", "You", me: true), person("u1", "Alex", speaking: true), person("u3", "Jo")]
        d.people.setVolume("u1", 150); d.people.setMuted("u3", true)
        d.currentChannelID = "v1"; d.callStatus = "Connected"
        return d
    }
}
