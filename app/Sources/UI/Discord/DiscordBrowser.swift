// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// What the Discord browser shows: plain data, so the screen can be drawn (and tried out) without a connection to Discord.
struct DiscordBrowserData: Equatable {
    var guilds: [DiscordGuild] = []
    var friends: [DiscordFriend] = []
    /// Who is in each voice channel (channel id -> people).
    var roster: [String: [CallMember]] = [:]
    var meName = ""
    var meAvatar: URL?
    /// The voice channel this account is in or joining.
    var currentChannelID: String?
    /// What the call is doing ("Connected", "Joining"), when there is one.
    var callStatus: String?
    var muted = false
    var deafened = false
    /// The call in a direct message or group chat this account is in (its name), which is not a channel of any server.
    var directCall: String?
    /// How loud each person is for this phone, and who is muted (see PersonVolumes).
    var people = PersonVolumes()
    /// What was read of each text channel (oldest first) and how loading it went.
    var messages: [String: [DiscordMessage]] = [:]
    var messageLoad: [String: MessageLoad] = [:]
    /// Channels a message is being sent to, and why the last one was not sent.
    var sending: Set<String> = []
    var sendError: [String: String] = [:]
    /// This account's own id, to tell "you" from the others (a profile card has no Message for yourself).
    var meID = ""
    /// The direct messages and group chats, newest first.
    var conversations: [Conversation] = []
    /// The posts of each forum or media channel that was opened, and how reading them went.
    var forumPosts: [String: [DiscordForumPost]] = [:]
    var forumLoad: [String: MessageLoad] = [:]
    /// Messages waiting in each channel or conversation, and the one a tapped banner asks to open.
    var unread: [String: Int] = [:]
    var focusChannelID: String?
    /// Who is typing in each channel or conversation right now (names).
    var typing: [String: [String]] = [:]
    /// Whether earlier messages can be read, per channel (absent: they may be; done: no more).
    var olderState: [String: OlderMessages] = [:]

    struct Conversation: Identifiable, Equatable {
        var id: String
        var title: String
        var isGroup: Bool
        var users: [DiscordUser]
    }
}

struct DiscordBrowserActions {
    var join: (DiscordGuild, DiscordGuild.Channel) -> Void = { _, _ in }
    var leave: () -> Void = {}
    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var setPersonVolume: (String, Double) -> Void = { _, _ in }
    var setPersonMuted: (String, Bool) -> Void = { _, _ in }
    /// Read a text channel's latest messages (the second argument forces a new read).
    var loadMessages: (String, Bool) -> Void = { _, _ in }
    /// Send a message to a text channel (called only when a person pressed Send); the closure says whether it went.
    var sendMessage: (String, String, String?, @escaping (Bool) -> Void) -> Void = { _, _, _, done in done(false) }
    /// Change the text of one of your own messages (channel, message, new text); the closure says whether it was saved.
    var editMessage: (String, String, String, @escaping (Bool) -> Void) -> Void = { _, _, _, done in done(false) }
    /// Delete one of your own messages (channel, message), after the person confirmed it.
    var deleteMessage: (String, String) -> Void = { _, _ in }
    /// Press an emoji under a message (channel, message, emoji, a server's own emoji id, animated): on if it was off, off if it was on.
    var toggleReaction: (String, String, String, String?, Bool) -> Void = { _, _, _, _, _ in }
    /// Read the messages before the oldest one shown.
    var loadOlder: (String) -> Void = { _ in }
    /// Which channel or conversation is being read now (nil: none), so what arrives in it is read at once and needs no banner.
    var viewing: (String?) -> Void = { _ in }
    /// The tapped banner's request was carried out.
    var consumeFocus: () -> Void = {}
    /// Read a forum's posts (the second argument forces a new read).
    var loadForum: (String, Bool) -> Void = { _, _ in }
    /// Reads a person's profile (called with nil when Discord would not say).
    var loadProfile: (String, @escaping (DiscordProfile?) -> Void) -> Void = { _, done in done(nil) }
    /// The conversation with a person (made when there is none); called with its id, or nil when it could not be opened.
    var openDirect: (String, @escaping (String?) -> Void) -> Void = { _, done in done(nil) }
    /// Calls a conversation: joins its call and rings the others.
    var callDirect: (String) -> Void = { _ in }
    /// Watches somebody's Go Live (the person's id), when they are streaming in the voice channel this account is in.
    var watch: (String) -> Void = { _ in }
    var close: () -> Void = {}
    /// Opens Discord's settings (embedded in the Social tab, where the close button is not needed).
    var settings: () -> Void = {}
    /// Embedded on a phone held sideways, where the tab's own Discord / Steam switch is hidden to give the chat the room: a small button for the other section.
    var otherSection: (title: String, go: () -> Void)?
}

/// Discord the way its own app lays it out: the servers down the left, the selected server's channels in categories next to them, and the selected channel on the right. On a phone
/// held upright the three become three steps (servers, channels, channel). Touch, a controller (D-pad to move, A to open, X to join a voice channel, the bumpers to change server,
/// B to go back) and a keyboard and mouse all work, through the same focus targets as the rest of Porthole.
struct DiscordBrowser: View {
    let data: DiscordBrowserData
    let actions: DiscordBrowserActions
    /// Living in the Social tab instead of its own full-screen cover: it shares the tab's focus layer and background, and the corner button opens settings instead of closing.
    var embedded = false

    enum Place: Equatable { case friends, messages, guild(String) }
    fileprivate struct ProfileRequest: Identifiable { let user: DiscordUser; var id: String { user.id } }
    enum Level { case servers, channels, channel }

    @State private var ownScope = FocusScope()
    @Environment(\.focusScope) private var tabScope
    @State private var place: Place = .friends
    @State private var channelID: String?
    @State private var level: Level = .servers
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
    @State private var wide = true
    /// A phone held sideways: every bar and heading gets tighter so the messages have the room.
    @State private var short = false
    @State private var drafts: [String: String] = [:]
    @State private var conversationID: String?
    /// The forum post that is open (a forum shows its list of posts until one is opened).
    @State private var openPost: DiscordForumPost?
    @State fileprivate var profileRequest: ProfileRequest?
    @State fileprivate var openError: String?
    /// The message being answered and the one being edited, by channel; the message the actions menu is open on; the one asked to be deleted.
    @State private var replyingTo: [String: DiscordMessage] = [:]
    @State private var editing: [String: DiscordMessage] = [:]
    @State fileprivate var actionsFor: DiscordMessage?
    @State fileprivate var deleting: DiscordMessage?
    @State fileprivate var imageRequest: ImageRequest?
    /// The block that was just jumped to (briefly lit).
    @State private var flash: String?
    fileprivate struct ImageRequest: Identifiable { let url: URL; let name: String; var id: String { url.absoluteString } }
    private static let quickEmoji = ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F389}"]
    @State private var confirmSend: String?
    @State private var personID: String? = UserDefaults.standard.string(forKey: "f4.discordPerson")    // a preview launch argument selects one

    static let collapsedKey = "f4.discordCollapsed", placeKey = "f4.discordPlace", sendAckKey = "f4.discordSendAcknowledged"

    private var other: (title: String, go: () -> Void)? { actions.otherSection }
    private var scope: FocusScope { embedded ? (tabScope ?? ownScope) : ownScope }

    private var guild: DiscordGuild? {
        if case .guild(let id) = place { return data.guilds.first { $0.id == id } }
        return nil
    }
    private var channel: DiscordGuild.Channel? { guild.flatMap { g in channelID.flatMap { g.channel($0) } } }
    /// What is being read right now: a text channel, a forum post, or a conversation (on a phone held upright only on the screen that shows it).
    private var viewedID: String? {
        if !wide, level != .channel { return nil }
        switch place {
        case .friends: return nil
        case .messages: return conversationID
        case .guild: return openPost?.id ?? (channel?.readsMessages == true ? channel?.id : nil)
        }
    }

    /// A tapped banner asks for a channel or conversation: show it.
    private func applyFocus() {
        guard let id = data.focusChannelID else { return }
        defer { actions.consumeFocus() }
        if let c = data.conversations.first(where: { $0.id == id }) {
            place = .messages; conversationID = c.id
            UserDefaults.standard.set("messages", forKey: Self.placeKey)
        } else if let g = data.guilds.first(where: { $0.channel(id) != nil }) {
            place = .guild(g.id); channelID = id
            UserDefaults.standard.set(g.id, forKey: Self.placeKey)
        } else { return }
        if !wide { level = .channel }
    }

    private func unreadCount(in guild: DiscordGuild) -> Int { guild.channels.reduce(0) { $0 + (data.unread[$1.id] ?? 0) } }

    private var conversation: DiscordBrowserData.Conversation? { conversationID.flatMap { id in data.conversations.first { $0.id == id } } }

    var body: some View {
        screen
            .modifier(OwnScope(active: !embedded, scope: ownScope))
            .onNavBack { stepBack() }
            .modifier(dialogs)
            .onChange(of: channelID) { _, _ in openPost = nil }
            .onChange(of: viewedID) { _, id in actions.viewing(id) }
            .onChange(of: data.focusChannelID) { _, _ in applyFocus() }
            .onDisappear { actions.viewing(nil) }
            .onAppear {
                if !embedded {
                    scope.onBack = { actions.close() }
                    scope.onSection = { cycleServer($0) }
                }
                restore()
                applyFocus()
                focusStart()
                actions.viewing(viewedID)
            }
            .preferredColorScheme(Theme.scheme)
    }

    /// The columns (or steps on a phone held upright), measured to know which.
    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                if !embedded { AmbientBackdrop(animated: false) }
                Group { if geo.size.width >= 680 { wideLayout } else { compactLayout } }
            }
            .onAppear { wide = geo.size.width >= 680; short = geo.size.height < 480 }
            .onChange(of: geo.size.width) { _, width in wide = width >= 680 }
            .onChange(of: geo.size.height) { _, height in short = height < 480 }
        }
    }

    fileprivate var actionsBinding: Binding<Bool> { Binding(get: { actionsFor != nil }, set: { if !$0 { actionsFor = nil } }) }
    fileprivate var deletingBinding: Binding<Bool> { Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }) }
    fileprivate var openErrorBinding: Binding<Bool> { Binding(get: { openError != nil }, set: { if !$0 { openError = nil } }) }
    fileprivate func confirmDelete() { if let m = deleting { actions.deleteMessage(m.channelID, m.id) }; deleting = nil }

    /// Everything that opens over the browser: a person's card, a picture, the message menu and the questions it asks.
    private var dialogs: some ViewModifier { DiscordBrowserDialogs(browser: self) }

    // MARK: Layouts

    private var wideLayout: some View {
        HStack(spacing: 0) {
            rail.frame(width: short ? 64 : 92)
            Divider().overlay(Theme.line)
            switch place {
            case .friends: friendsPane
            case .messages:
                conversationList.frame(width: short ? 210 : 300)
                Divider().overlay(Theme.line)
                conversationPane
            case .guild:
                channelList.frame(width: short ? 210 : 300)
                Divider().overlay(Theme.line)
                channelPane
            }
        }
    }

    @ViewBuilder private var compactLayout: some View {
        switch level {
        case .servers:
            VStack(spacing: 0) {
                topBar(title: "Discord", back: nil)
                ScrollView { serverList.padding(16) }
            }
        case .channels:
            VStack(spacing: 0) {
                topBar(title: place == .messages ? "Messages" : (guild?.name ?? "Friends"), back: { _ = stepBack() })
                switch place {
                case .friends: friendsList.frame(maxHeight: .infinity)
                case .messages: conversationList
                case .guild: channelList
                }
            }
        case .channel:
            VStack(spacing: 0) {
                topBar(title: place == .messages ? (conversation?.title ?? "") : (channel.map { ($0.isVoice ? "" : "#") + $0.name } ?? ""), back: { _ = stepBack() })
                if place == .messages { conversationPane } else { channelPane }
            }
        }
    }

    private func topBar(title: String, back: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            if back != nil || !embedded {
                Button { if let back { back() } else { actions.close() } } label: {
                    Image(systemName: back == nil ? "xmark" : "chevron.left").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                        .background(Theme.panelHigh, in: Circle()).foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain).focusTarget("dc-top-back", radius: 22) { if let back { back() } else { actions.close() } }
            }
            Text(title).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            if embedded && back == nil { settingsButton }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var settingsButton: some View {
        Button { actions.settings() } label: {
            Image(systemName: "gearshape.fill").font(.system(size: short ? 15 : 17, weight: .bold)).frame(width: short ? 36 : 44, height: short ? 36 : 44).background(Theme.panelHigh, in: Circle()).foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain).accessibilityLabel("Discord settings").focusTarget("dc-settings", radius: 22) { actions.settings() }
    }

    // MARK: Servers

    private var rail: some View {
        VStack(spacing: 0) {
            if embedded {
                settingsButton.padding(.top, short ? 4 : 14).padding(.bottom, other == nil ? (short ? 4 : 10) : (short ? 3 : 6))
                if let other {
                    Button(action: other.go) {
                        Text(other.title).font(.system(size: 12, weight: .bold, design: .rounded)).frame(width: short ? 52 : 64, height: short ? 26 : 30).background(Theme.panelHigh, in: Capsule()).foregroundStyle(Theme.text)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Show \(other.title)").focusTarget("dc-other", radius: 15) { other.go() }
                    .padding(.bottom, short ? 4 : 10)
                }
            } else {
                Button { actions.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44).background(Theme.panelHigh, in: Circle()).foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain).focusTarget("dc-close", radius: 22) { actions.close() }
                .padding(.top, 14).padding(.bottom, 10)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: short ? 4 : 12) {
                    railButton(selected: place == .friends, id: "dc-friends", title: "Friends") {
                        RoundedRectangle(cornerRadius: short ? 13 : 16, style: .continuous).fill(place == .friends ? Theme.accent : Theme.panelHigh)
                            .overlay(Image(systemName: "person.2.fill").font(.system(size: short ? 16 : 20, weight: .bold)).foregroundStyle(place == .friends ? Theme.onAccent : Theme.text))
                    } action: { open(.friends) }
                    railButton(selected: place == .messages, id: "dc-messages", title: "Messages") {
                        RoundedRectangle(cornerRadius: short ? 13 : 16, style: .continuous).fill(place == .messages ? Theme.accent : Theme.panelHigh)
                            .overlay(Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: short ? 15 : 19, weight: .bold)).foregroundStyle(place == .messages ? Theme.onAccent : Theme.text))
                            .overlay(alignment: .topTrailing) { let n = data.conversations.reduce(0) { $0 + (data.unread[$1.id] ?? 0) }; if n > 0 { DiscordCountBadge(count: n).offset(x: 6, y: -6) } }
                    } action: { open(.messages) }
                    Capsule().fill(Theme.line).frame(width: 30, height: 2).padding(.vertical, 2)
                    ForEach(data.guilds) { g in
                        railButton(selected: place == .guild(g.id), id: "dc-s-\(g.id)", title: g.name) {
                            GuildIcon(guild: g, size: short ? 40 : 52, selected: place == .guild(g.id))
                                .overlay(alignment: .topTrailing) { let n = unreadCount(in: g); if n > 0 { DiscordCountBadge(count: n).offset(x: 6, y: -6) } }
                        } action: { open(.guild(g.id)) }
                    }
                }
                .padding(.vertical, 6).frame(maxWidth: .infinity)
            }
            if data.currentChannelID != nil { callBadge.padding(.vertical, short ? 6 : 12) }
        }
        .background(Theme.panel.opacity(0.6))
    }

    private func railButton<Icon: View>(selected: Bool, id: String, title: String, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                icon().frame(width: short ? 40 : 52, height: short ? 40 : 52)
                Capsule().fill(Theme.text).frame(width: 4, height: selected ? (short ? 24 : 32) : 0).offset(x: short ? -10 : -14)
            }
            .frame(width: short ? 52 : 70, height: short ? 44 : 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 18, action: action)
        .accessibilityLabel(title)
    }

    /// The call this account is in, always in sight on the rail: green, with who is talking.
    private var callBadge: some View {
        Image(systemName: data.deafened ? "speaker.slash.fill" : data.muted ? "mic.slash.fill" : "waveform").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
            .frame(width: short ? 36 : 44, height: short ? 36 : 44).background(data.muted || data.deafened ? Theme.warn : Theme.good, in: Circle())
            .accessibilityLabel("In a call")
    }

    private var serverList: some View {
        VStack(spacing: 10) {
            serverRow(title: "Friends", detail: "\(data.friends.filter { $0.status.isOnline }.count) online", id: "dc-friends", selected: false) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panelHigh).frame(width: 48, height: 48)
                    .overlay(Image(systemName: "person.2.fill").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text))
            } action: { open(.friends) }
            serverRow(title: "Messages", detail: "\(data.conversations.count) conversation\(data.conversations.count == 1 ? "" : "s")", id: "dc-messages", selected: false, badge: data.conversations.reduce(0) { $0 + (data.unread[$1.id] ?? 0) }) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panelHigh).frame(width: 48, height: 48)
                    .overlay(Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text))
            } action: { open(.messages) }
            ForEach(data.guilds) { g in
                serverRow(title: g.name, detail: "\(g.channels.filter { !$0.isCategory }.count) channels", id: "dc-s-\(g.id)", selected: false, badge: unreadCount(in: g)) {
                    GuildIcon(guild: g, size: 48, selected: false)
                } action: { open(.guild(g.id)) }
            }
            if data.guilds.isEmpty { emptyNote("No servers came with the connection.") }
        }
    }

    private func serverRow<Icon: View>(title: String, detail: String, id: String, selected: Bool, badge: Int = 0, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(.footnote).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if badge > 0 { DiscordCountBadge(count: badge) }
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.textDim)
            }
            .padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusTarget(id, radius: 16, action: action)
    }

    // MARK: Channels

    private var channelList: some View {
        VStack(spacing: 0) {
            if wide, let guild {
                HStack {
                    Text(guild.name).font(.system(size: short ? 16 : 19, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, short ? 10 : 20).padding(.bottom, short ? 6 : 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: short ? 1 : 6) {
                    if let guild {
                        ForEach(guild.sections) { section in
                            if let category = section.category { categoryHeader(category) }
                            if section.category == nil || !collapsed.contains(section.category!.id) {
                                ForEach(section.channels) { c in channelRow(c, guild: guild) }
                            } else {
                                // A collapsed category still shows the channel you are in, as Discord's does.
                                ForEach(section.channels.filter { $0.id == data.currentChannelID || $0.id == channelID }) { c in channelRow(c, guild: guild) }
                            }
                        }
                        if guild.sections.isEmpty { emptyNote("This server has no channel this account can see.") }
                    }
                }
                .padding(.horizontal, short ? 6 : 10).padding(.bottom, short ? 8 : 20).padding(.top, wide ? 0 : 6)
            }
        }
        .background(Theme.panel.opacity(0.3))
    }

    /// An open thread under its channel, indented.
    private func threadRow(_ t: DiscordGuild.Channel) -> some View {
        let selected = channelID == t.id
        return Button { openChannel(t) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: short ? 11 : 12, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text(t.name).font(.system(size: short ? 13 : 15, weight: selected ? .bold : .medium, design: .rounded)).foregroundStyle(selected ? Theme.text : Theme.textDim).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 26).padding(.trailing, 10).frame(minHeight: short ? 28 : 36)
            .background(selected ? Theme.panelHigh : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("dc-c-\(t.id)", radius: 10) { openChannel(t) }
    }

    private func categoryHeader(_ category: DiscordGuild.Channel) -> some View {
        let isCollapsed = collapsed.contains(category.id)
        return Button { toggle(category.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .heavy)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(category.name.uppercased()).font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(0.6).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Theme.textDim).padding(.horizontal, 8).padding(.top, short ? 6 : 14).padding(.bottom, short ? 2 : 4).frame(minHeight: short ? 26 : 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusTarget("dc-cat-\(category.id)", radius: 10, label: isCollapsed ? "Expand" : "Collapse") { toggle(category.id) }
    }

    private func channelRow(_ c: DiscordGuild.Channel, guild: DiscordGuild) -> some View {
        let selected = channelID == c.id
        let inCall = data.currentChannelID == c.id
        let members = data.roster[c.id] ?? []
        return VStack(alignment: .leading, spacing: 2) {
            Button { openChannel(c) } label: {
                HStack(spacing: 10) {
                    Image(systemName: c.symbol).font(.system(size: short ? 13 : 15, weight: .semibold)).frame(width: short ? 18 : 22).foregroundStyle(inCall ? Theme.good : (selected ? Theme.text : Theme.textDim))
                    Text(c.name).font(.system(size: short ? 14 : 16, weight: selected || inCall ? .bold : .medium, design: .rounded)).foregroundStyle(selected || inCall ? Theme.text : Theme.textDim).lineLimit(1)
                    Spacer(minLength: 4)
                    if let n = data.unread[c.id], n > 0 { DiscordCountBadge(count: n) }
                    else if inCall { Circle().fill(Theme.good).frame(width: 8, height: 8) }
                    else if c.isVoice, !members.isEmpty { Text("\(members.count)").font(.caption.weight(.bold)).foregroundStyle(Theme.textDim) }
                }
                .padding(.horizontal, 10).frame(minHeight: short ? 32 : 44)
                .background(selected ? Theme.panelHigh : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusTarget("dc-c-\(c.id)", radius: 10, secondary: c.isVoice ? { join(guild, c) } : nil, label: "Open", secondaryLabel: inCall ? nil : "Join voice") { openChannel(c) }
            ForEach(guild.threads(of: c.id).prefix(6)) { t in threadRow(t) }
            if c.isVoice, !members.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(members.prefix(5)) { m in
                        HStack(spacing: 8) {
                            DiscordFace(url: m.avatarURL, name: m.name, size: 22, speaking: m.speaking)
                            Text(m.name).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                            if m.streaming { DiscordLiveBadge(small: true) }
                        }
                    }
                    if members.count > 5 { Text("and \(members.count - 5) more").font(.caption).foregroundStyle(Theme.textDim).padding(.leading, 30) }
                }
                .padding(.leading, 34).padding(.bottom, 4)
            }
        }
    }

    // MARK: The selected channel

    @ViewBuilder private var channelPane: some View {
        if let guild, let channel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: short ? 8 : 12) {
                    Image(systemName: channel.symbol).font(.system(size: short ? 17 : 22, weight: .semibold)).foregroundStyle(Theme.textDim)
                    if short {
                        Text(channel.name).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(guild.name).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(channel.kindTitle) in \(guild.name)").font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                    }
                    Spacer()
                    if channel.readsMessages { refreshButton(channel) } else if channel.isForum { refreshButton(id: channel.id, forum: true) }
                }
                .padding(.horizontal, short ? 18 : 24).padding(.top, short ? 8 : 24).padding(.bottom, short ? 6 : 14)
                if channel.isVoice { voiceScroll(guild: guild, channel: channel) } else { textPane(channel) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 44)).foregroundStyle(Theme.textDim)
                Text("Pick a channel").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text("Voice channels show who is in them and can be joined.").font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Forums

    /// A forum: its posts as cards, the most recently active first; opening one shows its conversation (and the box to reply) with a way back to the list.
    @ViewBuilder private func forumPane(_ channel: DiscordGuild.Channel) -> some View {
        if let post = openPost {
            VStack(alignment: .leading, spacing: short ? 4 : 8) {
                HStack(spacing: 10) {
                    Button { openPost = nil } label: {
                        Label("Posts", systemImage: "chevron.left").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).frame(height: 34).background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain).focusTarget("dc-post-back", radius: 17) { openPost = nil }
                    Text(post.title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    if post.locked { Label("Locked", systemImage: "lock.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.warn) }
                    Spacer()
                    refreshButton(id: post.id)
                }
                .padding(.horizontal, short ? 18 : 24)
                messagesPane(id: post.id, prompt: "Reply to \(post.title)", topic: nil)
            }
        } else {
            let load = data.forumLoad[channel.id]
            let posts = data.forumPosts[channel.id] ?? []
            VStack(alignment: .leading, spacing: 10) {
                if let topic = channel.topic, !short { Text(topic).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(3).padding(.horizontal, 24) }
                switch load {
                case .failed(let why)?:
                    VStack(spacing: 14) {
                        notice(symbol: "exclamationmark.triangle.fill", title: "Could not read this forum", detail: why)
                        PillButton(id: "dc-retry", title: "Try again", symbol: "arrow.clockwise") { actions.loadForum(channel.id, true) }
                    }.padding(.horizontal, 24)
                case .loading? where posts.isEmpty, nil:
                    HStack(spacing: 10) { ProgressView(); Text("Reading posts").font(.subheadline).foregroundStyle(Theme.textDim) }.frame(maxWidth: .infinity).padding(40)
                default:
                    if posts.isEmpty {
                        notice(symbol: "text.bubble", title: "No posts here yet", detail: "Nobody has posted in this \(channel.kind == .media ? "media channel" : "forum") recently.").padding(.horizontal, 24)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: short ? 8 : 12) { ForEach(posts) { postCard($0) } }
                                .padding(.horizontal, short ? 14 : 24).padding(.bottom, 24).background(PointerScroll())
                        }
                    }
                }
            }
            .task(id: channel.id) { actions.loadForum(channel.id, false) }
        }
    }

    private func postCard(_ post: DiscordForumPost) -> some View {
        Button { openPost = post } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if post.pinned { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Theme.accent) }
                        Text(post.title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if !post.preview.isEmpty { Text(post.preview).font(.system(size: 14)).foregroundStyle(Theme.text.opacity(0.8)).lineLimit(2).multilineTextAlignment(.leading) }
                    if !post.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(post.tags.prefix(3), id: \.self) { tag in
                                Text(tag).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.panelHigh, in: Capsule())
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text("\(post.ownerName ?? "Someone")").font(.footnote.weight(.semibold))
                        Text("\u{00B7} \(post.replies) repl\(post.replies == 1 ? "y" : "ies")").font(.footnote)
                        if let when = post.lastActivity { Text("\u{00B7} \(Self.when(when))").font(.footnote) }
                        if post.locked { Image(systemName: "lock.fill").font(.system(size: 11)) }
                    }
                    .foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let thumb = post.thumbnail {
                    AsyncImage(url: thumb) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Theme.panelHigh }
                    }
                    .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusTarget("dc-post-\(post.id)", radius: 16) { openPost = post }
    }

    /// Leave, Mute and Deafen (or Join). The same buttons go in a row, or one under the other when the pane is too narrow for the row.
    @ViewBuilder private func voiceButtons(inThis: Bool, guild: DiscordGuild, channel: DiscordGuild.Channel) -> some View {
        if inThis {
            PillButton(id: "dc-leave", title: "Leave", symbol: "phone.down.fill", style: .danger) { actions.leave() }
            PillButton(id: "dc-mute", title: data.muted ? "Unmute" : "Mute", symbol: data.muted ? "mic.fill" : "mic.slash.fill") { actions.toggleMute() }
            PillButton(id: "dc-deafen", title: data.deafened ? "Undeafen" : "Deafen", symbol: data.deafened ? "speaker.wave.2.fill" : "speaker.slash.fill") { actions.toggleDeafen() }
        } else {
            PillButton(id: "dc-join", title: data.currentChannelID == nil ? "Join voice" : "Switch to this channel", symbol: "speaker.wave.2.fill", style: .primary) { join(guild, channel) }
        }
    }

    /// A voice channel scrolls (it is taller than a phone held sideways when many people are in it): it follows the controller's focus, and goes to the person panel when somebody is picked.
    private func voiceScroll(guild: DiscordGuild, channel: DiscordGuild.Channel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                voicePane(guild: guild, channel: channel)
                    .padding(.horizontal, 24).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(PointerScroll())
            }
            .onChange(of: scope.scrollTick) { _, _ in
                if let id = scope.scrollRequest { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: personID) { _, id in
                if id != nil { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("dc-person-panel", anchor: .center) } }
            }
        }
    }

    /// One person of the call: how loud they are for this phone, and a mute that is only for this phone too (the others still hear them).
    private func personPanel(_ m: CallMember) -> some View {
        let value = data.people.volume(m.id)
        let set: (Double) -> Void = { actions.setPersonVolume(m.id, min(200, max(0, $0))) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(m.name).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(data.people.isMuted(m.id) ? "Muted" : "\(Int(value))%").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: set), in: 0...200, step: 5).tint(Theme.accent)
                .focusTarget("slider:dc-person", radius: 8, scale: 1.0, adjust: { step in set(value + Double(step) * 5) }) {}
            if m.streaming {
                PillButton(id: "dc-p-watch", title: "Watch \(m.name)'s stream", symbol: "play.rectangle.fill", style: .primary) { actions.watch(m.id) }
            }
            PillButton(id: "dc-p-mute", title: data.people.isMuted(m.id) ? "Unmute for me" : "Mute for me", symbol: data.people.isMuted(m.id) ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                actions.setPersonMuted(m.id, !data.people.isMuted(m.id))
            }
            Text("Only for you: the others in the call still hear them as before.").font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .id("dc-person-panel")
    }

    private func voicePane(guild: DiscordGuild, channel: DiscordGuild.Channel) -> some View {
        let members = data.roster[channel.id] ?? []
        let inThis = data.currentChannelID == channel.id
        return VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { voiceButtons(inThis: inThis, guild: guild, channel: channel) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { voiceButtons(inThis: inThis, guild: guild, channel: channel).fixedSize(horizontal: true, vertical: false) }
            }
            if inThis, let status = data.callStatus {
                Label(status, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.good)
            }
            Text(members.isEmpty ? "Nobody is in this channel." : "In this channel, \(members.count)").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(0.5)
                .foregroundStyle(Theme.textDim).textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(members) { m in
                    let adjustable = inThis && !m.isSelf
                    let chosen = adjustable && personID == m.id
                    Button { if adjustable { personID = chosen ? nil : m.id } } label: {
                        VStack(spacing: 8) {
                            DiscordFace(url: m.avatarURL, name: m.name, size: 60, speaking: m.speaking)
                                .overlay(alignment: .bottomTrailing) {
                                    if data.people.isMuted(m.id) { Image(systemName: "speaker.slash.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent).padding(5).background(Theme.warn, in: Circle()) }
                                }
                            Text(m.isSelf ? "\(m.name) (you)" : m.name).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(chosen ? Theme.accent : .clear, lineWidth: 2))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topLeading) { if m.streaming { DiscordLiveBadge().padding(8) } }
                    .overlay(alignment: .topTrailing) {
                        Button { profileRequest = ProfileRequest(user: DiscordUser(id: m.id, username: m.name, globalName: m.name, avatar: nil, discriminator: nil)) } label: {
                            Image(systemName: "person.crop.circle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textDim).frame(width: 40, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("\(m.name)'s profile")
                        .focusTarget("dc-pi-\(m.id)", radius: 12, scale: 1.0, label: "Profile") { profileRequest = ProfileRequest(user: DiscordUser(id: m.id, username: m.name, globalName: m.name, avatar: nil, discriminator: nil)) }
                    }
                    .focusTarget("dc-p-\(m.id)", radius: 16) { if adjustable { personID = chosen ? nil : m.id } }
                }
            }
            if inThis, let id = personID, let m = members.first(where: { $0.id == id }) { personPanel(m) }
        }
    }

    // MARK: Messages

    private func refreshButton(_ channel: DiscordGuild.Channel) -> some View { refreshButton(id: channel.id) }

    private func refreshButton(id: String, forum: Bool = false) -> some View {
        Button { if forum { actions.loadForum(id, true) } else { actions.loadMessages(id, true) } } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).frame(width: short ? 34 : 40, height: short ? 34 : 40).background(Theme.panelHigh, in: Circle())
        }
        .buttonStyle(.plain)
        .focusTarget("dc-refresh", radius: 20) { if forum { actions.loadForum(id, true) } else { actions.loadMessages(id, true) } }
        .accessibilityLabel("Read the messages again")
    }

    @ViewBuilder private func textPane(_ channel: DiscordGuild.Channel) -> some View {
        if channel.readsMessages {
            messagesPane(channel)
        } else if channel.isForum {
            forumPane(channel)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let topic = channel.topic { Text(topic).font(.subheadline).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                notice(symbol: "text.bubble.fill", title: "\(channel.kindTitle) posts are not shown yet", detail: "Porthole reads the messages of text and announcement channels. Open this one in Discord.")
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    @ViewBuilder private func messagesPane(_ channel: DiscordGuild.Channel) -> some View {
        messagesPane(id: channel.id, prompt: "Message #\(channel.name)", topic: channel.topic)
    }

    /// The messages of one channel or conversation and the box to write in: the same pane for a server's text channel and for a direct message.
    @ViewBuilder private func messagesPane(id: String, prompt: String, topic: String?) -> some View {
        let load = data.messageLoad[id]
        let list = data.messages[id] ?? []
        VStack(alignment: .leading, spacing: short ? 4 : 8) {
            if let topic, !short { Text(topic).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(2).padding(.horizontal, 24) }
            switch load {
            case .failed(let why)?:
                VStack(spacing: 14) {
                    notice(symbol: "exclamationmark.triangle.fill", title: "Could not read this channel", detail: why)
                    PillButton(id: "dc-retry", title: "Try again", symbol: "arrow.clockwise") { actions.loadMessages(id, true) }
                }.padding(.horizontal, 24)
            case .loading? where list.isEmpty, nil:
                HStack(spacing: 10) { ProgressView(); Text("Reading messages").font(.subheadline).foregroundStyle(Theme.textDim) }.frame(maxWidth: .infinity).padding(40)
            default:
                if list.isEmpty {
                    notice(symbol: "text.bubble", title: "No messages here yet", detail: "Nothing was said in this channel recently.").padding(.horizontal, 24)
                } else {
                    messageList(list, in: id)
                }
            }
            if load == .loaded {
                if let names = data.typing[id], !names.isEmpty {
                    Label(Self.typingText(names), systemImage: "ellipsis.bubble").font(.caption).foregroundStyle(Theme.textDim).lineLimit(1).padding(.horizontal, short ? 14 : 24)
                }
                DiscordComposer(prompt: prompt, text: Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 }),
                                sending: data.sending.contains(id), error: data.sendError[id], compact: short, context: composerContext(id), cancelContext: { cancelContext(id) }) { trySend(id) }
                    .padding(.horizontal, short ? 14 : 24).padding(.bottom, short ? 4 : 16).padding(.top, short ? 0 : 4)
            }
        }
        .task(id: id) { actions.loadMessages(id, false) }
        .alert("Send messages from an unofficial client?", isPresented: Binding(get: { confirmSend != nil }, set: { if !$0 { confirmSend = nil } })) {
            Button("Send") { UserDefaults.standard.set(true, forKey: Self.sendAckKey); if let id = confirmSend { performSend(id) }; confirmSend = nil }
            Button("Cancel", role: .cancel) { confirmSend = nil }
        } message: {
            Text("Porthole is not an official Discord client. Discord's terms do not allow third-party clients, and an account that sends messages through one can be limited or banned. Use an account you can afford to lose. This is asked once.")
        }
    }

    /// Send was pressed. The first message ever sent asks once, because this is the most visible thing an unofficial client does.
    private func trySend(_ channelID: String) {
        guard UserDefaults.standard.bool(forKey: Self.sendAckKey) else { confirmSend = channelID; return }
        performSend(channelID)
    }

    private func performSend(_ channelID: String) {
        if let m = editing[channelID] {
            actions.editMessage(channelID, m.id, drafts[channelID] ?? "") { ok in if ok { drafts[channelID] = nil; editing[channelID] = nil } }
        } else {
            actions.sendMessage(channelID, drafts[channelID] ?? "", replyingTo[channelID]?.id) { ok in if ok { drafts[channelID] = nil; replyingTo[channelID] = nil } }
        }
    }

    private func notice(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Theme.textDim)
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The messages, newest at the bottom; it opens at the bottom and stays there while new ones arrive. Each block is a stop for the D-pad, which scrolls the list.
    private func messageList(_ list: [DiscordMessage], in channelID: String) -> some View {
        let groups = DiscordMessageGroup.groups(list)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: short ? 6 : 14) {
                    olderButton(channelID)
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if DiscordMessageGroup.startsNewDay(group, after: index > 0 ? groups[index - 1] : nil) { daySeparator(group.date) }
                        messageBlock(group) { ref in jump(to: ref, in: groups, proxy: proxy) }
                    }
                    Color.clear.frame(height: 1).id("dc-m-end")
                }
                .padding(.horizontal, short ? 14 : 24).padding(.vertical, short ? 2 : 8)
                .background(PointerScroll())
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: list.last?.id) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("dc-m-end", anchor: .bottom) } }
            .onChange(of: scope.scrollTick) { _, _ in
                if let id = scope.scrollRequest { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// A line between two days: "Today", "Yesterday", a weekday or a date.
    private func daySeparator(_ date: Date) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text(DiscordMessageGroup.dayTitle(date)).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(Theme.textDim).fixedSize()
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .padding(.vertical, short ? 2 : 6).accessibilityElement(children: .combine)
    }

    /// Scrolls to the message another one answers and lights it for a moment (when it is among the messages shown).
    private func jump(to messageID: String, in groups: [DiscordMessageGroup], proxy: ScrollViewProxy) {
        guard let group = groups.first(where: { $0.messages.contains { $0.id == messageID } }) else { return }
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("dc-m-\(group.id)", anchor: .center) }
        flash = group.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if flash == group.id { flash = nil } }
    }

    private func messageBlock(_ group: DiscordMessageGroup, jump: @escaping (String) -> Void) -> some View {
        HStack(alignment: .top, spacing: short ? 10 : 12) {
            Button { profileRequest = ProfileRequest(user: group.author) } label: {
                DiscordFace(url: group.author.avatarURL, name: group.author.displayName, size: short ? 30 : 38, speaking: false)
            }
            .buttonStyle(.plain).accessibilityLabel("\(group.author.displayName)'s profile")
            .focusTarget("dc-ma-\(group.id)", radius: 20, label: "Profile") { profileRequest = ProfileRequest(user: group.author) }
            VStack(alignment: .leading, spacing: 4) {
                if let reply = group.messages[0].replyTo {
                    Button { if let ref = group.messages[0].referenceID { jump(ref) } } label: {
                        Label(reply, systemImage: "arrowshape.turn.up.left.fill").font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    .buttonStyle(.plain).accessibilityHint("Goes to the message it answers")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { profileRequest = ProfileRequest(user: group.author) } label: {
                        Text(group.author.displayName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Text(Self.when(group.date)).font(.caption).foregroundStyle(Theme.textDim)
                }
                ForEach(group.messages) { m in messageBody(m).contextMenu { messageMenuItems(m) } }
            }
            Spacer(minLength: 0)
        }
        .padding(short ? 4 : 8).frame(maxWidth: .infinity, alignment: .leading)
        .background(flash == group.id ? Theme.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: flash)
        .focusTarget("dc-m-\(group.id)", radius: 12, glow: true, secondary: { actionsFor = group.messages.last }, secondaryLabel: "Actions") {}
        .id("dc-m-\(group.id)")
    }

    private func messageBody(_ m: DiscordMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !m.content.isEmpty {
                (Text(Self.styled(m.content)) + (m.edited ? Text("  (edited)").font(.caption).foregroundStyle(Theme.textDim) : Text("")))
                    .font(.system(size: short ? 14 : 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(m.attachments) { a in
                if a.isImage, let url = a.url {
                    Button { imageRequest = ImageRequest(url: url, name: a.name) } label: {
                        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Theme.panelHigh.overlay(ProgressView()) }
                            .frame(maxWidth: 320, maxHeight: 220, alignment: .leading).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain).accessibilityLabel(a.name).accessibilityHint("Opens the picture")
                } else {
                    Label(a.name, systemImage: "paperclip").font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            ForEach(m.embeds) { embedCard($0) }
            ForEach(m.stickers) { s in
                AsyncImage(url: s.url) { phase in if let image = phase.image { image.resizable().scaledToFit() } else { Theme.panelHigh } }
                    .frame(width: 120, height: 120).accessibilityLabel("Sticker: \(s.name)")
            }
            ForEach(m.extras, id: \.self) { extra in Label(extra, systemImage: "link").font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1) }
            if !m.reactions.isEmpty {
                FlowLayout(spacing: 6) { ForEach(m.reactions) { r in reactionChip(m, r) } }.padding(.top, 2)
            }
        }
    }

    /// A card Discord made of a link (or a bot sent): its colour bar, who it is from, the title, the text, fields and a picture.
    private func embedCard(_ e: DiscordMessage.Embed) -> some View {
        let bar = e.colour.map { Color(hex: $0) } ?? Theme.accent
        return HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(bar).frame(width: 4)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let provider = e.provider { Text(provider).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
                    if let author = e.author { Text(author).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1) }
                    if let title = e.title { Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                    if let text = e.description { Text(Self.styled(text)).font(.system(size: 14)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(8).fixedSize(horizontal: false, vertical: true) }
                    ForEach(Array(e.fields.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                            Text(Self.styled(f.value)).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let url = e.imageURL {
                        Button { imageRequest = ImageRequest(url: url, name: e.title ?? "") } label: {
                            AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFit() } else { Theme.panelHigh.overlay(ProgressView()) } }
                                .frame(maxWidth: 360, maxHeight: 240, alignment: .leading).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .bottomLeading) { if e.isAnimated { Text("GIF").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.6), in: Capsule()).padding(6) } }
                        }
                        .buttonStyle(.plain).accessibilityLabel(e.title ?? "Picture").accessibilityHint("Opens the picture")
                    }
                    if let footer = e.footer { Text(footer).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if e.imageURL == nil, let thumb = e.thumbnailURL {
                    AsyncImage(url: thumb) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { Theme.panelHigh } }
                        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(12)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reactionChip(_ m: DiscordMessage, _ r: DiscordMessage.Reaction) -> some View {
        Button { actions.toggleReaction(m.channelID, m.id, r.name, r.customID, r.animated) } label: {
            HStack(spacing: 5) {
                if let url = r.imageURL {
                    AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFit() } else { Color.clear } }.frame(width: 18, height: 18)
                } else { Text(r.name).font(.system(size: 15)) }
                Text("\(r.count)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(r.me ? Theme.accent : Theme.textDim).monospacedDigit()
            }
            .padding(.horizontal, 9).frame(minHeight: 28)
            .background(r.me ? Theme.accent.opacity(0.2) : Theme.panelHigh, in: Capsule())
            .overlay(Capsule().strokeBorder(r.me ? Theme.accent : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(r.name), \(r.count)\(r.me ? ", you reacted" : "")")
        .focusTarget("dc-r-\(m.id)-\(r.id)", radius: 14, scale: 1.0) { actions.toggleReaction(m.channelID, m.id, r.name, r.customID, r.animated) }
    }

    /// What can be done with a message: answer it, react to it, copy its text, and (on your own) edit or delete it. Shown by a long press, and by X on a controller.
    @ViewBuilder fileprivate func messageMenuItems(_ m: DiscordMessage) -> some View {
        Button { editing[m.channelID] = nil; replyingTo[m.channelID] = m } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        ForEach(Self.quickEmoji, id: \.self) { e in Button("React \(e)") { actions.toggleReaction(m.channelID, m.id, e, nil, false) } }
        if !m.content.isEmpty { Button { UIPasteboard.general.string = m.content } label: { Label("Copy text", systemImage: "doc.on.doc") } }
        if m.author.id == data.meID {
            Button { replyingTo[m.channelID] = nil; editing[m.channelID] = m; drafts[m.channelID] = m.content } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { deleting = m } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// "Replying to Alex: ..." or "Editing your message", above the box.
    private func composerContext(_ id: String) -> (title: String, symbol: String)? {
        if editing[id] != nil { return ("Editing your message", "pencil") }
        if let m = replyingTo[id] {
            let text = m.content.isEmpty ? "an attachment" : String(m.content.prefix(60))
            return ("Replying to \(m.author.displayName): \(text)", "arrowshape.turn.up.left.fill")
        }
        return nil
    }

    private func cancelContext(_ id: String) {
        if editing[id] != nil { drafts[id] = nil }
        editing[id] = nil; replyingTo[id] = nil
    }

    private func olderButton(_ id: String) -> some View {
        Group {
            switch data.olderState[id] {
            case .done?: EmptyView()
            case .loading?: HStack(spacing: 8) { ProgressView(); Text("Reading earlier messages").font(.footnote).foregroundStyle(Theme.textDim) }.frame(maxWidth: .infinity).padding(.vertical, 6)
            case nil:
                Button { actions.loadOlder(id) } label: {
                    Label("Load earlier messages", systemImage: "arrow.up.circle").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 40).background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain).focusTarget("dc-older", radius: 20) { actions.loadOlder(id) }
            }
        }
    }

    /// "Alex is typing", "Alex and Sam are typing", "Several people are typing".
    static func typingText(_ names: [String]) -> String {
        switch names.count {
        case 1: "\(names[0]) is typing\u{2026}"
        case 2: "\(names[0]) and \(names[1]) are typing\u{2026}"
        default: "Several people are typing\u{2026}"
        }
    }

    /// "8:10 PM" for today, else the date and time.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Discord's bold, italics and code, without making links tappable (links are opened only after the confirmation Porthole asks elsewhere).
    static func styled(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs where run.link != nil { out[run.range].link = nil }
        return out
    }

    // MARK: Messages (direct messages and group chats)

    private var conversationList: some View {
        VStack(spacing: 0) {
            if wide {
                HStack {
                    Text("Messages").font(.system(size: short ? 16 : 19, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, short ? 10 : 20).padding(.bottom, short ? 6 : 12)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(data.conversations) { c in
                        Button { openConversation(c) } label: {
                            DiscordConversationRow(title: c.title, users: c.users, isGroup: c.isGroup, preview: data.messages[c.id]?.last.map(Self.preview), selected: conversationID == c.id, unread: data.unread[c.id] ?? 0)
                        }
                        .buttonStyle(.plain)
                        .focusTarget("dc-dm-\(c.id)", radius: 12) { openConversation(c) }
                    }
                    if data.conversations.isEmpty { emptyNote("No conversations yet. Open a person's card and press Message.") }
                }
                .padding(.horizontal, short ? 6 : 10).padding(.bottom, short ? 8 : 20).padding(.top, wide ? 0 : 6)
            }
        }
        .background(Theme.panel.opacity(0.3))
    }

    /// The start of a message, for the list.
    private static func preview(_ m: DiscordMessage) -> String {
        if !m.content.isEmpty { return m.content.replacingOccurrences(of: "\n", with: " ") }
        return m.attachments.isEmpty ? "" : "Attachment"
    }

    private func openConversation(_ c: DiscordBrowserData.Conversation) {
        conversationID = c.id
        if !wide { level = .channel }
        DispatchQueue.main.async { scope.start(at: "dc-dm-\(c.id)") }
    }

    @ViewBuilder private var conversationPane: some View {
        if let c = conversation {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: short ? 8 : 12) {
                    Image(systemName: c.isGroup ? "person.3.fill" : "at").font(.system(size: short ? 16 : 20, weight: .semibold)).foregroundStyle(Theme.textDim)
                    Text(c.title).font(.system(size: short ? 18 : 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    if !c.isGroup, let user = c.users.first { roundButton("person.crop.circle", id: "dc-dm-profile", label: "Profile") { profileRequest = ProfileRequest(user: user) } }
                    roundButton("phone.fill", id: "dc-dm-call", label: "Call") { actions.callDirect(c.id) }
                    refreshButton(id: c.id)
                }
                .padding(.horizontal, short ? 18 : 24).padding(.top, short ? 8 : 24).padding(.bottom, short ? 6 : 14)
                messagesPane(id: c.id, prompt: "Message \(c.title)", topic: nil)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 44)).foregroundStyle(Theme.textDim)
                Text("Pick a conversation").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text("Open a person's card from a message or the friends list and press Message to start one.").font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func roundButton(_ symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).frame(width: short ? 34 : 40, height: short ? 34 : 40).background(Theme.panelHigh, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
        .focusTarget(id, radius: 20, action: action)
    }

    // MARK: People

    fileprivate func profileSheet(_ user: DiscordUser) -> some View {
        let friend = data.friends.first { $0.id == user.id }
        return DiscordProfileCard(user: friend?.user ?? user, isSelf: user.id == data.meID, status: friend?.status, activity: friend?.activity,
                                  serverName: { id in data.guilds.first { $0.id == id }?.name },
                                  load: { done in actions.loadProfile(user.id, done) },
                                  message: { messageUser(user) }, call: { messageUser(user, thenCall: true) }, close: { profileRequest = nil })
            .preferredColorScheme(Theme.scheme)
    }

    /// Message or Call on a card: opens the conversation with them (made when there is none) and shows it; Call also rings.
    private func messageUser(_ user: DiscordUser, thenCall: Bool = false) {
        actions.openDirect(user.id) { cid in
            guard let cid else { openError = "Discord would not open a conversation with \(user.displayName)."; return }
            profileRequest = nil
            place = .messages; conversationID = cid
            UserDefaults.standard.set("messages", forKey: Self.placeKey)
            if !wide { level = .channel }
            if thenCall { actions.callDirect(cid) }
            DispatchQueue.main.async { scope.start(at: "dc-dm-\(cid)", force: true) }
        }
    }

    // MARK: Friends

    private var friendsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Friends").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
            if let title = data.directCall { directCallBar(title).padding(.horizontal, 16).padding(.bottom, 8) }
            friendsList
        }
    }

    /// The call this account is in with a friend or group: it is in no server, so it has no channel to open; this is where to leave it or mute.
    private func directCallBar(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("In a call: \(title)", systemImage: "phone.fill").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.good).lineLimit(1)
            if let status = data.callStatus { Text(status).font(.footnote).foregroundStyle(Theme.textDim) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { directCallButtons.fixedSize(horizontal: true, vertical: false) }
                VStack(alignment: .leading, spacing: 10) { directCallButtons.fixedSize(horizontal: true, vertical: false) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var directCallButtons: some View {
        PillButton(id: "dc-leave", title: "Leave", symbol: "phone.down.fill", style: .danger) { actions.leave() }
        PillButton(id: "dc-mute", title: data.muted ? "Unmute" : "Mute", symbol: data.muted ? "mic.fill" : "mic.slash.fill") { actions.toggleMute() }
        PillButton(id: "dc-deafen", title: data.deafened ? "Undeafen" : "Deafen", symbol: data.deafened ? "speaker.wave.2.fill" : "speaker.slash.fill") { actions.toggleDeafen() }
    }

    private var friendsList: some View {
        func byName(_ list: [DiscordFriend]) -> [DiscordFriend] { list.sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending } }
        func inCall(_ f: DiscordFriend) -> Bool { FriendCall.of(person: f.id, roster: data.roster, guilds: data.guilds) != nil }
        // Anybody in a voice channel is listed first, whatever their status says (a friend who appears offline can still be in a call).
        let calling = byName(data.friends.filter(inCall))
        let online = byName(data.friends.filter { $0.status.isOnline && !inCall($0) })
        let offline = byName(data.friends.filter { !$0.status.isOnline && !inCall($0) })
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !calling.isEmpty { friendsHeader("In a voice channel, \(calling.count)") }
                ForEach(calling) { friendRow($0) }
                if !online.isEmpty { friendsHeader("Online, \(online.count)") }
                ForEach(online) { friendRow($0) }
                if !offline.isEmpty { friendsHeader("Offline, \(offline.count)") }
                ForEach(offline) { friendRow($0) }
                if data.friends.isEmpty { emptyNote("No friends came with the connection.") }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
    }

    private func friendsHeader(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(0.6).foregroundStyle(Theme.textDim).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 2)
    }

    private func friendRow(_ f: DiscordFriend) -> some View {
        let call = FriendCall.of(person: f.id, roster: data.roster, guilds: data.guilds)
        let inMine = call != nil && call?.channel.id == data.currentChannelID
        let row = HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                DiscordFace(url: f.user.avatarURL, name: f.user.displayName, size: 40, speaking: false)
                Circle().fill(f.status.isOnline ? Theme.good : Theme.textDim).frame(width: 12, height: 12).overlay(Circle().stroke(Theme.backgroundTop, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(f.user.displayName).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if let call {
                    Label("In \(call.label)", systemImage: "waveform").font(.footnote.weight(.semibold)).foregroundStyle(Theme.good).lineLimit(1)
                } else {
                    Text(f.activity ?? f.status.title).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            if call != nil {
                Text(inMine ? "In your call" : "Join").font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                    .foregroundStyle(inMine ? Theme.textDim : Theme.onAccent).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(inMine ? AnyShapeStyle(Theme.panelHigh) : AnyShapeStyle(Theme.accentGradient), in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 52)
        .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        return Group {
            if let call, !inMine {
                // The picture and name open their card; the Join pill joins the channel they are in.
                HStack(spacing: 8) {
                    Button { profileRequest = ProfileRequest(user: f.user) } label: { row.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                        .buttonStyle(.plain).accessibilityHint("Opens their profile")
                }
                .overlay(alignment: .trailing) {
                    Button { joinFriend(call) } label: { Color.clear.frame(width: 96, height: 52).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Join their voice channel")
                }
                .focusTarget("dc-f-\(f.id)", radius: 12, glow: true, secondary: { joinFriend(call) }, label: "Profile", secondaryLabel: "Join") { profileRequest = ProfileRequest(user: f.user) }
            } else {
                Button { profileRequest = ProfileRequest(user: f.user) } label: { row.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                    .buttonStyle(.plain).accessibilityHint("Opens their profile")
                    .focusTarget("dc-f-\(f.id)", radius: 12, glow: true, label: "Profile") { profileRequest = ProfileRequest(user: f.user) }
            }
        }
    }

    /// Joins the voice channel a friend is in, and opens that server and channel so the call is in front of you.
    private func joinFriend(_ call: FriendCall) {
        place = .guild(call.guild.id)
        UserDefaults.standard.set(call.guild.id, forKey: Self.placeKey)
        channelID = call.channel.id
        if !wide { level = .channel }
        actions.join(call.guild, call.channel)
        DispatchQueue.main.async { focusStart() }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
    }

    // MARK: Moving around

    private func open(_ new: Place) {
        place = new
        if case .guild(let id) = new {
            UserDefaults.standard.set(id, forKey: Self.placeKey)
            if let g = data.guilds.first(where: { $0.id == id }), channelID == nil || g.channel(channelID!) == nil {
                channelID = g.sections.flatMap(\.channels).first(where: { $0.id == data.currentChannelID })?.id ?? g.sections.flatMap(\.channels).first?.id
            }
        } else if new == .messages {
            UserDefaults.standard.set("messages", forKey: Self.placeKey)
            if conversationID == nil || conversation == nil { conversationID = data.conversations.first?.id }
        } else { UserDefaults.standard.removeObject(forKey: Self.placeKey) }
        if !wide { level = .channels }
        DispatchQueue.main.async { focusStart() }
    }

    private func openChannel(_ c: DiscordGuild.Channel) {
        channelID = c.id
        if !wide { level = .channel }
        DispatchQueue.main.async { scope.start(at: c.isVoice ? "dc-join" : "dc-c-\(c.id)") }
    }

    private func join(_ g: DiscordGuild, _ c: DiscordGuild.Channel) {
        channelID = c.id
        actions.join(g, c)
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    /// B: one step back on a phone held upright; with the three columns on screen it closes (the scope's own back).
    private func stepBack() -> Bool {
        guard !wide else { return false }
        switch level {
        case .channel: level = .channels; return true
        case .channels: level = .servers; return true
        case .servers: return false
        }
    }

    /// The bumpers: the next or previous server in the rail.
    private func cycleServer(_ step: Int) {
        let places: [Place] = [.friends, .messages] + data.guilds.map { .guild($0.id) }
        guard let index = places.firstIndex(of: place) else { return }
        let next = places[(index + step + places.count) % places.count]
        place = next
        if case .guild(let id) = next, let g = data.guilds.first(where: { $0.id == id }) {
            channelID = g.sections.flatMap(\.channels).first?.id
        }
        if !wide { level = .channels }
        DispatchQueue.main.async { focusStart() }
    }

    private func restore() {
        if UserDefaults.standard.string(forKey: Self.placeKey) == "messages" || UserDefaults.standard.bool(forKey: "f4.discordMessages") {
            place = .messages
            if conversationID == nil { conversationID = data.conversations.first?.id }
        } else if let saved = UserDefaults.standard.string(forKey: Self.placeKey), data.guilds.contains(where: { $0.id == saved }) {
            place = .guild(saved)
            if channelID == nil, let g = data.guilds.first(where: { $0.id == saved }) {
                channelID = g.sections.flatMap(\.channels).first(where: { $0.id == data.currentChannelID })?.id ?? g.sections.flatMap(\.channels).first?.id
            }
        } else if let current = data.currentChannelID, let g = data.guilds.first(where: { $0.channel(current) != nil }) {
            place = .guild(g.id); channelID = current
        }
        // A preview launch argument opens one channel of the server.
        if case .guild(let id) = place, let c = UserDefaults.standard.string(forKey: "f4.discordChannel"), data.guilds.first(where: { $0.id == id })?.channel(c) != nil { channelID = c }
        if !wide, place != .friends { level = .channels }
        // A preview launch argument opens one person's card.
        if let id = UserDefaults.standard.string(forKey: "f4.discordProfile"), let f = data.friends.first(where: { $0.id == id }) { profileRequest = ProfileRequest(user: f.user) }
    }

    private func focusStart() {
        switch place {
        case .friends: scope.start(at: "dc-friends", force: true)
        case .messages: scope.start(at: conversationID.map { "dc-dm-\($0)" } ?? "dc-messages", force: true)
        case .guild(let id): scope.start(at: channelID.map { "dc-c-\($0)" } ?? "dc-s-\(id)", force: true)
        }
    }
}

/// Gives the browser its own controller layer only when it is a screen of its own; in the Social tab it uses the tab's.
private struct OwnScope: ViewModifier {
    let active: Bool
    let scope: FocusScope
    func body(content: Content) -> some View {
        if active { content.navScope(scope) } else { content }
    }
}

/// A server's picture, or its first letters on the accent colour when it has none.
struct GuildIcon: View {
    let guild: DiscordGuild
    var size: CGFloat = 52
    var selected = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: selected ? size * 0.3 : size * 0.42, style: .continuous).fill(Theme.panelHigh)
            if let url = guild.iconURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { initials }
                }
            } else { initials }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: selected ? size * 0.3 : size * 0.42, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private var initials: some View {
        Text(guild.initials).font(.system(size: size * 0.36, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
    }
}

/// A person's picture in a circle (their first letter without one), with a green ring while they talk.
struct DiscordFace: View {
    let url: URL?
    let name: String
    var size: CGFloat = 32
    var speaking = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.panelHigh)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { letter }
                }
            } else { letter }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(speaking ? Theme.good : .clear, lineWidth: max(2, size * 0.06)))
    }

    private var letter: some View {
        Text(String(name.first.map { String($0).uppercased() } ?? "?")).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
    }
}

/// The sheets, covers, menu and questions of the browser, in a modifier of their own so the screen's `body` stays small enough to compile.
private struct DiscordBrowserDialogs: ViewModifier {
    let browser: DiscordBrowser

    func body(content: Content) -> some View {
        content
            .sheet(item: browser.$profileRequest) { request in browser.profileSheet(request.user) }
            .fullScreenCover(item: browser.$imageRequest) { r in DiscordImageViewer(url: r.url, name: r.name, close: { browser.imageRequest = nil }) }
            .confirmationDialog("Message", isPresented: browser.actionsBinding, presenting: browser.actionsFor) { m in browser.messageMenuItems(m) }
            .alert("Delete this message?", isPresented: browser.deletingBinding) {
                Button("Delete", role: .destructive) { browser.confirmDelete() }
                Button("Cancel", role: .cancel) { browser.deleting = nil }
            } message: { Text("It is removed from Discord for everyone. This cannot be undone.") }
            .alert("Could not open it", isPresented: browser.openErrorBinding) { Button("OK", role: .cancel) {} } message: { Text(browser.openError ?? "") }
    }
}
