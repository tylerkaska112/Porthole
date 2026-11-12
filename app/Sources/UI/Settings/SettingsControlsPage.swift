// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Settings > Controls: every setting about how a game is controlled, in one place. The rows are the same engine options Settings > Advanced > Engine options lists (a change in
// either place is the same setting); the everyday ones are here, the ones that only matter when something is wrong are behind "Show technical options".

struct ControlsPage: View {
    @State private var look = LaunchSettings.globalLookSensitivity
    @State private var values: [String: String] = [:]
    @State private var rumbleMessage: String?
    @State private var compactKeyboard = UserDefaults.standard.bool(forKey: TouchKeyboardView.compactKey)
    @AppStorage("f4.advanced") private var advanced = false

    /// Everyday rows, then the technical ones, by engine option key.
    private static let controllerKeys = ["env.PORTHOLE_RUMBLE", "env.PORTHOLE_PAD_MENU", "env.MADEIRA_PAD_KBM", "env.PORTHOLE_PAD_POINTER", "env.PORTHOLE_HIDE_TOUCH_ON_PAD"]
    private static let controllerTechnicalKeys = ["env.MADEIRA_XINPUT", "env.MADEIRA_PAD_MODE", "env.MADEIRA_HIDPAD_XINPUT", "env.MADEIRA_DINPUT_PAD"]
    private static let keyboardKeys = ["env.PORTHOLE_MOUSE_SPEED", "env.PORTHOLE_MOUSE_LOOK", "env.PORTHOLE_SCROLL_DIRECTION", "env.PORTHOLE_KEY_REPEAT", "env.PORTHOLE_KEY_LAYOUT",
                                       "env.PORTHOLE_HIDE_TOUCH_ON_KEYS"]
    private static let keyboardTechnicalKeys = ["env.MADEIRA_HWINPUT", "env.MADEIRA_INPUT_FOCUS", "env.PORTHOLE_INPUT_DIAGNOSTICS"]

    private func options(_ keys: [String]) -> [EngineOption] {
        let all = EngineOptions.groups.flatMap(\.options)
        return keys.compactMap { key in all.first { $0.key == key } }
    }

    var body: some View {
        PageScaffold(title: "Controls", symbol: "gamecontroller.fill", subtitle: "Controllers, keyboard and mouse, and the touch screen") {
            SettingsGroup(title: "Controller", note: "The controller connected to this device, and how Porthole and games use it.") {
                ValueRow(id: "ct-pad", symbol: "gamecontroller.fill", title: "Connected controller",
                         value: ControllerInput.shared.kind == .none ? "None" : ControllerInput.shared.kind.displayName,
                         statusColor: ControllerInput.shared.kind == .none ? Theme.textDim : Theme.good)
                Text(ControllerInput.shared.kind == .none
                     ? "Pair a controller in the iOS Bluetooth settings. Porthole names its buttons the way they are printed on it."
                     : "Buttons are named as printed on this controller (\(ControllerInput.shared.kind.glyph("A")) select, \(ControllerInput.shared.kind.glyph("B")) back, \(ControllerInput.shared.kind.glyph("LB")) \(ControllerInput.shared.kind.glyph("RB")) switch section). Hold \(ControllerInput.shared.kind.menuChordName) in a game to open Porthole's menu.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                ForEach(options(Self.controllerKeys)) { EngineOptionRow(option: $0, values: $values) }
                ActionRow(id: "ct-rumble-test", symbol: "waveform", title: "Test controller rumble", subtitle: rumbleMessage ?? "Buzzes the left, then the right motor of the first controller", chevron: false) {
                    rumbleMessage = "Testing\u{2026}"
                    PadRumble.shared.test { rumbleMessage = $0 }
                }
            }
            if advanced {
                SettingsGroup(title: "Controller fixes", note: "How controllers are presented to games. Most people never change these.") {
                    ForEach(options(Self.controllerTechnicalKeys)) { EngineOptionRow(option: $0, values: $values) }
                }
            }
            SettingsGroup(title: "Keyboard and mouse", note: "A keyboard, mouse or trackpad in games, and the keys for Porthole's own menu.") {
                ForEach(options(Self.keyboardKeys)) { EngineOptionRow(option: $0, values: $values) }
                KeybindRow(id: "kb-menu", symbol: "line.3.horizontal.circle", title: "Open Porthole's menu in a game", key: InputSettings.menuKeyKey, fallback: .defaultMenu)
                KeybindRow(id: "kb-lock", symbol: "lock.fill", title: "Lock or free the pointer", key: InputSettings.lockKeyKey, fallback: .defaultLock)
                Text("Tap a key row, then press the key you want (hold Ctrl, Alt, Shift or Cmd with it for a combination). Esc cancels. Ctrl+Alt+M and Ctrl+Alt+P always work.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            if advanced {
                SettingsGroup(title: "Keyboard and mouse fixes", note: "Switches for when a keyboard or mouse misbehaves in a game. Most people never change these.") {
                    ForEach(options(Self.keyboardTechnicalKeys)) { EngineOptionRow(option: $0, values: $values) }
                }
            }
            SettingsGroup(title: "Touch screen", note: "Looking around by dragging on the screen, and the on-screen keyboard.") {
                SliderRow(id: "ct-look", symbol: "scope", title: "Look sensitivity",
                          info: "How fast dragging on the screen turns the view in first-person games. A game can set its own on its page, and the in-game Menu has quick Faster and Slower buttons.",
                          value: Binding(get: { look }, set: { look = $0; LaunchSettings.globalLookSensitivity = $0 }), range: LaunchSettings.lookRange, step: 0.1,
                          format: { String(format: "%.1f\u{00D7}", $0) })
                ToggleRow(id: "ct-keyboard-compact", symbol: "keyboard", title: "Fewer keys on the on-screen keyboard",
                          info: "The on-screen keyboard hides the function row (F1 to F12) and remembers it. The same switch is on the keyboard itself.",
                          isOn: Binding(get: { compactKeyboard }, set: { compactKeyboard = $0; UserDefaults.standard.set($0, forKey: TouchKeyboardView.compactKey) }))
                Text("Layouts, button size, haptics and the Presets for the on-screen controls are set for each game: open the game's page, then Controls and key binds. The in-game Menu has the touch pointer and trackpad speed.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
        }
        .onAppear { values = loadEngineValues() }
    }
}
