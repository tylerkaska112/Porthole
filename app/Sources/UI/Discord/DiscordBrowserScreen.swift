// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The Discord browser on the live connection: its data comes from the session and its buttons go back to it.
struct DiscordBrowserScreen: View {
    @ObservedObject private var discord = DiscordSession.shared
    @ObservedObject private var notifier = DiscordNotifier.shared
    /// In the Social tab: no close button, a settings button instead.
    var embedded = false
    var settings: () -> Void = {}
    var otherSection: (title: String, go: () -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var inCall: Bool { if case .idle = discord.voiceState { return false }; return true }

    private var status: String? {
        switch discord.voiceState {
        case .idle: nil
        case .joining: "Joining the call"
        case .ready: "Connected"
        case .refused(let why): "Not accepted: \(why)"
        }
    }

    /// The conversations for the list, with the people in each (a name Discord sent only as an id is looked up from the people this account knows).
    private var conversations: [DiscordBrowserData.Conversation] {
        discord.conversations.map { c in
            let users = c.recipientIDs.filter { $0 != discord.me?.id }.compactMap { id in c.users.first { $0.id == id } ?? discord.knownUser(id) }
            return DiscordBrowserData.Conversation(id: c.id, title: discord.conversationTitle(c), isGroup: c.isGroup, users: users)
        }
    }

    var body: some View {
        DiscordBrowser(
            data: DiscordBrowserData(guilds: discord.guilds, friends: discord.friends, roster: discord.voiceRoster, meName: discord.me?.displayName ?? "", meAvatar: discord.me?.avatarURL,
                                     currentChannelID: inCall ? discord.currentVoiceChannelID : nil, callStatus: status, muted: discord.micMuted, deafened: discord.deafened, directCall: discord.directCallLabel, people: discord.personVolumes,
                                     messages: discord.messages, messageLoad: discord.messageLoad, sending: discord.sendingTo, sendError: discord.sendError,
                                     meID: discord.me?.id ?? "", conversations: conversations, forumPosts: discord.forumPosts, forumLoad: discord.forumLoad,
                                     unread: discord.unread, focusChannelID: notifier.focus,
                                     typing: Dictionary(uniqueKeysWithValues: discord.typingUntil.keys.map { ($0, discord.typingNames(in: $0)) }), olderState: discord.olderState),
            actions: DiscordBrowserActions(join: { guild, channel in discord.joinVoice(guild: guild, channel: channel) }, leave: { discord.leaveVoice() },
                                           toggleMute: { discord.setMicMuted(!discord.micMuted) }, toggleDeafen: { discord.setDeafened(!discord.deafened) },
                                           setPersonVolume: { discord.setPersonVolume($0, $1) }, setPersonMuted: { discord.setPersonMuted($0, $1) },
                                           loadMessages: { discord.loadMessages($0, force: $1) },
                                           sendMessage: { discord.sendMessage($1, to: $0, replyTo: $2, done: $3) },
                                           editMessage: { discord.editMessage($1, in: $0, to: $2, done: $3) },
                                           deleteMessage: { discord.deleteMessage($1, in: $0) },
                                           toggleReaction: { discord.toggleReaction((name: $2, id: $3, animated: $4), on: $1, in: $0) },
                                           loadOlder: { discord.loadOlder($0) },
                                           viewing: { discord.setViewing($0) }, consumeFocus: { notifier.focus = nil },
                                           loadForum: { discord.loadForum($0, force: $1) },
                                           loadProfile: { id, done in Task { done(await discord.loadProfile(id)) } },
                                           openDirect: { id, done in Task { done(await discord.openDirect(with: id)) } },
                                           callDirect: { discord.callDirect(channelID: $0) },
                                           watch: { discord.watchStream(of: $0) },
                                           close: { dismiss() }, settings: settings, otherSection: otherSection),
            embedded: embedded)
    }
}
