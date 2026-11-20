// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The box a message is typed in, with Send. A tap puts the cursor in it (the Return key of a keyboard sends); A on a controller opens the pad keyboard. Nothing is sent
/// until Send is pressed.
struct DiscordComposer: View {
    /// What the empty box says ("Message #general").
    let prompt: String
    @Binding var text: String
    var sending: Bool
    var error: String?
    /// A phone held sideways: a lower box.
    var compact = false
    /// What the box is for besides a new message: "Replying to Alex: ..." or "Editing your message", with a way to give it up.
    var context: (title: String, symbol: String)?
    var cancelContext: () -> Void = {}
    let send: () -> Void
    @FocusState private var focused: Bool
    @State private var padOpen = false

    private var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var over: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count - OutgoingMessage.maxLength }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            if let context {
                HStack(spacing: 8) {
                    Image(systemName: context.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(context.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: cancelContext) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.textDim).frame(width: 34, height: 34).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Cancel")
                        .focusTarget("dc-compose-cancel", radius: 17, scale: 1.0, action: cancelContext)
                }
                .padding(.horizontal, 14).background(Theme.panelHigh, in: Capsule())
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
            else if over > -200 { Text(over > 0 ? "\(over) characters too long" : "\(-over) characters left").font(.caption).foregroundStyle(over > 0 ? Theme.warn : Theme.textDim) }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if TextEntry.padMode {
                        // Not a text field while a controller is connected: nothing can raise iOS's keyboard by itself.
                        Text(text.isEmpty ? prompt : text).foregroundStyle(text.isEmpty ? Theme.textDim : Theme.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField(prompt, text: $text).focused($focused).submitLabel(.send).onSubmit { if canSend { send() } }.foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 16).frame(minHeight: compact ? 36 : 44)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { if TextEntry.padMode { padOpen = true } }
                .focusTarget("dc-compose", radius: 22, scale: 1.01, label: "Type", action: { if TextEntry.padMode { padOpen = true } else { focused = true } })
                .sheet(isPresented: $padOpen) { PadKeyboardSheet(title: prompt, text: $text) }
                PillButton(id: "dc-send", title: sending ? "Sending" : "Send", symbol: "paperplane.fill", style: .primary, enabled: canSend) { send() }
            }
        }
    }
}
