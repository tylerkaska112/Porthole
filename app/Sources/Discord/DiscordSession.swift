// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import Observation
import Security
import SwiftUI
import UIKit

/// The signed-in Discord account and what the screens show of it. Experimental: Porthole is not an official Discord client, Discord's terms do not allow third-party clients,
/// and an account used with one can be limited or banned. Nothing here runs unless the person turned Discord features on after reading that.
@MainActor
final class DiscordSession: ObservableObject {
    static let shared = DiscordSession()

    enum State: Equatable {
        case signedOut
        case waitingForScan(URL)
        case waitingForConfirm(String)
        case connecting
        case connected
        case failed(String)
    }

    private static let enabledKey = "discord.enabled"

    @Published private(set) var state: State = .signedOut
    @Published private(set) var me: DiscordUser?
    @Published private(set) var friends: [DiscordFriend] = []
    @Published private(set) var enabled: Bool
    @Published private(set) var guilds: [DiscordGuild] = []
    /// The order of servers in the account's own list, when Discord sent it.
    private var guildOrder: [String] = []

    /// Servers in the order of the account's own list; the ones it does not name, and everything when no order was sent, by name.
    private func sortGuilds() {
        let byName = guilds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guilds = DiscordPermissions.sort(byName, id: { $0.id }, by: guildOrder)
    }
    @Published private(set) var voiceState: DiscordVoice.State = .idle
    @Published private(set) var micMuted = false
    @Published private(set) var deafened = false
    private var muteState = VoiceMuteState()
    private let voice = DiscordVoice()
    private var keepAlive: BackgroundRun.Token?
    private var voiceSessionID: String?
    /// The voice channel being joined or in. For a call in a direct message or group chat the channel's id also stands in for the server's (Discord's voice servers are addressed so),
    /// and the request to join names no server.
    private struct VoiceTarget {
        var guild: String
        var channel: String
        var label: String
        var direct = false
        var gatewayGuild: String? { direct ? nil : guild }
    }
    private var voiceTarget: VoiceTarget?
    private var voiceServer: (token: String, endpoint: String)?
    /// Who is in the call this account is in, with who is talking (the in-game Discord tab and overlay show it).
    @Published private(set) var callMembers: [CallMember] = []
    /// Who is in each voice channel the servers told about (channel id -> people), for the channel list. Someone whose name is not known yet shows as "Someone".
    @Published private(set) var voiceRoster: [String: [CallMember]] = [:]
    private var voiceChannelOf: [String: String] = [:]      // user id -> voice channel id, from the servers' voice states
    private var knownUsers: [String: DiscordUser] = [:]
    private var speakingIDs: Set<String> = []
    private var lookingUp: Set<String> = []
    /// Go Live (experimental): this account streaming a picture into its voice channel.
    @Published private(set) var streamState: DiscordStream.State = .idle
    private let stream = DiscordStream()
    private var streamSource = DiscordStream.Source.testPicture
    /// How big and heavy the next stream is (Settings > Discord and the Discord tab of the in-game menu).
    @Published private(set) var streamQuality = DiscordStreamQuality.saved
    func cycleStreamQuality() { streamQuality = streamQuality.next; DiscordStreamQuality.save(streamQuality) }
    /// True while the stream shows the game's screen rather than the test picture.
    var streamShowsScreen: Bool { streamSource != .testPicture }
    /// What the running stream shows, for the screens that say so.
    var streamDescription: String {
        switch streamSource {
        case .testPicture: return "a test picture"
        case .screen: return "the whole screen"
        case .game: return "the game only"
        }
    }
    private var streamKey: String?
    private var streamRTC: String?
    private var streamServer: (endpoint: String, token: String)?
    // Watching somebody else's Go Live (experimental).
    @Published private(set) var watchState: DiscordStreamViewer.State = .idle
    /// Who is being watched (nil when nobody is).
    @Published private(set) var watchingID: String?
    /// The picture's size once it is known, for the viewer's shape.
    @Published private(set) var watchSize = CGSize.zero
    let viewer = DiscordStreamViewer()
    private var watchKey: String?
    private var watchRTC: String?
    private var watchServer: (endpoint: String, token: String)?
    private var joinWatch: Task<Void, Never>?
    private var joinAgainWhenReady = false

    private let auth = DiscordRemoteAuth()
    private let gateway = DiscordGateway()
    private let keychain = DiscordTokenStore()

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        auth.onEvent = { [weak self] event in self?.authEvent(event) }
        gateway.onEvent = { [weak self] event in self?.gatewayEvent(event) }
        voice.onState = { [weak self] state in self?.voiceState = state; self?.rebuildMembers() }
        stream.onState = { [weak self] state in self?.streamState = state }
        stream.onFatal = { [weak self] why in self?.stopStream(); self?.streamState = .failed(why) }
        // Closing the app from the app switcher: iOS tells a running app (one the background keep-alive holds open) just before it ends it. Say goodbye to Discord then.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownForTermination() }
        }
        viewer.onState = { [weak self] state in self?.watchState = state }
        viewer.onSize = { [weak self] size in self?.watchSize = size }
        voice.onSpeakingUsers = { [weak self] ids in self?.speakingIDs = ids; self?.rebuildMembers() }
        voice.setPersonGains(personVolumes.gains)
        voice.onLevel = { [weak self] level in
            guard let self, self.micLevelWatchers > 0, abs(level - self.micLevel) > 0.01 else { return }
            self.micLevel = level
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appBecameActive() }
        }
    }

    var hasToken: Bool { keychain.load() != nil }

    /// Friends who are online first, then by name.
    var sortedFriends: [DiscordFriend] {
        friends.sorted { a, b in
            if a.status.isOnline != b.status.isOnline { return a.status.isOnline }
            return a.user.displayName.localizedCaseInsensitiveCompare(b.user.displayName) == .orderedAscending
        }
    }

    // MARK: switch

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        LogStore.shared.log("[discord] features \(on ? "turned on" : "turned off")")
        if on { connectIfSignedIn() } else { auth.cancel(); gateway.disconnect(); releaseBackground(); state = .signedOut; me = nil; friends = [] }
    }

    // MARK: sign in

    func startSignIn() {
        guard enabled else { return }
        holdBackground()
        auth.cancel()
        state = .connecting
        auth.start()
    }

    /// A token from Discord's own login page (DiscordWebLogin).
    func signIn(withToken token: String) {
        guard enabled else { return }
        auth.cancel()
        keychain.save(token)
        LogStore.shared.log("[discord] signed in on Discord's login page")
        connectIfSignedIn()
    }

    // MARK: voice (step 1: connect without sound)

    func joinVoice(guild: DiscordGuild, channel: DiscordGuild.Channel) {
        beginJoin(VoiceTarget(guild: guild.id, channel: channel.id, label: "\(guild.name) / \(channel.name)"))
    }

    // MARK: people and conversations

    /// Profiles read so far, so opening the same card again is instant.
    @Published private(set) var profiles: [String: DiscordProfile] = [:]

    /// The direct messages and group chats, the one with the newest message first.
    var conversations: [DiscordDirectChannel] {
        directChannels.values.sorted { a, b in
            a.lastMessageID == b.lastMessageID ? a.id < b.id : DiscordSnowflake.isLater(a.lastMessageID, than: b.lastMessageID)
        }
    }

    /// Someone this account knows by id (a friend, or somebody met in a call or a message).
    func knownUser(_ id: String) -> DiscordUser? { knownUsers[id] ?? friends.first { $0.id == id }?.user }

    func conversationTitle(_ c: DiscordDirectChannel) -> String { c.title(me: me?.id, nameOf: displayName) }

    /// Reads a person's profile because their card was opened: one request, remembered. Nil when Discord would not say (a stranger's profile may be hidden).
    func loadProfile(_ id: String) async -> DiscordProfile? {
        if let known = profiles[id] { return known }
        guard let token = keychain.load() else { return nil }
        do {
            let json = try await DiscordREST.get("users/\(id)/profile", query: [URLQueryItem(name: "with_mutual_guilds", value: "true"), URLQueryItem(name: "with_mutual_friends_count", value: "true")], token: token)
            guard let d = json as? [String: Any], let profile = DiscordProfile.parse(d) else { return nil }
            profiles[id] = profile
            knownUsers[id] = profile.user
            return profile
        } catch {
            LogStore.shared.log("[discord] a profile could not be read: \(error)")
            return nil
        }
    }

    /// The conversation with one person, made if there is none yet (Discord's own apps make it the same way when you press Message). Nothing is sent to them by this.
    func openDirect(with userID: String) async -> String? {
        if let existing = directChannels.values.first(where: { !$0.isGroup && $0.recipientIDs == [userID] }) { return existing.id }
        guard let token = keychain.load() else { return nil }
        do {
            let json = try await DiscordREST.post("users/@me/channels", body: ["recipient_id": userID], token: token)
            guard let d = json as? [String: Any], let channel = DiscordDirectChannel.parse(d) else { return nil }
            directChannels[channel.id] = channel
            return channel.id
        } catch {
            LogStore.shared.log("[discord] a conversation could not be opened: \(error)")
            return nil
        }
    }

    /// Calls the other people of a conversation, because the person pressed Call: joins its call and rings them (the same two steps Discord's own apps take).
    func callDirect(channelID: String) {
        guard let channel = directChannels[channelID], state == .connected else { return }
        beginJoin(VoiceTarget(guild: channelID, channel: channelID, label: conversationTitle(channel), direct: true))
        guard let token = keychain.load() else { return }
        Task {
            do {
                _ = try await DiscordREST.post("channels/\(channelID)/call/ring", body: ["recipients": NSNull()], token: token)
                LogStore.shared.log("[discord-call] ringing a conversation")
            } catch {
                LogStore.shared.log("[discord-call] ringing failed: \(error)")
            }
        }
    }

    /// A message in a conversation moves it to the top of the list.
    private func touchConversation(_ raw: [String: Any]) {
        guard raw["guild_id"] == nil, let channel = raw["channel_id"] as? String, let id = raw["id"] as? String, directChannels[channel] != nil else { return }
        if DiscordSnowflake.isLater(id, than: directChannels[channel]?.lastMessageID) { directChannels[channel]?.lastMessageID = id }
    }

    /// Joins the call that is ringing (a direct message or group chat), because the person pressed Join.
    func joinCall(_ call: DiscordIncomingCall) {
        beginJoin(VoiceTarget(guild: call.channelID, channel: call.channelID, label: call.title, direct: true))
    }

    private func beginJoin(_ target: VoiceTarget) {
        guard state == .connected else { return }
        voice.stop(silently: true)
        voiceServer = nil
        voiceTarget = target
        voiceState = .joining(target.label)
        rebuildMembers()
        LogStore.shared.log("[discord-voice] joining a \(target.direct ? "call" : "voice channel")")
        gateway.setVoiceChannel(guildID: target.gatewayGuild, channelID: target.channel)
        watchJoin(target)
    }

    /// Stops a call ringing for this account (the same request Discord's own apps make when you decline).
    func declineCall(_ call: DiscordIncomingCall) {
        guard let me, let token = keychain.load() else { return }
        Task {
            do {
                _ = try await DiscordREST.post("channels/\(call.channelID)/call/stop-ringing", body: ["recipients": [me.id]], token: token)
                LogStore.shared.log("[discord-call] declined a call")
            } catch {
                LogStore.shared.log("[discord-call] declining a call failed: \(error)")
            }
        }
    }

    /// Discord sometimes keeps an account in a channel from an older connection and then never sends the voice server for a join to the same channel.
    /// If nothing arrives, leave once and join again; if that fails too, say so instead of showing "joining" for ever.
    private func watchJoin(_ target: VoiceTarget) {
        joinWatch?.cancel()
        joinWatch = Task { [weak self] in
            @MainActor func stillJoining(_ me: DiscordSession) -> Bool {
                if case .joining = me.voiceState, me.voiceTarget?.channel == target.channel { return true }
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, stillJoining(self) else { return }
            LogStore.shared.log("[discord-voice] no voice server after 5 s (\(self.gateway.summary)): leaving the channel and joining again")
            self.gateway.setVoiceChannel(guildID: target.gatewayGuild, channelID: nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, stillJoining(self) else { return }
            self.gateway.setVoiceChannel(guildID: target.gatewayGuild, channelID: target.channel)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, stillJoining(self) else { return }
            // The connection to Discord may be one that went dead without saying so (the quick VPN a game start switches on can do that): start a new one and ask again once it is up.
            LogStore.shared.log("[discord-voice] still no voice server (\(self.gateway.summary)): connecting to Discord again")
            self.voiceSessionID = nil
            self.joinAgainWhenReady = true
            self.connectIfSignedIn()
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard !Task.isCancelled, stillJoining(self) else { return }
            LogStore.shared.log("[discord-voice] Discord never sent a voice server")
            self.joinAgainWhenReady = false
            self.voiceState = .refused("Discord did not answer the request to join. Leave and try again.")
        }
    }

    /// The name of the direct-message or group call being joined or in (nil in a server's voice channel or none).
    var directCallLabel: String? { voiceTarget?.direct == true ? voiceTarget?.label : nil }

    /// The voice channel being joined or in (nil when none).
    var currentVoiceChannelID: String? { voiceTarget?.channel }

    /// The balance between the game and the call: percent of the game's level (10...200) and of the call's (0...200). They apply while a call runs.
    @Published private(set) var gameVolume: Double = UserDefaults.standard.object(forKey: DiscordAudio.gameVolumeKey) as? Double ?? 100
    @Published private(set) var callVolume: Double = UserDefaults.standard.object(forKey: DiscordAudio.callVolumeKey) as? Double ?? 100

    func setGameVolume(_ percent: Double) {
        gameVolume = min(max(percent.rounded(), 10), 200)
        UserDefaults.standard.set(gameVolume, forKey: DiscordAudio.gameVolumeKey)
        voice.volumesChanged()
    }

    /// How easily the microphone counts as talking (0...100, higher = quieter sound is enough), and how loud it is now (0...1, for the level bar; only kept up to date while a bar is on screen).
    @Published private(set) var micSensitivity: Double = MicSensitivity.saved
    @Published private(set) var micLevel: Float = 0
    private var micLevelWatchers = 0

    /// How loud each person in a call is for this phone, and who is muted. Remembered by Discord user id.
    @Published private(set) var personVolumes = PersonVolumes.load()

    func setPersonVolume(_ id: String, _ percent: Double) {
        personVolumes.setVolume(id, percent)
        personVolumes.save()
        voice.setPersonGains(personVolumes.gains)
    }

    func setPersonMuted(_ id: String, _ on: Bool) {
        personVolumes.setMuted(id, on)
        personVolumes.save()
        voice.setPersonGains(personVolumes.gains)
    }

    func setMicSensitivity(_ percent: Double) {
        micSensitivity = MicSensitivity.clamp(percent)
        UserDefaults.standard.set(micSensitivity, forKey: MicSensitivity.key)
        voice.sensitivityChanged()
    }

    /// A level bar calls this when it appears and disappears, so the session does not redraw screens ten times a second for nobody.
    func watchMicLevel(_ on: Bool) {
        micLevelWatchers = max(0, micLevelWatchers + (on ? 1 : -1))
        if micLevelWatchers == 0 { micLevel = 0 }
    }

    func setCallVolume(_ percent: Double) {
        callVolume = min(max(percent.rounded(), 0), 200)
        UserDefaults.standard.set(callVolume, forKey: DiscordAudio.callVolumeKey)
        voice.volumesChanged()
    }

    // MARK: text channels

    /// What was read of each text channel (oldest first), and how loading it went. Live messages from the gateway are added to a channel that has been opened.
    @Published private(set) var messages: [String: [DiscordMessage]] = [:]
    @Published private(set) var messageLoad: [String: MessageLoad] = [:]

    private func channelName(_ id: String) -> String? { guilds.lazy.compactMap { $0.channel(id)?.name }.first }

    /// Reads the latest messages of a text channel (once; opening it again does nothing unless `force`). One request, made because a person opened the channel.
    func loadMessages(_ channelID: String, force: Bool = false) {
        if !force, let state = messageLoad[channelID], state == .loading || state == .loaded { return }
        messageLoad[channelID] = .loading
        let token = keychain.load()
        Task { [weak self] in
            do {
                let json = try await DiscordREST.get("channels/\(channelID)/messages", query: [URLQueryItem(name: "limit", value: "50")], token: token)
                guard let self else { return }
                let list = (json as? [[String: Any]] ?? []).compactMap { DiscordMessage.parse($0, channelName: self.channelName) }
                self.messages[channelID] = DiscordMessage.merged(self.messages[channelID] ?? [], list)
                self.messageLoad[channelID] = .loaded
                if self.olderState[channelID] == nil, (json as? [[String: Any]] ?? []).count < 50 { self.olderState[channelID] = .done }
            } catch let failure as DiscordREST.Failure {
                self?.messageLoad[channelID] = .failed(failure.message)
            } catch {
                self?.messageLoad[channelID] = .failed(DiscordREST.Failure.network(error.localizedDescription).message)
            }
        }
    }

    // MARK: echo

    /// Keeps the call's own sound from going back into the call when the speakers are loud (experimental; see EchoSuppressor). Off until the person turns it on.
    @Published var reduceEcho: Bool = UserDefaults.standard.bool(forKey: "f4.discord.reduceEcho") {
        didSet { UserDefaults.standard.set(reduceEcho, forKey: "f4.discord.reduceEcho"); voice.setReduceEcho(reduceEcho) }
    }

    // MARK: push to talk

    private static let pushToTalkKey = "f4.discord.pushToTalk"
    /// The microphone sends only while the talk button is held. Off until the person turns it on.
    @Published var pushToTalk: Bool = UserDefaults.standard.bool(forKey: "f4.discord.pushToTalk") {
        didSet { UserDefaults.standard.set(pushToTalk, forKey: Self.pushToTalkKey); if !pushToTalk { talkHeld = false }; applyPushToTalk() }
    }
    @Published private(set) var talkHeld = false
    /// The talk button shows over the game: push to talk is on and this account is in a call.
    var talkButtonShowing: Bool { pushToTalk && voiceTarget != nil }

    /// The talk button was pressed or let go.
    func setTalking(_ held: Bool) {
        guard pushToTalk, talkHeld != held else { return }
        talkHeld = held
        applyPushToTalk()
    }

    private func applyPushToTalk() { voice.setPushToTalk(enabled: pushToTalk, held: talkHeld) }

    // MARK: activity ("Playing <game>")

    private static let shareActivityKey = "f4.discord.shareActivity"
    /// Whether friends see the game that is running. Off until the person turns it on: it is something Discord's own app does by detecting games, which Porthole cannot; here it is
    /// Porthole telling Discord.
    @Published var shareActivity: Bool = UserDefaults.standard.bool(forKey: "f4.discord.shareActivity") {
        didSet { UserDefaults.standard.set(shareActivity, forKey: Self.shareActivityKey); onActivitySettingChanged?(); applyActivity() }
    }
    /// Asks the app to work out what the person is doing again (the setting changed).
    var onActivitySettingChanged: (() -> Void)?
    private var presence: DiscordActivity.Kind?
    private var presenceSince = Date()
    private var sentPresence: DiscordActivity.Kind?

    /// What the person is doing changed (nil: nothing to show): their friends see it when the activity is turned on. The time restarts when the kind changes.
    func presenceChanged(_ kind: DiscordActivity.Kind?) {
        if kind != presence { presence = kind; presenceSince = Date() }
        applyActivity()
    }

    private func applyActivity() {
        let wanted = shareActivity ? presence : nil
        guard wanted != sentPresence else { return }
        sentPresence = wanted
        gateway.setActivity(wanted.flatMap { DiscordActivity.activity(for: $0, since: presenceSince) })
        LogStore.shared.log("[discord] activity \(wanted == nil ? "cleared" : "set")")
    }

    // MARK: reactions, replies, editing, typing

    /// Who is typing where, until when (a typing notice lasts about ten seconds; Discord sends a new one while somebody keeps typing).
    @Published private(set) var typingUntil: [String: [String: Date]] = [:]
    static let typingSeconds: TimeInterval = 9

    /// The names of the people typing in a channel now.
    func typingNames(in channelID: String) -> [String] {
        let now = Date()
        return (typingUntil[channelID] ?? [:]).filter { $0.value > now }.keys.sorted().map { displayName(of: $0) ?? "Someone" }
    }

    private func pruneTyping() {
        let now = Date()
        var next = typingUntil
        for (channel, people) in typingUntil {
            let alive = people.filter { $0.value > now }
            next[channel] = alive.isEmpty ? nil : alive
        }
        if next != typingUntil { typingUntil = next }
    }

    /// Presses an emoji under a message: it changes at once, and Discord is told. If Discord refuses, it changes back and says why.
    func toggleReaction(_ emoji: (name: String, id: String?, animated: Bool), on messageID: String, in channelID: String) {
        guard var list = messages[channelID], let i = list.firstIndex(where: { $0.id == messageID }) else { return }
        let on = list[i].toggle(emoji: emoji)
        messages[channelID] = list
        let key = DiscordMessage.Reaction.key(name: emoji.name, id: emoji.id)
        let encoded = key.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? key
        let path = "channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me"
        let query = [URLQueryItem(name: "location", value: "Message"), URLQueryItem(name: "type", value: "0")]
        let token = keychain.load()
        Task { [weak self] in
            do {
                if on { try await DiscordREST.put(path, query: query, token: token) } else { try await DiscordREST.delete(path, query: query, token: token) }
            } catch {
                // Back to how it was.
                guard let self, var now = self.messages[channelID], let k = now.firstIndex(where: { $0.id == messageID }) else { return }
                now[k].apply(emoji: emoji, add: !on, mine: true)
                self.messages[channelID] = now
                self.sendError[channelID] = (error as? DiscordREST.Failure).map { $0 == .forbidden ? "You are not allowed to react here." : DiscordREST.sendingMessage($0) } ?? "The reaction was not sent."
                LogStore.shared.log("[discord] a reaction was not accepted: \(error)")
            }
        }
    }

    /// Changes the text of one of this account's own messages, because a person pressed Save.
    func editMessage(_ messageID: String, in channelID: String, to raw: String, done: @escaping (Bool) -> Void) {
        guard !sendingTo.contains(channelID) else { done(false); return }
        let text: String
        switch OutgoingMessage.check(raw) {
        case .success(let checked): text = checked
        case .failure(let problem): sendError[channelID] = problem == .empty ? nil : problem.message; done(false); return
        }
        sendError[channelID] = nil
        sendingTo.insert(channelID)
        let token = keychain.load()
        Task { [weak self] in
            var ok = false
            do {
                let json = try await DiscordREST.patch("channels/\(channelID)/messages/\(messageID)", body: ["content": text], token: token)
                if let self, let raw = json as? [String: Any], let edited = DiscordMessage.parse(raw, channelName: self.channelName) { self.messages[channelID] = DiscordMessage.merged(self.messages[channelID] ?? [], [edited]) }
                LogStore.shared.log("[discord] a message was edited")
                ok = true
            } catch let failure as DiscordREST.Failure {
                self?.sendError[channelID] = failure == .forbidden ? "You can only edit your own messages." : DiscordREST.sendingMessage(failure)
            } catch {
                self?.sendError[channelID] = DiscordREST.sendingMessage(.network(error.localizedDescription))
            }
            self?.sendingTo.remove(channelID)
            done(ok)
        }
    }

    /// Deletes one of this account's own messages, because a person confirmed it.
    func deleteMessage(_ messageID: String, in channelID: String) {
        let token = keychain.load()
        Task { [weak self] in
            do {
                try await DiscordREST.delete("channels/\(channelID)/messages/\(messageID)", token: token)
                self?.messages[channelID]?.removeAll { $0.id == messageID }
                LogStore.shared.log("[discord] a message was deleted")
            } catch let failure as DiscordREST.Failure {
                self?.sendError[channelID] = failure == .forbidden ? "You can only delete your own messages." : failure.message
            } catch {
                self?.sendError[channelID] = DiscordREST.Failure.network(error.localizedDescription).message
            }
        }
    }

    /// Whether more messages before the oldest one shown can be read ("done": Discord has no more), per channel.
    @Published private(set) var olderState: [String: OlderMessages] = [:]

    /// Reads the 50 messages before the oldest one shown, because a person pressed Load earlier messages.
    func loadOlder(_ channelID: String) {
        guard olderState[channelID] == nil, let first = messages[channelID]?.first?.id else { return }
        olderState[channelID] = .loading
        let token = keychain.load()
        Task { [weak self] in
            do {
                let json = try await DiscordREST.get("channels/\(channelID)/messages", query: [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "before", value: first)], token: token)
                guard let self else { return }
                let raw = json as? [[String: Any]] ?? []
                let list = raw.compactMap { DiscordMessage.parse($0, channelName: self.channelName) }
                self.messages[channelID] = DiscordMessage.merged(self.messages[channelID] ?? [], list)
                self.olderState[channelID] = raw.count < 50 ? .done : nil
            } catch {
                self?.olderState[channelID] = nil
                self?.sendError[channelID] = (error as? DiscordREST.Failure)?.message ?? DiscordREST.Failure.network(error.localizedDescription).message
            }
        }
    }

    // MARK: unread

    /// Messages that came in since they were last looked at, by channel or conversation: every message of a direct message or group chat, and the messages of a server that name this
    /// account or answer it. Kept in memory only, like the messages. The Social tab's badge is their total.
    @Published private(set) var unread: [String: Int] = [:] {
        didSet { DiscordBadge.shared.count = unread.values.reduce(0, +) }
    }

    /// The channel or conversation the person is reading right now (the Discord screen says so while it shows one); what arrives in it is read at once.
    private(set) var viewingChannel: String?

    func setViewing(_ id: String?) {
        viewingChannel = id
        if let id, unread[id] != nil { unread[id] = nil }
    }

    private func countUnread(_ raw: [String: Any]) {
        guard let me, let message = DiscordMessage.parse(raw, channelName: channelName), message.author.id != me.id, message.channelID != viewingChannel else { return }
        guard message.isDirect || message.mentions(me.id) else { return }
        unread[message.channelID, default: 0] += 1
    }

    // MARK: forums

    /// The posts of each forum or media channel that was opened, and how reading them went.
    @Published private(set) var forumPosts: [String: [DiscordForumPost]] = [:]
    @Published private(set) var forumLoad: [String: MessageLoad] = [:]

    /// Reads a forum's posts (once; opening it again does nothing unless `force`): Discord's own thread search, which also gives each post's first message, and when that is refused the
    /// list of the server's open threads. One or two requests, made because a person opened the forum.
    func loadForum(_ channelID: String, force: Bool = false) {
        guard let guild = guilds.first(where: { $0.channel(channelID) != nil }), let forum = guild.channel(channelID) else { return }
        if !force, let state = forumLoad[channelID], state == .loading || state == .loaded { return }
        forumLoad[channelID] = .loading
        let token = keychain.load()
        Task { [weak self] in
            do {
                var posts: [DiscordForumPost]
                do {
                    let query = [("sort_by", "last_message_time"), ("sort_order", "desc"), ("limit", "25"), ("tag_setting", "match_some"), ("offset", "0")].map { URLQueryItem(name: $0.0, value: $0.1) }
                    let json = try await DiscordREST.get("channels/\(channelID)/threads/search", query: query, token: token)
                    posts = DiscordForumPost.posts(fromSearch: json as? [String: Any] ?? [:], tagNames: forum.tags)
                } catch let failure as DiscordREST.Failure where failure != .unauthorized && failure != .signedOut && failure != .rateLimited {
                    LogStore.shared.log("[discord] the forum search was refused (\(failure)); reading the server's open threads instead")
                    let json = try await DiscordREST.get("guilds/\(guild.id)/threads/active", token: token)
                    posts = DiscordForumPost.posts(fromThreads: (json as? [String: Any])?["threads"] as? [[String: Any]] ?? [], forum: channelID, tagNames: forum.tags)
                }
                self?.forumPosts[channelID] = posts
                self?.forumLoad[channelID] = .loaded
            } catch let failure as DiscordREST.Failure {
                self?.forumLoad[channelID] = .failed(failure.message)
            } catch {
                self?.forumLoad[channelID] = .failed(DiscordREST.Failure.network(error.localizedDescription).message)
            }
        }
    }

    /// A new message: the notifier decides whether it is worth a banner (that is off unless the person turned it on).
    private func noticeMessage(_ raw: [String: Any]) {
        guard let me, DiscordNotifier.shared.enabled, let message = DiscordMessage.parse(raw, channelName: channelName) else { return }
        let conversation: DiscordConversation
        if let guildID = message.guildID {
            conversation = DiscordConversation(id: message.channelID, title: "#" + (channelName(message.channelID) ?? "channel"), place: guilds.first { $0.id == guildID }?.name ?? "Server")
        } else {
            let title = directChannels[message.channelID]?.title(me: me.id, nameOf: displayName) ?? message.author.displayName
            conversation = DiscordConversation(id: message.channelID, title: title, place: nil)
        }
        DiscordNotifier.shared.consider(message, me: me.id, conversation: conversation)
    }

    // MARK: calls in direct messages and group chats

    /// The direct messages and group chats of this account, by channel id (they name the calls and the messages).
    @Published private(set) var directChannels: [String: DiscordDirectChannel] = [:]

    private func displayName(of id: String) -> String? { knownUsers[id]?.displayName ?? friends.first { $0.id == id }?.user.displayName }

    /// A call changed. If it rings for this account (and the person asked for call banners) the notifier shows it; otherwise any banner for it goes.
    private func callEvent(_ call: DiscordCallState) {
        guard let me else { return }
        guard DiscordNotifier.shared.callBanners, call.rings(me.id), voiceTarget?.channel != call.channelID else {
            DiscordNotifier.shared.callEnded(channelID: call.channelID)
            return
        }
        let callers = call.inCall.filter { $0 != me.id }
        for id in callers where displayName(of: id) == nil { lookUp(id) }
        let named = callers.compactMap(displayName)
        let direct = directChannels[call.channelID]
        var title = direct?.title(me: me.id, nameOf: displayName) ?? ""
        if title.isEmpty || title == "Direct message" || title == "Group chat" { title = named.isEmpty ? "Someone" : named.joined(separator: " and ") }
        let caller = callers.compactMap { id in knownUsers[id] ?? friends.first { $0.id == id }?.user }.first
        DiscordNotifier.shared.callRinging(DiscordIncomingCall(channelID: call.channelID, title: title, caller: caller, isGroup: direct?.isGroup ?? (callers.count > 1)))
    }

    @Published private(set) var sendingTo: Set<String> = []
    @Published private(set) var sendError: [String: String] = [:]

    /// Sends one message to a text channel, because a person pressed Send. `done` says whether Discord took it (so the box can be emptied). The text is never logged.
    func sendMessage(_ raw: String, to channelID: String, replyTo: String? = nil, done: @escaping (Bool) -> Void) {
        guard !sendingTo.contains(channelID) else { done(false); return }
        let text: String
        switch OutgoingMessage.check(raw) {
        case .success(let checked): text = checked
        case .failure(let problem): sendError[channelID] = problem == .empty ? nil : problem.message; done(false); return
        }
        sendError[channelID] = nil
        sendingTo.insert(channelID)
        let token = keychain.load()
        Task { [weak self] in
            var ok = false
            do {
                var body: [String: Any] = ["content": text, "nonce": OutgoingMessage.nonce(), "tts": false]
                if let replyTo { body["message_reference"] = ["message_id": replyTo, "fail_if_not_exists": false] as [String: Any] }
                let json = try await DiscordREST.post("channels/\(channelID)/messages", body: body, token: token)
                if let self, let raw = json as? [String: Any], self.messages[channelID] != nil, let sent = DiscordMessage.parse(raw, channelName: self.channelName) {
                    self.messages[channelID] = DiscordMessage.merged(self.messages[channelID] ?? [], [sent])    // the gateway echoes it too; one entry per message
                }
                LogStore.shared.log("[discord] a message was sent")
                ok = true
            } catch let failure as DiscordREST.Failure {
                self?.sendError[channelID] = DiscordREST.sendingMessage(failure)
                LogStore.shared.log("[discord] a message was not sent: \(failure)")
            } catch {
                self?.sendError[channelID] = DiscordREST.sendingMessage(.network(error.localizedDescription))
            }
            self?.sendingTo.remove(channelID)
            done(ok)
        }
    }

    private func messageEvent(_ raw: [String: Any], isUpdate: Bool) {
        guard let channel = raw["channel_id"] as? String, messages[channel] != nil, let message = DiscordMessage.parse(raw, channelName: channelName) else { return }
        // An update that only adds a preview has no author or text of its own: parse() drops it and the message stays as it was.
        messages[channel] = DiscordMessage.merged(messages[channel] ?? [], [message])
    }

    // MARK: Go Live (test)

    /// Starts a stream in the voice channel this account is in (a test picture for now). Discord answers with the stream's id and its server; the stream's own connection starts then.
    func startStream(source: DiscordStream.Source = .testPicture) {
        guard let target = voiceTarget, case .ready = voiceState, let me else { streamState = .failed("Join a voice channel first, and wait until it says it is accepted."); return }
        guard !target.direct else { streamState = .failed("Go Live works in a server's voice channel for now, not in a call."); return }
        guard streamKey == nil else { return }
        streamSource = source
        stream.stop(silently: true)
        streamKey = "guild:\(target.guild):\(target.channel):\(me.id)"
        streamRTC = nil; streamServer = nil
        streamState = .starting
        gateway.startStream(guildID: target.guild, channelID: target.channel, key: streamKey!)
        let key = streamKey
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.streamKey == key, case .starting = self.streamState else { return }
            LogStore.shared.log("[discord-stream] Discord never started the stream")
            self.stopStream()
            self.streamState = .failed("Discord did not start the stream.")
        }
    }

    /// Whether this account can watch `userID`'s stream now: they are streaming in the voice channel this account has joined.
    func canWatch(_ userID: String) -> Bool {
        guard userID != me?.id, streamingUsers.contains(userID), voiceTarget != nil, case .ready = voiceState, voiceChannelOf[userID] == voiceTarget?.channel else { return false }
        return true
    }

    /// Starts watching somebody's Go Live in the voice channel this account is in. Discord answers with the stream's id and its server; the viewer connects then.
    func watchStream(of userID: String) {
        guard let target = voiceTarget, case .ready = voiceState, me != nil else { watchState = .failed("Join the voice channel first, and wait until it says it is accepted."); return }
        guard streamingUsers.contains(userID) else { watchState = .failed("That person is not streaming."); return }
        if watchKey != nil { stopWatching() }
        viewer.stop(silently: true)
        viewer.pacing = watchPacing
        watchKey = DiscordStreamKey.make(guild: target.direct ? nil : target.guild, channel: target.channel, owner: userID)
        watchRTC = nil; watchServer = nil
        watchingID = userID; watchSize = .zero
        watchState = .connecting
        gateway.watchStream(key: watchKey!)
        let key = watchKey
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.watchKey == key, self.watchState == .connecting, self.watchServer == nil else { return }
            LogStore.shared.log("[discord-watch] Discord never gave the stream's server")
            self.stopWatching()
            self.watchState = .failed("Discord did not open the stream.")
        }
    }

    /// How the watched stream's pictures are paced (steady / sender clock / instant); the button on the stream screen cycles it.
    @Published private(set) var watchPacing = DiscordPacing.saved
    func cycleWatchPacing() {
        watchPacing = watchPacing.next
        DiscordPacing.save(watchPacing)
        viewer.pacing = watchPacing
        LogStore.shared.log("[discord-watch] pacing: \(watchPacing.title)")
    }

    /// The app is being closed: end the stream, leave the call and go offline on Discord's side too, instead of leaving all of it hanging for a while.
    func shutDownForTermination() {
        guard state == .connected || streamKey != nil || voiceTarget != nil else { return }
        LogStore.shared.log("[discord] the app is closing: leaving the call, ending the stream and going offline")
        let key = streamKey
        let wasInCall = voiceTarget != nil
        stream.stop(silently: true)
        viewer.stop(silently: true)
        voice.stop(silently: true)
        gateway.goodbye(streamKey: key, leaveVoice: wasInCall)
    }

    func stopWatching() {
        viewer.stop()
        if let key = watchKey { gateway.stopStream(key: key) }
        watchKey = nil; watchRTC = nil; watchServer = nil; watchingID = nil; watchSize = .zero
        if case .failed = watchState { return }
        watchState = .idle
    }

    /// Clears a failure once it has been shown.
    func dismissWatchFailure() { stopWatching(); watchState = .idle }

    private func startWatchIfReady() {
        guard let rtc = watchRTC, !rtc.isEmpty, let server = watchServer, let session = voiceSessionID, let me, let key = watchKey, let owner = DiscordStreamKey.parse(key)?.owner else { return }
        watchServer = nil
        viewer.connect(endpoint: server.endpoint, rtcServerID: rtc, userID: me.id, sessionID: session, token: server.token, streamerID: owner)
    }

    func stopStream() {
        stream.stop()
        if let key = streamKey { gateway.stopStream(key: key) }
        streamKey = nil; streamRTC = nil; streamServer = nil
        if case .failed = streamState { return }
        streamState = .idle
    }

    private func startStreamIfReady() {
        guard let rtc = streamRTC, !rtc.isEmpty, let server = streamServer, let session = voiceSessionID, let me else { return }
        streamServer = nil
        stream.connect(endpoint: server.endpoint, rtcServerID: rtc, userID: me.id, sessionID: session, token: server.token, source: streamSource)
    }

    func setMicMuted(_ on: Bool) { muteState.setMicMuted(on); applyMuteState() }
    func setDeafened(_ on: Bool) { muteState.setDeafened(on); applyMuteState() }

    private func applyMuteState() {
        micMuted = muteState.micMuted
        deafened = muteState.deafened
        voice.setMuted(micMuted)
        voice.setDeafened(deafened)
        gateway.selfMute = micMuted
        gateway.selfDeaf = deafened
        // Tell Discord (and so everyone in the channel) while this account is in one.
        if let target = voiceTarget { gateway.setVoiceChannel(guildID: target.gatewayGuild, channelID: target.channel) }
    }

    func leaveVoice() {
        micLevel = 0
        joinWatch?.cancel()
        if streamKey != nil { stopStream() }
        if watchKey != nil { stopWatching() }
        if let target = voiceTarget { gateway.setVoiceChannel(guildID: target.gatewayGuild, channelID: nil) }
        voice.stop()
        voiceTarget = nil
        voiceServer = nil
        voiceState = .idle
        speakingIDs = []
        rebuildMembers()
    }

    /// The voice channel a person is in right now (a server this account is in), if any.
    func call(of person: String) -> FriendCall? { FriendCall.of(person: person, roster: voiceRoster, guilds: guilds) }

    /// Everyone the servers put in a voice channel, for the channel list.
    /// Who is streaming (Go Live) in a voice channel, from their voice states.
    private var streamingUsers: Set<String> = []

    private func rebuildRoster() {
        var roster: [String: [CallMember]] = [:]
        for (id, channel) in voiceChannelOf {
            let user = knownUsers[id] ?? friends.first { $0.id == id }?.user
            roster[channel, default: []].append(CallMember(id: id, name: user?.displayName ?? "Someone", avatarURL: user?.avatarURL, speaking: speakingIDs.contains(id), isSelf: id == me?.id, streaming: streamingUsers.contains(id)))
        }
        for key in roster.keys {
            roster[key]?.sort { a, b in a.isSelf != b.isSelf ? a.isSelf : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        }
        if roster != voiceRoster { voiceRoster = roster }
    }

    /// The people in the call, newest information first: servers' voice states say who is in the channel, the voice connection says who is talking.
    private func rebuildMembers() {
        rebuildRoster()
        guard let target = voiceTarget, voiceState != .idle else {
            if !callMembers.isEmpty { callMembers = [] }
            return
        }
        var ids = voiceChannelOf.filter { $0.value == target.channel }.map(\.key)
        if let me, !ids.contains(me.id) { ids.append(me.id) }
        let members = ids.map { id -> CallMember in
            let user = knownUsers[id] ?? friends.first { $0.id == id }?.user
            if user == nil { lookUp(id) }
            return CallMember(id: id, name: user?.displayName ?? "Someone", avatarURL: user?.avatarURL, speaking: speakingIDs.contains(id), isSelf: id == me?.id, streaming: streamingUsers.contains(id))
        }.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if members != callMembers { callMembers = members }
    }

    /// A name for someone the servers did not name: the same lookup Discord's own app makes for a profile.
    private func lookUp(_ id: String) {
        guard !lookingUp.contains(id), let token = keychain.load(), let url = URL(string: "https://discord.com/api/v9/users/\(id)") else { return }
        lookingUp.insert(id)
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "Authorization")
            request.setValue(DiscordIdentity.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let user = try? JSONDecoder().decode(DiscordUser.self, from: data) else { return }
            self?.knownUsers[id] = user
            self?.rebuildMembers()
        }
    }

    private func startVoiceIfReady() {
        guard let target = voiceTarget, let session = voiceSessionID, let server = voiceServer, let me else { return }
        voiceServer = nil
        voice.connect(endpoint: server.endpoint, serverID: target.guild, userID: me.id, sessionID: session, token: server.token, channelID: target.channel, label: target.label)
    }

    func cancelSignIn() {
        auth.cancel()
        if state != .connected { state = .signedOut }
    }

    func signOut() {
        auth.cancel()
        gateway.disconnect()
        voice.stop()
        releaseBackground()
        keychain.delete()
        guilds = []; guildOrder = []
        messages = [:]; messageLoad = [:]; sendError = [:]
        DiscordNotifier.shared.forgetRecent()
        directChannels = [:]; forumPosts = [:]; forumLoad = [:]; unread = [:]; viewingChannel = nil; typingUntil = [:]; olderState = [:]; streamingUsers = []
        me = nil
        friends = []
        state = .signedOut
        LogStore.shared.log("[discord] signed out; the token was removed from this device")
    }

    /// iOS suspends an app a few seconds after it leaves the screen and the connection dies with it. Porthole's background keep-alive (silent audio, the same one downloads use,
    /// BackgroundRun) holds the app running while Discord is signed in, for as long as it allows downloads to run in the background (60 minutes by default).
    private func holdBackground() {
        guard keepAlive == nil else { return }
        keepAlive = BackgroundRun.shared.beginTask("Discord") { [weak self] in
            Task { @MainActor in
                self?.keepAlive = nil
                LogStore.shared.log("[discord] the background time is over; the connection is picked up again when you come back")
            }
        }
    }

    private func releaseBackground() {
        if let token = keepAlive { BackgroundRun.shared.endTask(token) }
        keepAlive = nil
    }

    /// Called once when the app starts: with Discord features on and a saved sign-in, connect now, without anyone opening Settings > Discord first.
    func startAtLaunch() {
        guard enabled, hasToken, state == .signedOut else { return }
        LogStore.shared.log("[discord] connecting at launch")
        connectIfSignedIn()
    }

    func connectIfSignedIn() {
        guard enabled, let token = keychain.load() else { return }
        holdBackground()
        reconnectTask?.cancel()
        state = .connecting
        gateway.connect(token: token)
    }

    /// "Try again" after a lost connection: the saved sign-in is used again; only without one does it start a new sign-in.
    func retry() {
        if hasToken { connectIfSignedIn() } else { startSignIn() }
    }

    // MARK: staying connected

    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: Double = 2

    /// iOS closes a connection when the app has been in the background. Coming back, connect again by itself instead of asking the person to sign in.
    private func appBecameActive() {
        guard enabled, hasToken, auth.isIdle else { return }
        switch state {
        case .connected:
            // A connection that has heard nothing for a while is most likely dead: start a fresh one.
            if Date().timeIntervalSince(gateway.lastMessage) > 45 {
                LogStore.shared.log("[discord] back in the app after a while: connecting again")
                connectIfSignedIn()
            }
        case .failed(let message) where !message.contains("no longer valid"):
            LogStore.shared.log("[discord] back in the app: connecting again")
            connectIfSignedIn()
        case .signedOut: connectIfSignedIn()
        default: break
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.enabled, self.hasToken, UIApplication.shared.applicationState == .active else { return }
            LogStore.shared.log("[discord] reconnecting")
            self.connectIfSignedIn()
        }
    }

    private func authEvent(_ event: DiscordRemoteAuth.Event) {
        switch event {
        case .qr(let url): state = .waitingForScan(url)
        case .scanned(let who): state = .waitingForConfirm(who)
        case .token(let token):
            keychain.save(token)
            LogStore.shared.log("[discord] signed in by QR code")
            connectIfSignedIn()
        case .failed(let message):
            LogStore.shared.log("[discord] sign-in failed: \(message)")
            state = .failed(message)
        case .cancelled:
            if state != .connected, state != .connecting { state = .signedOut }
        }
    }

    private func gatewayEvent(_ event: DiscordGateway.Event) {
        switch event {
        case .ready(let ready):
            me = ready.user
            knownUsers[ready.user.id] = ready.user
            voiceChannelOf = [:]
            friends = ready.friends
            state = .connected
            reconnectDelay = 2
            LogStore.shared.log("[discord] connected: \(friends.count) friend(s)")
            if joinAgainWhenReady, let target = voiceTarget, case .joining = voiceState {
                joinAgainWhenReady = false
                LogStore.shared.log("[discord-voice] asking to join again on the new connection")
                gateway.setVoiceChannel(guildID: target.gatewayGuild, channelID: target.channel)
            }
        case .presence(let id, let status, let activity):
            if let i = friends.firstIndex(where: { $0.id == id }) { friends[i].status = status; friends[i].activity = activity }
        case .friendAdded(let user):
            if !friends.contains(where: { $0.id == user.id }) { friends.append(DiscordFriend(user: user)) }
        case .directChannels(let list): for c in list { directChannels[c.id] = c }
        case .call(let call): callEvent(call)
        case .callEnded(let id): DiscordNotifier.shared.callEnded(channelID: id)
        case .messageCreate(let raw): touchConversation(raw); countUnread(raw); messageEvent(raw, isUpdate: false); noticeMessage(raw)
            // Somebody who sends a message has stopped typing.
            if let channel = raw["channel_id"] as? String, let author = (raw["author"] as? [String: Any])?["id"] as? String, typingUntil[channel]?[author] != nil { typingUntil[channel]?[author] = nil }
        case .messageUpdate(let raw): messageEvent(raw, isUpdate: true)
        case .messageDelete(let channelID, let id): messages[channelID]?.removeAll { $0.id == id }
        case .reaction(let channelID, let messageID, let userID, let emoji, let add):
            guard var list = messages[channelID], let i = list.firstIndex(where: { $0.id == messageID }) else { return }
            list[i].apply(emoji: emoji, add: add, mine: userID == me?.id)
            messages[channelID] = list
        case .reactionsCleared(let channelID, let messageID, let key):
            guard var list = messages[channelID], let i = list.firstIndex(where: { $0.id == messageID }) else { return }
            if let key { list[i].reactions.removeAll { $0.id == key } } else { list[i].reactions = [] }
            messages[channelID] = list
        case .typing(let channelID, let userID, let user):
            guard userID != me?.id else { return }
            if let user { knownUsers[userID] = user } else if displayName(of: userID) == nil { lookUp(userID) }
            typingUntil[channelID, default: [:]][userID] = Date().addingTimeInterval(Self.typingSeconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingSeconds + 0.5) { [weak self] in self?.pruneTyping() }
        case .friendRemoved(let id):
            friends.removeAll { $0.id == id }
        case .guilds(let list):
            // Only the channels this account may open, and no server that has none.
            for raw in list {
                let g = me.map { raw.visible(for: $0.id) } ?? raw
                if g.channels.isEmpty { guilds.removeAll { $0.id == g.id }; continue }
                if let i = guilds.firstIndex(where: { $0.id == g.id }) { guilds[i] = g } else { guilds.append(g) }
            }
            sortGuilds()
        case .thread(let guildID, let channel, let deletedID):
            guard let i = guilds.firstIndex(where: { $0.id == guildID }) else { return }
            if let deletedID { guilds[i].channels.removeAll { $0.id == deletedID } }
            if let channel {
                // The parent has to be a channel this account may open (a thread has no rules of its own).
                guard guilds[i].channel(channel.parentID ?? "") != nil else { return }
                if let k = guilds[i].channels.firstIndex(where: { $0.id == channel.id }) { guilds[i].channels[k] = channel } else { guilds[i].channels.append(channel) }
            }
        case .streaming(let userID, let on):
            if on { streamingUsers.insert(userID) } else { streamingUsers.remove(userID) }
            if !on, userID == watchingID, watchState != .idle { LogStore.shared.log("[discord-watch] the streamer stopped"); viewer.stop(silently: true); watchState = .failed("The stream ended.") }
            rebuildMembers()
        case .guildOrder(let order):
            guildOrder = order
            sortGuilds()
        case .voiceState(let userID, let channelID, let user):
            if let user { knownUsers[userID] = user }
            voiceChannelOf[userID] = channelID
            rebuildMembers()
        case .voiceStates(let states, let users):
            for u in users { knownUsers[u.id] = u }
            for s in states { voiceChannelOf[s.userID] = s.channelID }
            rebuildMembers()
        case .streamCreate(let key, let rtc):
            if key == watchKey { watchRTC = rtc; startWatchIfReady(); return }
            guard key == streamKey else { return }
            streamRTC = rtc
            startStreamIfReady()
        case .streamServer(let key, let endpoint, let token):
            if key == watchKey { watchServer = (endpoint, token); startWatchIfReady(); return }
            guard key == streamKey else { return }
            streamServer = (endpoint, token)
            startStreamIfReady()
        case .streamDelete(let key, let reason):
            if key == watchKey {
                LogStore.shared.log("[discord-watch] Discord ended the stream: \(reason)")
                viewer.stop(silently: true)
                watchKey = nil; watchRTC = nil; watchServer = nil
                watchState = .failed(reason == "stream_ended" ? "The stream ended." : "Discord closed the stream (\(reason)).")
                return
            }
            guard key == streamKey else { return }
            LogStore.shared.log("[discord-stream] Discord ended the stream: \(reason)")
            stream.stop(silently: true)
            streamKey = nil; streamRTC = nil; streamServer = nil
            streamState = .failed("Discord ended the stream (\(reason)).")
        case .ownVoiceState(let userID, let sessionID, _, let channelID):
            guard userID == me?.id else { return }
            if channelID != nil { voiceSessionID = sessionID; startVoiceIfReady() }
        case .voiceServer(let guildID, let token, let endpoint):
            guard let target = voiceTarget, target.guild == guildID, let endpoint else { return }
            voiceServer = (token, endpoint)
            startVoiceIfReady()
        case .disconnected(let authFailed, let code):
            LogStore.shared.log("[discord] disconnected (code \(code))\(authFailed ? ": Discord says the sign-in is no longer valid" : "")")
            if authFailed {
                releaseBackground()
                keychain.delete()
                me = nil
                friends = []
                state = .failed("Discord says this sign-in is no longer valid. Sign in again.")
            } else {
                state = .failed("The connection to Discord was lost. Reconnecting.")
                scheduleReconnect()
            }
        }
    }
}

/// The account token, in the Keychain of this device and nowhere else.
struct DiscordTokenStore {
    private let service = "site.portholehq.discord"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"] }

    func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}


/// How many messages are waiting, for the Social tab's badge. A separate small object so the app's tab bar redraws when the count changes and not on every Discord event.
@MainActor @Observable
final class DiscordBadge {
    static let shared = DiscordBadge()
    var count = 0
}
