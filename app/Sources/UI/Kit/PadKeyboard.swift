// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import GameController

// A keyboard a controller can type on. A text box used to be the one place the D-pad could not finish: pressing A on it did nothing, or raised iOS's keyboard, which a
// controller cannot drive. Now A opens this instead (touch and a hardware keyboard still get the iOS keyboard).
//
//   D-pad / stick  move over the keys        A  type the key         B  delete (closes when there is nothing left)
//   X  space                                 Y  shift                LB / RB  move the cursor
//   Menu (Start)  done

enum TextEntry {
    /// The pad keyboard is for a person who pressed A on the box with a controller and has no hardware keyboard; a tap, or a hardware keyboard, gets iOS's own.
    @MainActor static var wantsPad: Bool { NavHub.shared.isControllerCommand && ControllerInput.shared.connected && GCKeyboard.coalesced == nil }
    /// While a controller is connected (and no hardware keyboard), a text box is not a text field at all: it is a plain line that opens the pad keyboard (A, or a tap).
    /// A real text field can be focused by the system on its own (a D-pad press moving over it), which raised iOS's keyboard with no press of A and then would not go away.
    @MainActor static var padMode: Bool { ControllerInput.shared.connected && GCKeyboard.coalesced == nil }
}

/// A one-line text input for places that are not a row or a search box (a label, a search inside the game menu). An ordinary text field normally; with a controller connected
/// a read-only line that opens the pad keyboard, so iOS's keyboard never comes up by itself.
struct PadTextField: View {
    let title: String
    var prompt = ""
    var secure = false
    var monospaced = false
    var onDone: (() -> Void)?
    @Binding var text: String
    @State private var padOpen = false

    var body: some View {
        if TextEntry.padMode {
            Button { padOpen = true } label: {
                Text(shown).font(monospaced ? .system(size: 14, design: .monospaced) : .body).foregroundStyle(text.isEmpty ? Theme.textDim : Theme.text)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $padOpen, onDismiss: { onDone?() }) { PadKeyboardSheet(title: title, secure: secure, monospaced: monospaced, text: $text) }
        } else if secure {
            SecureField(prompt, text: $text).onSubmit { onDone?() }
        } else {
            TextField(prompt, text: $text).onSubmit { onDone?() }
        }
    }

    private var shown: String { text.isEmpty ? prompt : (secure ? String(repeating: "\u{2022}", count: text.count) : text) }
}

struct PadKeyboardSheet: View {
    let title: String
    var secure = false
    var monospaced = false
    @Binding var text: String

    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var layer = KeyLayer.letters
    @State private var shift = false
    @State private var caret = 0
    @State private var original = ""
    @State private var revealed = false

    enum KeyLayer { case letters, symbols }

    private static let digits = Array("1234567890").map(String.init)
    private static let top = Array("qwertyuiop").map(String.init)
    private static let home = Array("asdfghjkl").map(String.init)
    private static let bottom = Array("zxcvbnm").map(String.init)
    private static let symbolsA = Array("@#$%&*-+()").map(String.init)
    private static let symbolsB = Array("!\"':;/\\?_").map(String.init)
    private static let symbolsC = Array("~^=<>[]{}").map(String.init)

    var body: some View {
        GeometryReader { geo in
            let keyHeight = min(46, max(30, (geo.size.height - 112 - 4 * 5 - (ControllerInput.shared.connected ? 22 : 0)) / 5))
            ZStack {
                AmbientBackdrop(animated: false)
                VStack(spacing: 10) {
                    header
                    entry
                    VStack(spacing: 5) {
                        row(Self.digits.map { char($0) }, height: keyHeight)
                        if layer == .letters {
                            row(Self.top.map { char($0) }, height: keyHeight)
                            row(Self.home.map { char($0) }, height: keyHeight, inset: 0.5)
                            row([key("shift", symbol: shift ? "shift.fill" : "shift", weight: 1.5, tinted: shift, action: { shift.toggle() })]
                                + Self.bottom.map { char($0) } + [backspaceKey(weight: 1.5)], height: keyHeight)
                        } else {
                            row(Self.symbolsA.map { char($0) }, height: keyHeight)
                            row(Self.symbolsB.map { char($0) }, height: keyHeight, inset: 0.5)
                            row(Self.symbolsC.map { char($0) } + [backspaceKey(weight: 1.5)], height: keyHeight)
                        }
                        row([key("layer", label: layer == .letters ? "?123" : "abc", weight: 1.5, action: { layer = layer == .letters ? .symbols : .letters }),
                             char(","),
                             key("space", label: "space", weight: 4.5, action: { insert(" ") }),
                             char("."),
                             key("done", symbol: "checkmark", weight: 1.5, accent: true, action: { dismiss() })], height: keyHeight)
                    }
                    if ControllerInput.shared.connected { legend }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .navScope(scope)
        .onAppear {
            original = text; caret = text.count
            scope.defaultFocus = "key-g"; scope.focused = "key-g"
            scope.onBack = { backOrCancel() }
            scope.onMenu = { dismiss() }
            scope.onTertiary = { shift.toggle() }
            scope.onSecondary = { insert(" ") }
            scope.onSection = { step in caret = min(max(caret + step, 0), text.count) }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .interactiveDismissDisabled(false)
        .preferredColorScheme(Theme.scheme)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            if secure {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash.fill" : "eye.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textDim).frame(width: 40, height: 34)
                }
                .buttonStyle(.plain).focusTarget("key-reveal", radius: 17, scale: 1.1) { revealed.toggle() }
            }
            Button { text = original; dismiss() } label: {
                Text("Cancel").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).padding(.horizontal, 14).frame(height: 34)
                    .background(Theme.panelHigh, in: Capsule())
            }
            .buttonStyle(.plain).focusTarget("key-cancel", radius: 17, scale: 1.08) { text = original; dismiss() }
        }
    }

    /// What each button does, named as it is printed on the controller in use.
    private var legend: some View {
        let g = ControllerInput.shared.kind.glyph
        return Text("\(g("A")) type   \(g("B")) delete   \(g("X")) space   \(g("Y")) shift   \(g("LB")) \(g("RB")) cursor   \(g("Menu")) done")
            .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1).minimumScaleFactor(0.7)
    }

    /// What has been typed, with the cursor where the next character goes.
    private var entry: some View {
        let chars = Array(text)
        let cut = min(caret, chars.count)
        let shown: (String) -> String = { s in secure && !revealed ? String(repeating: "\u{2022}", count: s.count) : s }
        let font: Font = monospaced ? .system(size: 17, design: .monospaced) : .system(size: 18, weight: .semibold, design: .rounded)
        return (Text(shown(String(chars[..<cut]))) + Text("\u{258F}").foregroundColor(Theme.accent) + Text(shown(String(chars[cut...]))))
            .font(font).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 44)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func row(_ keys: [KeyCap], height: CGFloat, inset: CGFloat = 0) -> some View {
        let layout = WeightedRow(spacing: 5)
        return layout {
            if inset > 0 { Color.clear.weight(inset) }
            ForEach(keys) { $0.frame(height: height).weight($0.weight) }
            if inset > 0 { Color.clear.weight(inset) }
        }
        .frame(height: height)
    }

    private func char(_ c: String) -> KeyCap {
        let shown = layer == .letters && shift ? c.uppercased() : c
        return KeyCap(id: "key-\(c)", label: shown, weight: 1, action: { insert(shown); if shift { shift = false } })
    }
    private func key(_ id: String, label: String? = nil, symbol: String? = nil, weight: CGFloat, tinted: Bool = false, accent: Bool = false, action: @escaping () -> Void) -> KeyCap {
        KeyCap(id: "key-\(id)", label: label, symbol: symbol, weight: weight, tinted: tinted, accent: accent, action: action)
    }
    private func backspaceKey(weight: CGFloat) -> KeyCap { key("back", symbol: "delete.left.fill", weight: weight, action: { _ = backspace() }) }

    // MARK: Editing

    private func insert(_ s: String) {
        var chars = Array(text)
        let at = min(caret, chars.count)
        chars.insert(contentsOf: Array(s), at: at)
        text = String(chars)
        caret = at + s.count
    }

    private func backspace() -> Bool {
        var chars = Array(text)
        let at = min(caret, chars.count)
        guard at > 0 else { return false }
        chars.remove(at: at - 1)
        text = String(chars)
        caret = at - 1
        return true
    }

    /// B deletes a character; with nothing left to delete it closes the keyboard, keeping what is there.
    private func backOrCancel() {
        if !backspace() { dismiss() }
    }
}

/// One key: a cap that can be touched, and a focus target for the D-pad.
private struct KeyCap: View, Identifiable {
    let id: String
    var label: String?
    var symbol: String?
    var weight: CGFloat
    var tinted = false
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .bold)) }
                else if let label { Text(label).font(.system(size: label.count > 1 ? 14 : 19, weight: .semibold, design: .rounded)) }
            }
            .foregroundStyle(accent ? Theme.onAccent : tinted ? Theme.accent : Theme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(accent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(tinted ? Theme.accent.opacity(0.18) : Theme.panelHigh), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: accent ? 0 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 9, scale: 1.1, action: action)
    }
}

private struct RowWeight: LayoutValueKey { static let defaultValue: CGFloat = 1 }
private extension View { func weight(_ w: CGFloat) -> some View { layoutValue(key: RowWeight.self, value: w) } }

/// Lays its children out in one line, each as wide as its weight says.
private struct WeightedRow: SwiftUI.Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 40)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let total = subviews.reduce(0) { $0 + $1[RowWeight.self] }
        let free = bounds.width - spacing * CGFloat(subviews.count - 1)
        var x = bounds.minX
        for s in subviews {
            let w = free * s[RowWeight.self] / total
            s.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

/// A search box in a capsule. A tap puts the cursor in it; A on a controller opens the pad keyboard.
struct SearchField: View {
    let id: AnyHashable
    let prompt: String
    @Binding var text: String
    var minWidth: CGFloat = 200
    @FocusState private var focused: Bool
    @State private var padOpen = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
            if TextEntry.padMode {
                // Not a text field while a controller is connected: nothing can raise iOS's keyboard by itself.
                Text(text.isEmpty ? prompt : text).foregroundStyle(text.isEmpty ? Theme.textDim : Theme.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: $text).focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(Theme.text)
            }
        }
        .padding(.horizontal, 14).frame(minWidth: minWidth, minHeight: 40)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { if TextEntry.padMode { padOpen = true } }
        .focusTarget(id, radius: 20, scale: 1.02, label: "Type", action: { if TextEntry.padMode { padOpen = true } else { focused = true } })
        .sheet(isPresented: $padOpen) { PadKeyboardSheet(title: "Search", text: $text) }
        .layoutValue(key: ControlsFlow.Flexible.self, value: true)    // in a store's controls it takes the room left on its line
    }
}
