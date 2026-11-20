// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The Discord tab of the in-game menu (Discord branch, experimental): join a server's voice channel, mute, leave, from inside the running game. It shows only when Discord
/// features are switched on in the Social tab.
struct DiscordTab: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject private var discord = DiscordSession.shared
    @ObservedObject private var overlay = DiscordOverlaySettings.shared
    @State private var pickedGuild: String?
    @State private var pickedPerson: String?
    @ObservedObject private var notifier = DiscordNotifier.shared
    /// The conversation a banner (or the list of new messages) opened, to read and answer here.
    @State private var conversation: DiscordConversation?
    @State private var draft = ""
    @State private var askingAck = false

    var body: some View {
        content
            .onAppear { adoptFocus() }
            // Back out of a conversation (B, the Back button, a swipe) and it is closed.
            .onChange(of: model.page) { _, page in if page != .discordConversation { conversation = nil } }
    }

    @ViewBuilder private var content: some View {
        switch discord.state {
        case .connected:
            switch model.page {
            case .discordPeople?: membersCard
            case .discordLive?: liveCard
            case .discordConversation?: if let conversation { conversationCard(conversation) }
            case .discordServers?:
                serversCard
                channelCards
                if discord.guilds.isEmpty { MenuCard(title: "Servers", footer: "No server came with the connection.") { EmptyView() } }
            case .discordVoice?:
                volumeCard
                micCard
                overlayCard
            case .discordFriends?: friendsCard
            case .discordNotify?: notificationsCard
            default: root
            }
        case .connecting:
            MenuCard(title: "Discord", footer: "Connecting to Discord.") { EmptyView() }
        case .failed(let message):
            MenuCard(title: "Discord", footer: message) {
                MenuActionRow(title: "Try again", symbol: "arrow.clockwise") { discord.retry() }
            }
        default:
            MenuCard(title: "Discord", footer: "Not signed in. Sign in in the Social tab of Porthole.") { EmptyView() }
        }
    }

    /// What matters now (a ringing call, new messages, the call you are in), then a row for each of the rest, each opening a page of its own.
    @ViewBuilder private var root: some View {
        incomingCallCard
        callCard
        newMessagesCards
        MenuCard(title: "Discord") {
            MenuNavRow(id: MenuPage.discordServers.rawValue, symbol: "rectangle.3.group.bubble.left.fill", tint: Theme.accent, title: "Servers and channels",
                       value: shownGuild?.name ?? "\(discord.guilds.count) servers") { model.page = .discordServers }
            MenuDivider()
            MenuNavRow(id: MenuPage.discordVoice.rawValue, symbol: "speaker.wave.2.fill", tint: .green, title: "Voice and sound",
                       value: "Call \(Int(discord.callVolume))%") { model.page = .discordVoice }
            MenuDivider()
            MenuNavRow(id: MenuPage.discordFriends.rawValue, symbol: "person.2.fill", tint: .blue, title: "Friends",
                       value: "\(discord.sortedFriends.filter { $0.status.isOnline }.count) online") { model.page = .discordFriends }
            MenuDivider()
            MenuNavRow(id: MenuPage.discordNotify.rawValue, symbol: "bell.badge.fill", tint: .orange, title: "Notifications",
                       value: notifier.enabled || notifier.callBanners ? [notifier.enabled ? notifier.kind.title : nil, notifier.callBanners ? "calls" : nil].compactMap { $0 }.joined(separator: ", ") : "Off") { model.page = .discordNotify }
        }
    }

    // MARK: Messages and notifications

    /// A call ringing for this account: Join or Decline from the menu (with a controller this is the way; over the game a banner does the same).
    @ViewBuilder private var incomingCallCard: some View {
        if let call = notifier.incomingCall {
            MenuCard(title: call.headline, footer: "Join answers the call. Decline stops it ringing for you.") {
                MenuActionRow(title: "Join", symbol: "phone.fill", focusID: "dc-call-join") { notifier.answerCall() }
                MenuDivider()
                MenuActionRow(title: "Decline", symbol: "phone.down.fill", destructive: true, focusID: "dc-call-decline") { notifier.declineCall() }
            }
        }
    }

    /// The messages that notified lately: tap one to read it and answer (it opens as a page of its own, so B goes back).
    @ViewBuilder private var newMessagesCards: some View {
        if !notifier.recent.isEmpty {
            MenuCard(title: "New messages") {
                ForEach(Array(notifier.recent.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { MenuDivider() }
                    MenuActionRow(title: item.author.displayName + (item.conversation.isDirect ? "" : " in \(item.conversation.title)"), symbol: item.conversation.isDirect ? "person.fill" : "number",
                                  detail: item.text, focusID: "dc-new-\(item.id)") { open(item.conversation) }
                }
            }
        }
    }

    /// A tapped banner left the conversation to open in `notifier.focus`. (Set a moment later: the menu clears its page as it opens.)
    private func adoptFocus() {
        guard let id = notifier.focus, let item = notifier.recent.first(where: { $0.conversation.id == id }) else { return }
        notifier.focus = nil
        DispatchQueue.main.async { open(item.conversation) }
    }

    private func open(_ c: DiscordConversation) {
        conversation = c
        draft = ""
        askingAck = false
        discord.loadMessages(c.id, force: true)
        model.page = .discordConversation
    }

    private func conversationCard(_ c: DiscordConversation) -> some View {
        let list = discord.messages[c.id] ?? []
        let groups = DiscordMessageGroup.groups(Array(list.suffix(8)))
        let sending = discord.sendingTo.contains(c.id)
        return MenuCard(title: c.isDirect ? c.title : "\(c.title) in \(c.place ?? "")", footer: nil) {
            switch discord.messageLoad[c.id] {
            case .failed(let why)?:
                Text(why).font(.system(size: 13)).foregroundStyle(Theme.warn).padding(12)
                MenuActionRow(title: "Try again", symbol: "arrow.clockwise") { discord.loadMessages(c.id, force: true) }
            case .loaded?:
                if groups.isEmpty { Text("No messages yet.").font(.system(size: 13)).foregroundStyle(Theme.textDim).padding(12) }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.author.displayName).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                            ForEach(group.messages) { m in
                                Text(m.content.isEmpty ? DiscordNotifier.preview(m) : m.content).font(.system(size: 14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                MenuDivider()
                if askingAck {
                    Text("Porthole is not an official Discord client. Discord's terms do not allow third-party clients, and an account that sends messages through one can be limited or banned. Use an account you can afford to lose. This is asked once.")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn).padding(12)
                    MenuActionRow(title: "Send anyway", symbol: "paperplane.fill") { UserDefaults.standard.set(true, forKey: DiscordBrowser.sendAckKey); askingAck = false; send(c) }
                    MenuDivider()
                    MenuActionRow(title: "Cancel", symbol: "xmark") { askingAck = false }
                } else {
                    DiscordComposer(prompt: c.isDirect ? "Message \(c.title)" : "Message \(c.title)", text: $draft, sending: sending, error: discord.sendError[c.id]) {
                        if UserDefaults.standard.bool(forKey: DiscordBrowser.sendAckKey) { send(c) } else { askingAck = true }
                    }
                    .padding(12)
                }
            default:
                HStack(spacing: 10) { ProgressView(); Text("Reading messages").font(.system(size: 13)).foregroundStyle(Theme.textDim) }.padding(12)
            }
        }
    }

    private func send(_ c: DiscordConversation) {
        discord.sendMessage(draft, to: c.id) { ok in if ok { draft = "" } }
    }

    /// Whether banners show, and which messages. The same choices as the Social tab.
    private var notificationsCard: some View {
        MenuCard(title: "Message notifications", footer: notifier.testNote ?? "A banner slides in over the game for the messages you pick. Tap it to answer here. One at a time, never while this menu is open or while you stream with Go Live.") {
            MenuToggleRow(title: "Notify me of messages", isOn: Binding(get: { notifier.enabled }, set: { notifier.enabled = $0 }))
            MenuDivider()
            MenuToggleRow(title: "Show incoming calls", detail: "A banner with Join and Decline when a friend calls you", isOn: Binding(get: { notifier.callBanners }, set: { notifier.callBanners = $0 }))
            if notifier.enabled {
                MenuDivider()
                MenuActionRow(title: "Which messages: \(notifier.kind.title)", symbol: "line.3.horizontal.decrease.circle.fill", detail: "\(notifier.kind.detail) Tap to change.") { notifier.kind = Self.next(notifier.kind) }
                MenuDivider()
                MenuToggleRow(title: "Show the message in the banner", detail: "Off: only who wrote and where", isOn: Binding(get: { notifier.showText }, set: { notifier.showText = $0 }))
                MenuDivider()
                MenuActionRow(title: "Show a test banner", symbol: "bell.fill", detail: "Close this menu and it slides in") { notifier.test() }
            }
        }
    }

    /// The server whose channels are listed: the one picked, else the one the call is in, else the first.
    private var shownGuild: DiscordGuild? {
        if let id = pickedGuild, let g = discord.guilds.first(where: { $0.id == id }) { return g }
        if let current = discord.currentVoiceChannelID, !isIdle, let g = discord.guilds.first(where: { $0.channel(current) != nil }) { return g }
        return discord.guilds.first
    }
    private var isIdle: Bool { if case .idle = discord.voiceState { return true }; return false }

    @ViewBuilder private var serversCard: some View {
        if discord.guilds.count > 1 {
            MenuCard(title: "Servers") {
                ForEach(Array(discord.guilds.enumerated()), id: \.element.id) { index, guild in
                    if index > 0 { MenuDivider() }
                    MenuChoiceRow(title: guild.name, selected: shownGuild?.id == guild.id) { pickedGuild = guild.id }
                }
            }
        }
    }

    /// The picked server's voice channels in its categories, with who is in each. (Text channels have nothing to do in a running game until chat exists.)
    @ViewBuilder private var channelCards: some View {
        if let guild = shownGuild {
            ForEach(guild.sections) { section in
                let voice = section.channels.filter(\.isVoice)
                if !voice.isEmpty {
                    MenuCard(title: section.category?.name ?? guild.name) {
                        ForEach(Array(voice.enumerated()), id: \.element.id) { index, channel in
                            if index > 0 { MenuDivider() }
                            MenuActionRow(title: channel.name, symbol: channel.symbol, detail: channelDetail(channel), focusID: "discord:\(channel.id)") {
                                discord.joinVoice(guild: guild, channel: channel)
                            }
                        }
                    }
                }
            }
            if guild.voiceChannels.isEmpty {
                MenuCard(title: guild.name, footer: "This server has no voice channel this account can see.") { EmptyView() }
            }
        }
    }

    private func channelDetail(_ channel: DiscordGuild.Channel) -> String? {
        if isCurrent(channel) { return "You are in this channel" }
        let people = discord.voiceRoster[channel.id] ?? []
        guard !people.isEmpty else { return nil }
        let names = people.prefix(3).map(\.name).joined(separator: ", ")
        return people.count > 3 ? "\(names) and \(people.count - 3) more" : names
    }

    private func isCurrent(_ channel: DiscordGuild.Channel) -> Bool {
        if case .idle = discord.voiceState { return false }
        return discord.currentVoiceChannelID == channel.id
    }

    /// The call you are in, kept short: mute, deafen, who is in it, Go Live, leave. (The details are on pages.)
    @ViewBuilder private var callCard: some View {
        switch discord.voiceState {
        case .idle:
            EmptyView()
        default:
            MenuCard(title: "Voice call", footer: callFooter) {
                MenuToggleRow(title: "Mute my microphone", isOn: Binding(get: { discord.micMuted }, set: { discord.setMicMuted($0) }))
                MenuDivider()
                MenuToggleRow(title: "Deafen (stop hearing the call)", isOn: Binding(get: { discord.deafened }, set: { discord.setDeafened($0) }))
                MenuDivider()
                MenuToggleRow(title: "Reduce echo (experimental)", detail: "Your microphone sends nothing unless you are clearly louder than the speakers. Headphones fix echo completely.", isOn: Binding(get: { discord.reduceEcho }, set: { discord.reduceEcho = $0 }))
                MenuDivider()
                MenuToggleRow(title: "Push to talk", detail: "Your microphone sends only while you hold the microphone button at the top of the game screen.", isOn: Binding(get: { discord.pushToTalk }, set: { discord.pushToTalk = $0 }))
                MenuDivider()
                MenuNavRow(id: MenuPage.discordPeople.rawValue, symbol: "person.2.wave.2.fill", tint: .green, title: "People", value: "\(discord.callMembers.count)") { model.page = .discordPeople }
                if case .ready = discord.voiceState {
                    MenuDivider()
                    MenuNavRow(id: MenuPage.discordLive.rawValue, symbol: "dot.radiowaves.left.and.right", tint: .red, title: "Go Live",
                               value: { switch discord.streamState { case .starting: "Starting"; case .live: "Live"; default: "Off" } }()) { model.page = .discordLive }
                }
                MenuDivider()
                MenuActionRow(title: "Leave the call", symbol: "phone.down.fill", destructive: true) { discord.leaveVoice() }
            }
        }
    }

    /// Streaming the game (or the screen) into the call.
    @ViewBuilder private var liveCard: some View {
        MenuCard(title: "Go Live", footer: "Streams to the people in the voice channel you are in.") {
            switch discord.streamState {
            case .idle, .failed:
                MenuActionRow(title: "Stream quality: \(discord.streamQuality.title)", symbol: "slider.horizontal.3", detail: "\(discord.streamQuality.detail). Tap to change; lower is smoother on a weak connection.") { discord.cycleStreamQuality() }
                MenuDivider()
                MenuActionRow(title: "Go Live: the game only", symbol: "gamecontroller.fill", detail: streamDetail ?? "Just the game's picture, at its own size and shape. No controls, menus or overlays.") { discord.startStream(source: .game) }
                MenuDivider()
                MenuActionRow(title: "Go Live: the whole screen", symbol: "dot.radiowaves.left.and.right", detail: "Everything on screen, including touch controls and menus. iOS asks if Porthole may record the screen.") { discord.startStream(source: .screen) }
            case .starting, .live:
                MenuActionRow(title: "Stop streaming", symbol: "stop.circle.fill", detail: streamDetail, destructive: true) { discord.stopStream() }
            }
        }
    }

    @ViewBuilder private var membersCard: some View {
        if !discord.callMembers.isEmpty {
            MenuCard(title: "In the call (\(discord.callMembers.count))") {
                ForEach(Array(discord.callMembers.enumerated()), id: \.element.id) { index, member in
                    if index > 0 { MenuDivider() }
                    Button { if !member.isSelf { pickedPerson = pickedPerson == member.id ? nil : member.id } } label: {
                        HStack(spacing: 10) {
                            DiscordAvatar(member: member, diameter: 30)
                            Text(member.isSelf ? "\(member.name) (you)" : member.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            if discord.personVolumes.isMuted(member.id) { Image(systemName: "speaker.slash.fill").foregroundStyle(Theme.warn) }
                            else if discord.personVolumes.volume(member.id) != 100 { Text("\(Int(discord.personVolumes.volume(member.id)))%").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textDim) }
                            if member.speaking { Image(systemName: "waveform").foregroundStyle(Color.green) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusTarget("dc-pm-\(member.id)", radius: 8) { if !member.isSelf { pickedPerson = pickedPerson == member.id ? nil : member.id } }
                    if pickedPerson == member.id, !member.isSelf {
                        MenuDivider()
                        volumeRow(title: "Their volume (for you only)", id: "person", value: discord.personVolumes.volume(member.id), range: 0...200) { discord.setPersonVolume(member.id, $0) }
                        MenuDivider()
                        MenuToggleRow(title: "Mute for me", isOn: Binding(get: { discord.personVolumes.isMuted(member.id) }, set: { discord.setPersonMuted(member.id, $0) }))
                    }
                }
            }
        }
    }

    private var overlayCard: some View {
        MenuCard(title: "Overlay", footer: "Shows who is in the call over the game, with a ring round whoever is talking. It only appears while you are in a call.") {
            MenuToggleRow(title: "Show the overlay", isOn: Binding(get: { overlay.enabled }, set: { overlay.enabled = $0 }))
            MenuDivider()
            MenuToggleRow(title: "Only who is talking", detail: "Hides everyone else", isOn: Binding(get: { overlay.onlySpeaking }, set: { overlay.onlySpeaking = $0 }))
            MenuDivider()
            MenuActionRow(title: "Corner: \(overlay.corner.title)", symbol: "rectangle.inset.topleft.filled", detail: "Tap to move it to the next corner") { overlay.corner = Self.next(overlay.corner) }
            MenuDivider()
            MenuActionRow(title: "Size: \(overlay.size.title)", symbol: "textformat.size", detail: "Tap to change") { overlay.size = Self.next(overlay.size) }
        }
    }

    /// The next case after this one, round again at the end: a choice of a few takes one row that is pressed to change, not a row for each.
    private static func next<T: CaseIterable & Equatable>(_ value: T) -> T {
        let all = Array(T.allCases)
        guard let i = all.firstIndex(of: value) else { return value }
        return all[(i + 1) % all.count]
    }

    private var micCard: some View {
        MenuCard(title: "Microphone", footer: "How quiet a sound still counts as you talking. Left / right with a controller.") {
            volumeRow(title: "Sensitivity", id: "mic", value: discord.micSensitivity, range: 0...100) { discord.setMicSensitivity($0) }
            MenuDivider()
            MicLevelBar().padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var volumeCard: some View {
        MenuCard(title: "Volume balance", footer: "Turn the game down and the call up, or the other way round, to set which one you hear better. Left / right with a controller.") {
            volumeRow(title: "Game", id: "game", value: discord.gameVolume, range: 10...200) { discord.setGameVolume($0) }
            MenuDivider()
            volumeRow(title: "Call", id: "call", value: discord.callVolume, range: 0...200) { discord.setCallVolume($0) }
        }
    }

    private func volumeRow(title: String, id: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(Int(value))%").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range, step: 5).tint(Theme.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .focusTarget("slider:discord-\(id)", radius: 8, scale: 1.0, adjust: { step in set(min(range.upperBound, max(range.lowerBound, value + Double(step) * 5))) }) {}
    }

    private var streamDetail: String? {
        switch discord.streamState {
        case .idle: return nil
        case .starting: return "Starting the stream."
        case .live: return "Streaming \(discord.streamDescription)."
        case .failed(let why): return why
        }
    }

    private var callFooter: String {
        switch discord.voiceState {
        case .idle: return ""
        case .joining(let label): return "Joining \(label)."
        case .ready(let label): return "In \(label)."
        case .refused(let why): return why
        }
    }

    @ViewBuilder private var friendsCard: some View {
        let onlineAll = discord.sortedFriends.filter { $0.status.isOnline }
        let online = onlineAll.filter { discord.call(of: $0.id) != nil } + onlineAll.filter { discord.call(of: $0.id) == nil }    // friends in a call first
        if !online.isEmpty {
            MenuCard(title: "Friends online (\(online.count))", footer: "A friend who is in a voice channel shows where; tap them to join. Calling a friend directly comes later.") {
                ForEach(Array(online.prefix(15).enumerated()), id: \.element.id) { index, friend in
                    if index > 0 { MenuDivider() }
                    let call = discord.call(of: friend.id)
                    let inMine = call != nil && call?.channel.id == discord.currentVoiceChannelID && !isIdle
                    Button { if let call, !inMine { discord.joinVoice(guild: call.guild, channel: call.channel) } } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(friend.user.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                if let call { Text("In \(call.label)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.green).lineLimit(1) }
                                else { Text(friend.activity ?? friend.status.title).font(.system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(1) }
                            }
                            Spacer()
                            if call != nil { Text(inMine ? "In your call" : "Join").font(.system(size: 13, weight: .bold)).foregroundStyle(inMine ? Theme.textDim : Theme.accent) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusTarget("dc-fr-\(friend.id)", radius: 8) { if let call, !inMine { discord.joinVoice(guild: call.guild, channel: call.channel) } }
                }
            }
        }
    }
}
