// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Discord's setup and settings (experimental): the first thing the Social tab shows until you are signed in, and what its gear button opens afterwards. Off until the person turns it on after reading what it means.
struct DiscordPage: View {
    @ObservedObject private var discord = DiscordSession.shared
    @ObservedObject private var overlay = DiscordOverlaySettings.shared
    @ObservedObject private var notifier = DiscordNotifier.shared
    @State private var confirmEnable = false
    @State private var confirmActivity = false
    @State private var showWebLogin = false

    static let warning = "Porthole is not an official Discord client. Discord's terms do not allow third-party clients, and an account used with one can be limited or banned. Use an account you can afford to lose. Porthole says what it is to Discord and does not pretend to be the official app."

    var body: some View {
        PageScaffold(title: "Discord", symbol: "bubble.left.and.bubble.right.fill", subtitle: "Experimental") {
            if !discord.enabled {
                SettingsGroup(title: "Read this first") {
                    Text(Self.warning).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsGroup(title: "Discord features") {
                ToggleRow(id: "dc-enable", symbol: "bubble.left.and.bubble.right.fill", title: "Use Discord in Porthole",
                          info: "Turns on the experimental Discord features. Nothing connects to Discord until you sign in, and turning this off disconnects it.",
                          isOn: Binding(get: { discord.enabled }, set: { on in if on { confirmEnable = true } else { discord.setEnabled(false) } }))
            }
            if discord.enabled { account }
        }
        .alert("Turn on Discord features?", isPresented: $confirmEnable) {
            Button("Turn on") { discord.setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(Self.warning) }
        .sheet(isPresented: $showWebLogin) { DiscordWebLogin { discord.signIn(withToken: $0) } }
        .onAppear { if discord.enabled, discord.state == .signedOut { discord.connectIfSignedIn() } }
    }

    @ViewBuilder private var account: some View {
        SettingsGroup(title: "Account") {
            switch discord.state {
            case .signedOut:
                ActionRow(id: "dc-signin-web", symbol: "person.badge.key.fill", title: "Sign in with email and password", subtitle: "On Discord's own login page, inside Porthole",
                          info: "Opens discord.com's login page here. You type your password, captcha and two-step code into Discord's page; Porthole never sees them. When you are signed in, Porthole keeps the account's sign-in token in the Keychain and discards the page's cookies.") { showWebLogin = true }
                ActionRow(id: "dc-signin", symbol: "qrcode", title: "Sign in with a QR code", subtitle: "Scan it with the Discord app on another device",
                          info: "Shows a code. Open Discord on another device, go to Settings, Scan QR Code, and scan it. You confirm on that device: your password never reaches Porthole.") { discord.startSignIn() }
            case .connecting:
                ValueRow(id: "dc-connecting", symbol: "hourglass", title: "Connecting", value: "")
                ActionRow(id: "dc-cancel", symbol: "xmark", title: "Cancel", chevron: false) { discord.cancelSignIn() }
            case .waitingForScan(let url):
                QRCodeView(url: url)
                ActionRow(id: "dc-open-app", symbol: "arrow.up.forward.app", title: "Open in the Discord app on this device", subtitle: "If Discord is installed here; confirm there, then come back", chevron: false) { UIApplication.shared.open(url) }
                ActionRow(id: "dc-cancel", symbol: "xmark", title: "Cancel", chevron: false) { discord.cancelSignIn() }
            case .waitingForConfirm(let who):
                ValueRow(id: "dc-confirm", symbol: "iphone", title: "Scanned by \(who)", value: "Confirm on the other device")
                ActionRow(id: "dc-cancel", symbol: "xmark", title: "Cancel", chevron: false) { discord.cancelSignIn() }
            case .failed(let message):
                ValueRow(id: "dc-failed", symbol: "exclamationmark.triangle.fill", title: "Could not sign in", value: message, statusColor: Theme.bad)
                ActionRow(id: "dc-retry", symbol: "arrow.clockwise", title: "Try again", chevron: false) { discord.retry() }
            case .connected:
                ValueRow(id: "dc-me", symbol: "person.crop.circle.fill", title: "Signed in as", value: discord.me?.displayName ?? "")
                ActionRow(id: "dc-signout", symbol: "rectangle.portrait.and.arrow.right", title: "Sign out", subtitle: "Removes the sign-in from this device", chevron: false) { discord.signOut() }
            }
        }
        if discord.state == .connected {
            voiceSection
            notificationsSection
            activitySection
        }
    }
}

extension DiscordPage {
    /// "Playing <game>" on the account while a game runs. Off until turned on, and it asks once.
    @ViewBuilder var activitySection: some View {
        SettingsGroup(title: "Activity", note: "What your friends see next to your name.") {
            ToggleRow(id: "dc-activity", symbol: "gamecontroller.fill", title: "Show what I am doing in Porthole",
                      info: "Your friends and the servers you are in see what you are doing, next to your name: \u{201C}Firewatch on Porthole\u{201D} while a game runs (the name it has in your Porthole library), and \u{201C}Browsing their library\u{201D}, \u{201C}Downloading <a game>\u{201D}, \u{201C}Adjusting settings\u{201D} and similar while you use the app, with how long. Off until you turn it on. Discord's own app does this by recognising games; Porthole cannot, so it tells Discord itself, which is one more thing that marks the account as not using Discord's own app.",
                      isOn: Binding(get: { discord.shareActivity }, set: { on in if on { confirmActivity = true } else { discord.shareActivity = false } }))
        }
        .alert("Show what you are doing?", isPresented: $confirmActivity) {
            Button("Show it") { discord.shareActivity = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your friends will see \u{201C}<game> on Porthole\u{201D} while a game runs, and what you are doing in the app (browsing your library, downloading, adjusting settings) otherwise. Porthole is not an official Discord client, and telling Discord this way is something only an unofficial client does.") }
    }

    /// Banners for messages over a running game and over the app's own screens. Off until turned on; the person picks which messages.
    @ViewBuilder var notificationsSection: some View {
        SettingsGroup(title: "Message notifications", note: "A banner slides in over a running game, or over the app between games, when a message you chose arrives, or a friend calls. Tap it to open the conversation (the in-game menu over a game, the Social tab otherwise) and answer. One at a time, never while the menu is open and never while you stream with Go Live. Off until you turn it on.") {
            ToggleRow(id: "dc-n-on", symbol: "bell.badge.fill", title: "Notify me of messages",
                      info: "Shows a banner for the messages you pick below, over a running game (with its menu closed) and over the app's own screens. Not for the conversation you are reading. The Social tab shows how many messages are waiting. Messages are kept in memory only.",
                      isOn: Binding(get: { notifier.enabled }, set: { notifier.enabled = $0 }))
            ToggleRow(id: "dc-n-calls", symbol: "phone.arrow.down.left.fill", title: "Show incoming calls",
                      info: "When a friend calls you in a direct message or group chat, a banner over the game has Join and Decline on it, so you can answer without opening the menu. Calls in a server's voice channels do not ring. Off until you turn it on.",
                      isOn: Binding(get: { notifier.callBanners }, set: { notifier.callBanners = $0 }))
            if notifier.enabled {
                ChoiceRow(id: "dc-n-kind", symbol: "line.3.horizontal.decrease.circle.fill", title: "Which messages", subtitle: notifier.kind.detail,
                          options: DiscordNotifyKind.allCases.map { ($0, $0.title) }, selection: Binding(get: { notifier.kind }, set: { notifier.kind = $0 }))
                ToggleRow(id: "dc-n-text", symbol: "text.alignleft", title: "Show the message in the banner",
                          info: "Off: the banner only says who wrote to you and where, not what. Use that where other people can see your screen.",
                          isOn: Binding(get: { notifier.showText }, set: { notifier.showText = $0 }))
            }
        }
    }

    @ViewBuilder var voiceSection: some View {
        SettingsGroup(title: "Voice (test)", note: "Joins a voice channel with sound: you hear the channel and it hears your microphone once the encryption handshake is done. It shows up in the channel's list while connected. Use headphones: there is no echo cancelling for a loudspeaker yet.") {
            ValueRow(id: "dc-dave", symbol: "lock.shield.fill", title: "Encryption library", value: DaveCheck.result)
            switch discord.voiceState {
            case .idle: EmptyView()
            case .joining(let label): ValueRow(id: "dc-v-state", symbol: "hourglass", title: "Joining", value: label)
            case .ready(let label): ValueRow(id: "dc-v-state", symbol: "checkmark.circle.fill", title: "Accepted by Discord", value: label, statusColor: .green)
            case .refused(let why): ValueRow(id: "dc-v-state", symbol: "exclamationmark.triangle.fill", title: "Not accepted", value: why, statusColor: Theme.bad)
            }
            if discord.voiceState != .idle { ActionRow(id: "dc-v-leave", symbol: "phone.down.fill", title: "Leave", chevron: false) { discord.leaveVoice() } }
            if discord.voiceState != .idle {
                ToggleRow(id: "dc-v-mute", symbol: "mic.slash.fill", title: "Mute my microphone", info: "Stops sending your voice. You still hear the channel.",
                          isOn: Binding(get: { discord.micMuted }, set: { discord.setMicMuted($0) }))
                ToggleRow(id: "dc-v-echo", symbol: "waveform.path", title: "Reduce echo (experimental)", info: "If other people hear themselves back from your speakers: while the call is playing, your microphone sends nothing unless you are clearly louder than the speakers. It is not true echo cancelling, so you will not be heard over someone who is louder than you. Headphones fix echo completely.",
                          isOn: Binding(get: { discord.reduceEcho }, set: { discord.reduceEcho = $0 }))
                ToggleRow(id: "dc-v-ptt", symbol: "hand.tap.fill", title: "Push to talk", info: "Your microphone sends only while you hold the Talk button, a microphone at the top of the game screen while you are in a call. Nobody sees a mute: you simply speak when you press.",
                          isOn: Binding(get: { discord.pushToTalk }, set: { discord.pushToTalk = $0 }))
                ToggleRow(id: "dc-v-deafen", symbol: "speaker.slash.fill", title: "Deafen", info: "Stops playing the call and mutes your microphone too. Turning your microphone back on ends the deafen.",
                          isOn: Binding(get: { discord.deafened }, set: { discord.setDeafened($0) }))
            }
            ForEach(discord.callMembers) { member in
                ValueRow(id: "dc-m-\(member.id)", symbol: member.speaking ? "waveform" : "person.fill", title: member.isSelf ? "\(member.name) (you)" : member.name, value: member.speaking ? "Talking" : "",
                         statusColor: member.speaking ? .green : nil)
            }
            if case .ready = discord.voiceState {
                switch discord.streamState {
                case .idle, .failed(_):
                    ActionRow(id: "dc-v-quality", symbol: "slider.horizontal.3", title: "Stream quality: \(discord.streamQuality.title)", subtitle: "\(discord.streamQuality.detail). Tap to change; lower is smoother on a weak connection.", chevron: false) { discord.cycleStreamQuality() }
                    ActionRow(id: "dc-v-live", symbol: "dot.radiowaves.left.and.right", title: "Go Live (test picture)", subtitle: { if case .failed(let why) = discord.streamState { return why }; return "Streams a moving test picture to the channel." }(), chevron: false) { discord.startStream() }
                case .starting, .live:
                    ActionRow(id: "dc-v-live", symbol: "stop.circle.fill", title: "Stop streaming", subtitle: discord.streamState == .live ? "Streaming \(discord.streamDescription)." : "Starting the stream.", chevron: false) { discord.stopStream() }
                }
            }
            if discord.voiceState != .idle {
                ToggleRow(id: "dc-ov", symbol: "rectangle.on.rectangle", title: "Show who is in the call over the game", info: "A small list over a running game with a ring round whoever is talking. The corner, size and who to show are in the Discord tab of the in-game menu.",
                          isOn: Binding(get: { overlay.enabled }, set: { overlay.enabled = $0 }))
            }
            SliderRow(id: "dc-v-game", symbol: "gamecontroller.fill", title: "Game volume", info: "How loud the game is while you are in a call, 10 to 200 percent of its normal level. The volume buttons of the phone stay in front of both.",
                      value: Binding(get: { discord.gameVolume }, set: { discord.setGameVolume($0) }), range: 10...200, step: 5, format: { "\(Int($0))%" })
            SliderRow(id: "dc-v-call", symbol: "bubble.left.and.bubble.right.fill", title: "Call volume", info: "How loud the people in the call are, 0 to 200 percent. Turn the game down and the call up (or the other way round) to set which one you hear better.",
                      value: Binding(get: { discord.callVolume }, set: { discord.setCallVolume($0) }), range: 0...200, step: 5, format: { "\(Int($0))%" })
            SliderRow(id: "dc-v-sens", symbol: "mic.fill", title: "Microphone sensitivity", info: "How quiet a sound still counts as you talking. Higher picks up a soft voice but also a noisy room; lower needs you to speak up. Watch the bar below while you talk: it should pass the line when you speak and stay under it when you do not.",
                      value: Binding(get: { discord.micSensitivity }, set: { discord.setMicSensitivity($0) }), range: 0...100, step: 1, format: { "\(Int($0))%" })
            MicLevelBar().padding(.horizontal, 6)
            if discord.voiceState == .idle { Text("Pick a voice channel on the Discord screen.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
        }
    }
}

/// A QR code of an address, large and on white so another device's camera reads it.
struct QRCodeView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 10) {
            if let image = Self.image(for: url) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("Scan this with the Discord app on another device. The code stops working after a couple of minutes.").font(.footnote).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
