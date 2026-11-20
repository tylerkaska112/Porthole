// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The "Make it yours" part of the first-run setup: how the person wants to play, how the app looks and sounds, picture and power, and what Porthole may do for them. Every page is the
// same rows Settings uses (a choice made here IS the setting; there is nothing to apply and Settings shows it), with the defaults already chosen so a person can tap Continue on all of
// them. They take no setup state of their own, so the UI preview app draws them too.

/// Step "Controls": the default controls (the cards, Try it, Edit), then the two touch choices that change how those layouts are drawn, then what a controller does.
struct SetupControlsChoices: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DefaultControlsPicker()
            SettingsGroup(title: "Touch buttons", note: "How the on-screen buttons are drawn on this device. Try it above shows the result.") {
                ButtonSizeChoiceRow()
                LeftHandedRow()
            }
            SettingsGroup(title: "Controller") {
                ValueRow(id: "su-pad-state", symbol: ControllerInput.shared.kind == .none ? "gamecontroller" : "gamecontroller.fill",
                         title: ControllerInput.shared.kind == .none ? "No controller connected" : "\(ControllerInput.shared.kind.displayName) connected",
                         value: ControllerInput.shared.kind == .none ? "Optional" : "Ready", statusColor: ControllerInput.shared.kind == .none ? nil : Theme.good)
            }
            Text("A controller from iOS Settings \u{203A} Bluetooth works in every game by itself, and the on-screen controls hide while it is in use.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        }
    }
}

/// Step "Colours and sound": the colour scheme (live: the app changes behind the page), the holiday looks, the game volume and whether other apps keep playing.
struct SetupLookChoices: View {
    @State private var theme = ThemeStore.shared
    @AppStorage(SessionController.mixAudioKey) private var mixAudio = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Colour scheme", note: "The colours of the whole app. You can make your own later in Settings.") {
                PalettePicker(includeCustom: false)
            }
            SettingsGroup(title: "Festive") {
                ToggleRow(id: "su-festive", symbol: "moon.stars.fill", title: "Festive themes", subtitle: "Holiday looks that appear by themselves around the day",
                          info: "Porthole dresses up for some holidays by the date. Turn this off to keep your own colours all year.",
                          isOn: Binding(get: { theme.festive }, set: { theme.festive = $0 }))
            }
            SettingsGroup(title: "Sound", note: "Applies the next time a game starts.") {
                EngineChoiceRow(id: "su-volume", key: "env.MADEIRA_AUDIO_GAIN", symbol: "speaker.wave.3.fill", title: "Game volume")
                ToggleRow(id: "su-mix", symbol: "music.note.list", title: "Keep other apps' sound playing", subtitle: "Music or a video in another app plays together with the game",
                          info: "Normally Porthole takes over the sound and other apps go quiet. With this on, a song, a podcast or a video playing in another app keeps playing next to the game's own sound.",
                          isOn: $mixAudio)
            }
        }
    }
}

/// Step "Picture and power": the resolution games start with, turning to landscape, and how fast they run against battery and heat.
struct SetupPowerChoices: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Picture", note: "What every game starts with. A game's own page can change it for that game.") {
                ResolutionChoiceRow()
                AutoLandscapeRow()
            }
            SettingsGroup(title: "Power", note: "How fast games run and what happens when the device gets hot. Balanced is a good start; a game's own page can change it.") {
                PowerModeChoiceRow()
            }
        }
    }
}

/// Step "Helpers": what Porthole may do for the person after a game: fix known problems, ask how it ran, show what others reported, and keep the saves safe.
struct SetupHelperChoices: View {
    @AppStorage(AutoFixStore.enabledKey) private var autofix = true
    @AppStorage(AutoFixStore.askKey) private var autofixAsk = true
    @AppStorage(CompatStore.showBadgesKey) private var showBadges = true
    @AppStorage(CompatStore.askKey) private var ask = true
    @State private var backup = AutoBackup.enabled()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "When a game stops", note: "Porthole reads the game's own log on this device. By default it only suggests a change and waits for your yes.") {
                ToggleRow(id: "su-help-fix", symbol: "wand.and.stars", title: "Look for known problems",
                          info: "Examples: a game that needs AVX could get AVX turned on; a game that ran out of memory could get a swap file. Porthole shows what it found on the Home screen. A game gets each fix at most once.",
                          isOn: $autofix)
                if autofix {
                    ToggleRow(id: "su-help-ask", symbol: "questionmark.bubble.fill", title: "Ask me before changing a game",
                              info: "On (the default): a fix is only suggested, with Apply on the Home screen. Off: the fix is made at once and the Home screen shows it with an Undo button.",
                              isOn: $autofixAsk)
                }
                ToggleRow(id: "su-help-backup", symbol: "clock.arrow.circlepath", title: "Back up saves after each game",
                          info: "When a game ends, your saves and settings are zipped into Files > Porthole > Saves backups. The newest five are kept.",
                          isOn: Binding(get: { backup }, set: { backup = $0; AutoBackup.setEnabled($0) }))
            }
            SettingsGroup(title: "Compatibility reports", note: "Reports carry a random key kept on this device, never your name. Nothing is sent unless you choose to send it.") {
                ToggleRow(id: "su-help-badges", symbol: "checkmark.seal.fill", title: "Show compatibility badges",
                          info: "Small marks on games that show how they ran for other people.", isOn: $showBadges)
                ToggleRow(id: "su-help-ask-ran", symbol: "questionmark.bubble.fill", title: "Ask me how a game ran",
                          info: "After a game you can send a short report. It takes under a minute.", isOn: $ask)
            }
        }
    }
}

/// One line for each choice page, read from the settings themselves, for the last page of the setup.
@MainActor enum SetupSummary {
    static func controls() -> String {
        var parts = [DefaultControls.current.kind.title]
        let size = UserDefaults.standard.string(forKey: TouchButtonSize.key) ?? ""
        if !size.isEmpty { parts.append("buttons \(TouchButtonSize.title(setting: size).lowercased())") }
        if TouchHandedness.leftHanded { parts.append("left-handed") }
        return parts.joined(separator: ", ")
    }

    static func look() -> String {
        let theme = ThemeStore.shared
        let name = Palette.presets.first { $0.id == theme.presetID }?.name ?? "Your own colour"
        return theme.festive ? "\(name), festive themes on" : name
    }

    static func power() -> String {
        "\(DisplayResolution.title(id: LaunchSettings.globalResolution, screenAspect: LaunchSettings.screenAspect)), \(PowerManager.shared.userMode.title.lowercased())"
    }

    static func helpers() -> String {
        let d = UserDefaults.standard
        let on = [AutoFixStore.enabled, AutoBackup.enabled(), d.object(forKey: CompatStore.showBadgesKey) as? Bool ?? true, d.object(forKey: CompatStore.askKey) as? Bool ?? true].filter { $0 }.count
        return "\(on) of 4 on"
    }
}
