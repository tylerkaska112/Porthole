// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import GameController

/// One key the person can choose for something Porthole does in a game: a row that listens for the next key press, and two quieter rows to go back to the default or switch the key off.
struct KeybindRow: View {
    let id: String
    let symbol: String
    let title: String
    let key: String
    let fallback: KeyBind
    @State private var text = ""
    @State private var listening = false

    private var bind: KeyBind? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return fallback }
        return t.lowercased() == "none" ? nil : (KeyBind.parse(t) ?? fallback)
    }

    var body: some View {
        Group {
            ActionRow(id: id, symbol: symbol, title: title,
                      subtitle: listening ? "Press the key now. Esc cancels." : (GCKeyboard.coalesced == nil ? "Connect a keyboard to choose a key" : "Tap, then press a key"),
                      detail: listening ? "Waiting\u{2026}" : (bind?.label ?? "No key"), chevron: false) { listen() }
            if text.isEmpty == false {
                ActionRow(id: id + "-default", symbol: "arrow.uturn.backward", title: "Use the default (\(fallback.label))", chevron: false) { set("") }
            }
            if bind != nil {
                ActionRow(id: id + "-off", symbol: "xmark", title: "No key for this", subtitle: "Only the Ctrl+Alt chord works", chevron: false) { set("none") }
            }
        }
        .onAppear { text = EngineOptions.value(key) }
        .onDisappear { stop() }
    }

    private func set(_ value: String) { text = value; EngineOptions.set(key, value) }

    private func stop() { if listening { HardwareInput.shared.captureKey = nil; listening = false } }

    private func listen() {
        if listening { stop(); return }
        guard GCKeyboard.coalesced != nil else { return }
        listening = true
        HardwareInput.shared.captureKey = { chosen in
            listening = false
            if let chosen { set(chosen.string) }
        }
    }
}
