// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Settings > Controls: every setting about how a game is controlled, in one place. The rows are the same engine options Settings > Advanced > Engine options lists (a change in
// either place is the same setting); the everyday ones are here, the ones that only matter when something is wrong are behind "Show technical options".

struct ControlsPage: View {
    @Environment(AppRouter.self) private var router
    @State private var look = LaunchSettings.globalLookSensitivity
    @State private var values: [String: String] = [:]
    @State private var rumbleMessage: String?
    @AppStorage("f4.testPad.followMotion") private var followMotion = true
    @AppStorage(SlideAcross.key) private var slideAcross = true
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
        Group {
            switch router.settingsSub {
            case .controlsController?: SubPage(sub: .controlsController, symbol: "gamecontroller.fill") { controllerGroups }
            case .controlsKeyboard?: SubPage(sub: .controlsKeyboard, symbol: "keyboard") { keyboardGroups }
            case .controlsTouch?: SubPage(sub: .controlsTouch, symbol: "hand.tap.fill") { touchGroups }
            case .controlsTests?: SubPage(sub: .controlsTests, symbol: "checkmark.shield.fill") { testGroups }
            case .controlsTestPad?: SubPage(sub: .controlsTestPad, symbol: "gamecontroller.fill") { ControllerTestContent(onExit: { router.settingsSub = .controlsTests }) }
            case .controlsTestKeys?: SubPage(sub: .controlsTestKeys, symbol: "keyboard") { KeyboardMouseTestContent(onExit: { router.settingsSub = .controlsTests }) }
            case .controlsSticks?: SubPage(sub: .controlsSticks, symbol: "scope") { StickSettingsContent(onExit: { router.settingsSub = .controlsTests }) }
            default: main
            }
        }
        .onAppear { values = loadEngineValues() }
    }

    /// The page itself: how every game starts, then a door to each kind of input.
    private var main: some View {
        PageScaffold(title: "Controls", symbol: "gamecontroller.fill", subtitle: "How games are controlled, and the settings for each kind of input") {
            DefaultControlsPicker()
            SettingsGroup(title: "Input settings", note: "A single game's own controls are set on that game's page.") {
                ActionRow(id: SettingsSub.controlsController.rowID, symbol: "gamecontroller.fill", title: "Controller",
                          subtitle: ControllerInput.shared.kind == .none ? "None connected" : "\(ControllerInput.shared.kind.displayName) connected") { router.settingsSub = .controlsController }
                ActionRow(id: SettingsSub.controlsKeyboard.rowID, symbol: "keyboard", title: "Keyboard and mouse",
                          subtitle: "Mouse speed, scrolling and Porthole's menu key") { router.settingsSub = .controlsKeyboard }
                ActionRow(id: SettingsSub.controlsTouch.rowID, symbol: "hand.tap.fill", title: "Touch screen",
                          subtitle: "Buttons \(TouchButtonSize.title(setting: UserDefaults.standard.string(forKey: TouchButtonSize.key) ?? "").lowercased()), look sensitivity \(String(format: "%.1f\u{00D7}", look))") { router.settingsSub = .controlsTouch }
            }
            // The three tests and the stick check are one door: they are for when something is wrong, not for every visit.
            SettingsGroup {
                ActionRow(id: SettingsSub.controlsTests.rowID, symbol: "checkmark.shield.fill", title: "Test and troubleshoot",
                          subtitle: "Check a controller, its sticks, a keyboard and a mouse") { router.settingsSub = .controlsTests }
            }
        }
    }

    /// The tests: every press and movement is drawn, and a stick that drifts can be given a deadzone.
    @ViewBuilder private var testGroups: some View {
        SettingsGroup(title: "Test your devices", note: "See that a controller, keyboard or mouse works: every press and movement is drawn, and a stick that drifts can be given a deadzone.") {
            ActionRow(id: SettingsSub.controlsTestPad.rowID, symbol: "gamecontroller.fill", title: "Test controller",
                      subtitle: ControllerInput.shared.kind == .none ? "Sticks, buttons, triggers and drift (none connected)" : "Sticks, buttons, triggers and drift") { router.settingsSub = .controlsTestPad }
            ActionRow(id: SettingsSub.controlsSticks.rowID, symbol: "scope", title: "Sticks and drift",
                      subtitle: "Check a stick that drifts and set a deadzone") { router.settingsSub = .controlsSticks }
            ActionRow(id: SettingsSub.controlsTestKeys.rowID, symbol: "keyboard", title: "Test keyboard and mouse",
                      subtitle: "Keys, mouse buttons, wheel and movement") { router.settingsSub = .controlsTestKeys }
        }
    }

    @ViewBuilder private var controllerGroups: some View {
        SettingsGroup(title: "Controller", note: "The controller connected to this device, and how Porthole and games use it.") {
            ValueRow(id: "ct-pad", symbol: "gamecontroller.fill", title: "Connected controller",
                     value: ControllerInput.shared.kind == .none ? "None" : ControllerInput.shared.kind.displayName,
                     statusColor: ControllerInput.shared.kind == .none ? Theme.textDim : Theme.good)
            Text(ControllerInput.shared.kind == .none
                 ? "Pair a controller in the iOS Bluetooth settings. Porthole names its buttons the way they are printed on it."
                 : "Buttons are named as printed on this controller (\(ControllerInput.shared.kind.glyph("A")) select, \(ControllerInput.shared.kind.glyph("B")) back, \(ControllerInput.shared.kind.glyph("LB")) \(ControllerInput.shared.kind.glyph("RB")) switch section). Hold \(ControllerInput.shared.kind.menuChordName) in a game to open Porthole's menu.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            ForEach(options(Self.controllerKeys)) { EngineOptionRow(option: $0, values: $values) }
            ToggleRow(id: "ct-gyro-follow", symbol: "gyroscope", title: "3D controller follows motion",
                      info: "On the Test controller page a DualSense, DualShock 4 or Xbox controller is drawn in 3D. A DualSense or DualShock 4 has motion sensors, and the drawing turns as you turn the real controller; an Xbox controller has none, so its drawing only moves with your finger. Nothing tells the controller which way is forward, so double-tap the picture to make the way it points now the front; it may slowly wander from there. The sensors are on only while that page is open.",
                      isOn: $followMotion)
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
    }

    @ViewBuilder private var keyboardGroups: some View {
        SettingsGroup(title: "Keyboard and mouse", note: "A keyboard, mouse or trackpad in games, and the keys for Porthole's own menu.") {
            ForEach(options(Self.keyboardKeys)) { EngineOptionRow(option: $0, values: $values) }
        }
        SettingsGroup(title: "Keys for Porthole", note: "Tap a key row, then press the key you want (hold Ctrl, Alt, Shift or Cmd with it for a combination). Esc cancels. Ctrl+Alt+M and Ctrl+Alt+P always work.") {
            KeybindRow(id: "kb-menu", symbol: "line.3.horizontal.circle", title: "Open Porthole's menu in a game", key: InputSettings.menuKeyKey, fallback: .defaultMenu)
            KeybindRow(id: "kb-lock", symbol: "lock.fill", title: "Lock or free the pointer", key: InputSettings.lockKeyKey, fallback: .defaultLock)
        }
        if advanced {
            SettingsGroup(title: "Keyboard and mouse fixes", note: "Switches for when a keyboard or mouse misbehaves in a game. Most people never change these.") {
                ForEach(options(Self.keyboardTechnicalKeys)) { EngineOptionRow(option: $0, values: $values) }
            }
        }
    }

    @ViewBuilder private var touchGroups: some View {
        SettingsGroup(title: "Touch screen", note: "Looking around by dragging on the screen, and the on-screen keyboard.") {
            SliderRow(id: "ct-look", symbol: "scope", title: "Look sensitivity",
                      info: "How fast dragging on the screen turns the view in first-person games. A game can set its own on its page, and the in-game Menu has quick Faster and Slower buttons.",
                      value: Binding(get: { look }, set: { look = $0; LaunchSettings.globalLookSensitivity = $0 }), range: LaunchSettings.lookRange, step: 0.1,
                      format: { String(format: "%.1f\u{00D7}", $0) })
            ButtonSizeChoiceRow()
            LeftHandedRow()
            ToggleRow(id: "ct-keyboard-compact", symbol: "keyboard", title: "Fewer keys on the on-screen keyboard",
                      info: "The on-screen keyboard hides the function row (F1 to F12) and remembers it. The same switch is on the keyboard itself.",
                      isOn: Binding(get: { compactKeyboard }, set: { compactKeyboard = $0; UserDefaults.standard.set($0, forKey: TouchKeyboardView.compactKey) }))
            ToggleRow(id: "ct-slide", symbol: "hand.draw.fill", title: "Slide a finger across buttons",
                      info: "On: sliding a finger from one on-screen button to the next lets go of the first and presses the second, without lifting. Hold B to run, then slide your thumb to A to jump. Works on the held buttons of the touch layouts and on the on-screen keyboard. Off: a button stays pressed until the finger lifts.",
                      isOn: $slideAcross)
        }
    }
}

// MARK: - Rows shared by Settings and the first-run setup

/// Settings > Controls > Touch screen > Button size.
struct ButtonSizeChoiceRow: View {
    @State private var buttonSize = UserDefaults.standard.string(forKey: TouchButtonSize.key) ?? ""
    var body: some View {
        ChoiceRow(id: "ct-button-size", symbol: "circle.dashed", title: "Button size",
                  info: "How big the on-screen buttons of your layouts are drawn, on this device. Layouts are made for a phone, so Automatic makes them a little larger on an iPad. The on-screen game controller has its own size in the in-game menu.",
                  options: TouchButtonSize.choices.map { ($0.value, $0.title) },
                  selection: Binding(get: { buttonSize }, set: { buttonSize = $0; UserDefaults.standard.set($0, forKey: TouchButtonSize.key) }))
    }
}

/// Settings > Controls > Touch screen > Left-handed.
struct LeftHandedRow: View {
    @State private var leftHanded = TouchHandedness.leftHanded
    var body: some View {
        ToggleRow(id: "ct-left-handed", symbol: "hand.point.left.fill", title: "Left-handed",
                  info: "Shows every layout flipped left to right on this device, so the stick and the buttons swap hands. Nothing in a layout is changed: switch it off and they are back, and layouts you share are not turned round. The in-game menu has the same switch.",
                  isOn: Binding(get: { leftHanded }, set: { leftHanded = $0; TouchHandedness.set($0) }))
    }
}
