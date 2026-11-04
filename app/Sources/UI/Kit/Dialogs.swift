// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A text box as a row. Pressed with a tap, the iOS keyboard comes up; pressed with A on a controller, the pad keyboard opens instead.
struct TextFieldRow: View {
    let id: AnyHashable
    var symbol: String?
    let title: String
    var placeholder = ""
    var info: String?
    var secure = false
    var monospaced = false
    var keyboard: UIKeyboardType = .default
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var padOpen = false

    var body: some View {
        RowBase(id: id, symbol: symbol, title: title, info: info, action: { if TextEntry.padMode { padOpen = true } else { focused = true } }) {
            Group {
                if TextEntry.padMode {
                    // A plain line while a controller is connected (see TextEntry.padMode): A or a tap opens the pad keyboard, nothing raises iOS's.
                    Text(text.isEmpty ? placeholder : (secure ? String(repeating: "\u{2022}", count: text.count) : text)).lineLimit(1)
                        .foregroundStyle(text.isEmpty ? Theme.textDim : Theme.accent)
                } else if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .focused($focused)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
            .font(monospaced ? .system(size: 14, design: .monospaced) : .system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.accent).multilineTextAlignment(.trailing).frame(maxWidth: 260)
        }
        .sheet(isPresented: $padOpen) { PadKeyboardSheet(title: title, secure: secure, monospaced: monospaced, text: $text) }
    }
}

/// "Are you sure?" that a controller can answer.
struct ConfirmSheet: View {
    let title: String
    var message: String?
    var confirmTitle = "Confirm"
    var destructive = false
    let scope: FocusScope
    let done: (Bool) -> Void

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                if let message { Text(message).font(.body).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    PillButton(id: "confirm-no", title: "Cancel", symbol: "xmark") { done(false) }
                    PillButton(id: "confirm-yes", title: confirmTitle, symbol: "checkmark", style: destructive ? .danger : .primary) { done(true) }
                }
            }
            .padding(24)
        }
        .navScope(scope)
        .onAppear { scope.onBack = { done(false) }; scope.defaultFocus = "confirm-no"; scope.focused = "confirm-no" }
        .presentationDetents([.height(230), .medium])
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}

extension View {
    /// Asks before doing something; the question is a sheet a controller can answer.
    func confirm(_ title: String, message: String? = nil, confirmTitle: String = "Confirm", destructive: Bool = false, isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        modifier(ConfirmModifier(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, isPresented: isPresented, action: action))
    }
}

private struct ConfirmModifier: ViewModifier {
    let title: String, message: String?, confirmTitle: String, destructive: Bool
    @Binding var isPresented: Bool
    let action: () -> Void
    @State private var scope = FocusScope()
    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ConfirmSheet(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, scope: scope) { yes in
                // The action runs first: several screens keep the thing being confirmed in state that closing the sheet clears (for example a release chosen from a list),
                // and an action that ran after the close found nothing and silently did nothing.
                if yes { action() }
                isPresented = false
            }
        }
    }
}

/// Long text (a licence, the log) in a sheet that the D-pad scrolls: each paragraph is a stop.
struct TextReaderSheet: View {
    let title: String
    let text: String
    var monospaced = false
    let scope: FocusScope
    let done: () -> Void

    private var blocks: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                    PillButton(id: "reader-close", title: "Close", symbol: "xmark", action: done)
                }
                FocusScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(blocks.indices, id: \.self) { i in
                            Text(blocks[i])
                                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 14))
                                .foregroundStyle(Theme.text.opacity(0.92))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .focusTarget("block-\(i)", radius: 12, scale: 1.0, glow: true, action: {})
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
        .navScope(scope)
        .onAppear { scope.onBack = done; scope.defaultFocus = "reader-close"; scope.focused = "reader-close" }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}

/// The frame every full-screen sheet shares: the ambient backdrop, a title with a close button, a scrolling body, and its own focus scope so a controller works inside it.
struct KitSheet<Content: View>: View {
    let title: String
    var closeTitle = "Cancel"
    var closeSymbol = "xmark"
    let scope: FocusScope
    var defaultFocus: AnyHashable?
    var width: CGFloat = 680
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(title).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    PillButton(id: "sheet-close", title: closeTitle, symbol: closeSymbol, action: close)
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll { content.frame(maxWidth: width).frame(maxWidth: .infinity) }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = close; scope.defaultFocus = defaultFocus ?? AnyHashable("sheet-close"); if scope.focused == nil { scope.focused = scope.defaultFocus } }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}
