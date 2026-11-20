// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// Banners over a running game for Discord messages (Discord branch, experimental). Off until the person turns it on; they pick which messages count.
///
/// Safe for the game: a banner shows only while a game runs and its menu is closed; one at a time, each for a few seconds, with a pause between two; a conversation never has more than
/// one banner waiting; and none while a stream (Go Live) is going, so nobody watching sees your messages. It takes touches only inside its own small card.
@MainActor
final class DiscordNotifier: ObservableObject {
    static let shared = DiscordNotifier()
    private static let prefix = "f4.discord.notify."
    /// How long a banner stays, and the least time between the end of one and the start of the next.
    static let showFor: TimeInterval = 6, gap: TimeInterval = 2

    @Published var enabled: Bool { didSet { save(); if !enabled { dismissAll(); recent = [] } } }
    @Published var kind: DiscordNotifyKind { didSet { save() } }
    /// Show a banner when a call rings (a direct message or group chat): Join or Decline without opening the menu. Off until turned on, separately from messages.
    @Published var callBanners: Bool { didSet { save(); if !callBanners { incomingCall = nil } } }
    /// Show the start of the message in the banner (off: the banner only says who wrote to you).
    @Published var showText: Bool { didSet { save() } }

    struct Recent: Identifiable, Equatable {
        var conversation: DiscordConversation
        var author: DiscordUser
        var text: String
        var date: Date
        var id: String { conversation.id }
    }

    @Published private(set) var current: DiscordBanner?
    /// The conversations that notified lately, newest first: the in-game menu lists them for replying.
    @Published private(set) var recent: [Recent] = []
    /// A conversation to open in the in-game menu's Discord tab (set when a banner is tapped).
    @Published var focus: String?
    /// The HUD says whether a game is running with its menu closed.
    var gameShowing = false { didSet { refreshShowing(); objectWillChange.send() } }
    /// The app's own screens are showing (no game is running): banners slide in over them too, so a message is not missed between games.
    var appShowing = false { didSet { refreshShowing(); objectWillChange.send() } }
    /// A banner can be shown now: over a running game or over the app.
    var showing: Bool { gameShowing || appShowing }

    private func refreshShowing() {
        if showing { testNote = nil; pump() } else { dismissAll() }
    }

    /// The conversation or channel the person is reading right now in the Discord screen: it needs no banner, and what arrives in it is not counted as unread.
    var viewing: String? { DiscordSession.shared.viewingChannel }

    // MARK: calls

    /// A call ringing for this account, until it is answered, declined, ends, or a minute and a quarter passes (Discord stops ringing by then).
    @Published private(set) var incomingCall: DiscordIncomingCall?
    /// The call is shown as a banner over the game (otherwise it waits in the in-game menu's Discord tab).
    var callBannerShowing: Bool { incomingCall != nil && showing && !streaming }
    /// Whether the banner area takes touches now.
    var bannerTouchable: Bool { current != nil || callBannerShowing }
    static let ringLimit: TimeInterval = 75

    func callRinging(_ call: DiscordIncomingCall) {
        guard callBanners else { return }
        var call = call
        if let existing = incomingCall, existing.channelID == call.channelID { call.since = existing.since } else if showing, !streaming { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        incomingCall = call
        let channel = call.channelID, since = call.since
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringLimit) { [weak self] in
            if self?.incomingCall?.channelID == channel, self?.incomingCall?.since == since { self?.incomingCall = nil; self?.pump() }
        }
    }

    func callEnded(channelID: String) {
        guard incomingCall?.channelID == channelID else { return }
        incomingCall = nil
        pump()
    }

    /// Join was pressed.
    func answerCall() {
        guard let call = incomingCall else { return }
        incomingCall = nil
        DiscordSession.shared.joinCall(call)
        pump()
    }

    /// Decline was pressed.
    func declineCall() {
        guard let call = incomingCall else { return }
        incomingCall = nil
        DiscordSession.shared.declineCall(call)
        pump()
    }
    /// Tapping a banner over a game (the HUD opens the menu on the conversation).
    var onOpen: ((DiscordConversation) -> Void)?
    /// Tapping a banner over the app's screens (the Social tab opens on the conversation).
    var onOpenInApp: ((DiscordConversation) -> Void)?

    private var queue = DiscordBannerQueue()
    private var lastEnd = Date.distantPast
    private var pumpScheduled = false

    private init() {
        let d = UserDefaults.standard, p = Self.prefix
        enabled = d.bool(forKey: p + "enabled")
        kind = DiscordNotifyKind(rawValue: d.string(forKey: p + "kind") ?? "") ?? .mentions
        showText = d.object(forKey: p + "showText") as? Bool ?? true
        callBanners = d.bool(forKey: p + "calls")
    }

    private func save() {
        let d = UserDefaults.standard, p = Self.prefix
        d.set(enabled, forKey: p + "enabled"); d.set(kind.rawValue, forKey: p + "kind"); d.set(showText, forKey: p + "showText"); d.set(callBanners, forKey: p + "calls")
    }

    /// A message arrived: if it passes the person's choice it is remembered for the menu and, when a banner would be safe, shown.
    func consider(_ message: DiscordMessage, me: String, conversation: DiscordConversation) {
        guard enabled, DiscordNotifyRule.shouldNotify(message, me: me, kind: kind), conversation.id != viewing else { return }
        let preview = Self.preview(message)
        recent.removeAll { $0.conversation.id == conversation.id }
        recent.insert(Recent(conversation: conversation, author: message.author, text: preview, date: message.date), at: 0)
        if recent.count > 6 { recent.removeLast(recent.count - 6) }
        guard showing, !streaming else { return }
        queue.push(DiscordBanner(conversation: conversation, author: message.author, text: showText ? preview : "New message"))
        pump()
    }

    func forgetRecent() { recent = [] }

    /// A banner that says what a real one looks like. It is used from the in-game menu, which holds banners back, so this one waits and slides in when the menu closes.
    func test() {
        guard !streaming else { testNote = "Not while you stream with Go Live."; return }
        testNote = "Close this menu and the test banner slides in."
        queue.push(DiscordBanner(conversation: DiscordConversation(id: "porthole-test", title: "#general", place: "Porthole"), author: DiscordUser(id: "0", username: "porthole", globalName: "Porthole"),
                                 text: showText ? "This is how a message will look. Tap it to answer." : "New message"))
        pump()
    }
    @Published var testNote: String?

    /// The banner was tapped.
    func open(_ banner: DiscordBanner) {
        dismiss()
        // The test banner has no conversation, but a tap still opens the Discord tab (so it is clear that tapping works).
        if banner.conversation.id != "porthole-test" { focus = banner.conversation.id }
        if gameShowing { onOpen?(banner.conversation) } else { onOpenInApp?(banner.conversation) }
    }

    /// Swiped away, or its time is up.
    func dismiss() {
        guard current != nil else { return }
        current = nil
        lastEnd = Date()
        schedulePump(after: Self.gap)
    }

    func dismissAll() {
        queue.clear()
        if current != nil { current = nil; lastEnd = Date() }
    }

    private var streaming: Bool {
        switch DiscordSession.shared.streamState { case .starting, .live: true; default: false }
    }

    private func pump() {
        guard current == nil, incomingCall == nil, showing, !streaming, !queue.isEmpty else { return }
        let wait = Self.gap - Date().timeIntervalSince(lastEnd)
        if wait > 0 { schedulePump(after: wait); return }
        guard let banner = queue.pop() else { return }
        current = banner
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showFor) { [weak self] in
            if self?.current?.id == banner.id { self?.dismiss() }
        }
    }

    private func schedulePump(after delay: TimeInterval) {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in self?.pumpScheduled = false; self?.pump() }
    }

    /// What the banner and the menu show of a message: its text, else its first attachment.
    static func preview(_ message: DiscordMessage) -> String {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(140)) }
        if let a = message.attachments.first { return a.isImage ? "Sent a picture" : "Sent \(a.name)" }
        if let e = message.embeds.first { return e.title ?? e.description.map { String($0.prefix(140)) } ?? (e.imageURL != nil ? "Sent a picture" : "New message") }
        if message.stickers.first != nil { return "Sent a sticker" }
        return message.extras.first ?? "New message"
    }
}
