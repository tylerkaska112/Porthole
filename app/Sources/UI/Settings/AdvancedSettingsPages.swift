// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Settings > Advanced: a short page that opens the rest. Engine options (one page per group), Windows components, links and remote control, and diagnostics each have a page of their own.

struct AdvancedPage: View {
    @Environment(AppRouter.self) private var router
    @AppStorage("f4.advanced") private var advanced = false
    @AppStorage(ExecutableWindow.defaultsKey) private var releaseExeWindow = true
    @State private var vc = VCRuntimeInstaller.shared

    var body: some View {
        switch router.settingsSub {
        case .engineGroups?: EngineGroupsPage()
        case .engineGroup(let title)?: EngineGroupPage(title: title)
        case .engineChanged?: EngineChangedPage()
        case .components?: ComponentsPage()
        case .links?: LinksPage()
        case .diagnostics?: DiagnosticsPage()
        default: hub
        }
    }

    private var changedCount: Int { EngineOptions.groups.flatMap(\.options).filter { !EngineOptions.value($0.key).isEmpty }.count }
    private var optionCount: Int { EngineOptions.groups.reduce(0) { $0 + $1.options.count } }

    private var hub: some View {
        PageScaffold(title: "Advanced", symbol: "wrench.and.screwdriver.fill", subtitle: "Engine switches and diagnostics") {
            Text("Most people never need this page. Everything here starts on its default, which is what Porthole was tested with.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            SettingsGroup(title: "Options") {
                ToggleRow(id: "ad-tech", symbol: "slider.horizontal.3", title: "Show technical options",
                          info: "Shows swap and video memory, shader math, tunnel and JIT status, and technical readouts. Most people never need them.", isOn: $advanced)
                ToggleRow(id: "ad-pool", symbol: "memorychip", title: "Bigger code pool when the game allows it",
                          info: "The emulator keeps a stretch of memory free for the rare game that can only load at one fixed address. When none of a game's programs needs it, this gives it back so the code pool can be larger (fewer freezes in big games). Turn it off to go back to the previous behaviour if a game that started before no longer does.",
                          isOn: $releaseExeWindow)
            }
            SettingsGroup(title: "Engine", note: "The switches of the game engine that have no screen of their own.") {
                ActionRow(id: SettingsSub.engineGroups.rowID, symbol: "slider.horizontal.2.square", title: "Engine options",
                          subtitle: "\(optionCount) options in \(EngineOptions.groups.count) groups",
                          detail: changedCount == 0 ? nil : "\(changedCount) changed") { router.settingsSub = .engineGroups }
            }
            SettingsGroup(title: "Windows") {
                ActionRow(id: SettingsSub.components.rowID, symbol: "shippingbox.fill", title: "Windows components",
                          subtitle: "Visual C++ runtime: \(vc.available ? "ready" : "not installed") \u{00B7} .NET: \(WineMonoModel.available ? "ready" : "not installed") \u{00B7} Web pages: \(WineGeckoModel.available ? "ready" : "not installed")") { router.settingsSub = .components }
            }
            SettingsGroup(title: "Safety and testing") {
                ActionRow(id: SettingsSub.links.rowID, symbol: "link", title: "Links and remote control",
                          subtitle: "What a porthole:// link may do") { router.settingsSub = .links }
                ActionRow(id: SettingsSub.diagnostics.rowID, symbol: "stethoscope", title: "Diagnostics",
                          subtitle: "The log, window pictures and Wine debug channels") { router.settingsSub = .diagnostics }
            }
        }
    }
}

// MARK: - Windows components

struct ComponentsPage: View {
    @State private var installer = VCRuntimeInstaller.shared
    @ObservedObject private var mono = WineMonoModel.shared
    @ObservedObject private var gecko = WineGeckoModel.shared
    @ObservedObject private var vc32 = VCRedistModel.shared

    var body: some View {
        SubPage(sub: .components, symbol: "shippingbox.fill") {
            SettingsGroup(title: "Runtimes", note: "Programs many games need and Windows would normally have. Each is a one-time download, checked against a fixed fingerprint before it is used.") {
                ActionRow(id: "ad-vc", symbol: installer.available ? "checkmark.seal.fill" : "shippingbox.fill", tint: installer.available ? Theme.good : Theme.warn,
                          title: "Visual C++ runtime", subtitle: vcSubtitle, detail: !installer.available && !installer.busy ? "Download" : nil,
                          info: "Microsoft's runtime that many games need. About 25 MB, downloaded from Microsoft's own installer and checked against a fixed fingerprint before anything is used. Without it some games won't start.", chevron: false) {
                    if !installer.available && !installer.busy { Task { await installer.install() } }
                }
                if case .downloading(let fraction) = installer.state { ProgressView(value: fraction).tint(Theme.accent).padding(.horizontal, 8) }
                if installer.installed {
                    ActionRow(id: "ad-vc-remove", symbol: "trash", title: "Remove the downloaded copy", destructive: true, chevron: false) { installer.remove() }
                }
                ActionRow(id: "ad-mono", symbol: WineMonoModel.available ? "checkmark.seal.fill" : "shippingbox.fill", tint: WineMonoModel.available ? Theme.good : Theme.warn,
                          title: ".NET Framework (Wine Mono)", subtitle: mono.error ?? mono.status, detail: !WineMonoModel.available && !mono.busy ? "Download" : nil,
                          info: "Games built on Microsoft's .NET Framework (Celeste, many indie games and launchers) run on Wine Mono, the Wine project's open-source .NET runtime. About 42 MB from WineHQ, about 130 MB once installed, checked against a fixed fingerprint before use. Without it those games end as soon as they start.") {
                    if !WineMonoModel.available && !mono.busy { mono.install() }
                }
                if mono.busy { ProgressView(value: mono.progressFraction).tint(Theme.accent).padding(.horizontal, 8) }
                if mono.installed && !mono.busy {
                    ActionRow(id: "ad-mono-remove", symbol: "trash", title: "Remove Wine Mono", destructive: true, chevron: false) { mono.remove() }
                }
                ActionRow(id: "ad-vc32", symbol: vc32.complete ? "checkmark.seal.fill" : "shippingbox.fill", tint: vc32.complete ? Theme.good : Theme.warn,
                          title: "32-bit Visual C++ runtime", subtitle: vc32.error ?? vc32.status, detail: !vc32.complete && !vc32.busy ? "Download" : nil,
                          info: "Microsoft's C++ runtime for 32-bit programs (older games, many launchers). Without it they run on Wine's own C++ runtime. About 14 MB from Microsoft's installer, checked against a pinned fingerprint and unpacked here; every file is checked again. Not allowed while a game is running.", chevron: false) {
                    if !vc32.complete && !vc32.busy { vc32.install() }
                }
                if vc32.busy { ProgressView(value: { if case .downloading(let f) = vc32.phase { return f } else if case .installing(let f) = vc32.phase { return f } else { return 0 } }()).tint(Theme.accent).padding(.horizontal, 8) }
                if vc32.complete && !vc32.busy {
                    ActionRow(id: "ad-vc32-remove", symbol: "trash", title: "Remove the 32-bit runtime", destructive: true, chevron: false) { vc32.remove() }
                }
                ActionRow(id: "ad-gecko", symbol: gecko.installed ? "checkmark.seal.fill" : "globe", tint: gecko.installed ? Theme.good : Theme.warn,
                          title: "Web pages in programs (Wine Gecko)", subtitle: gecko.error ?? gecko.status, detail: !gecko.installed && !gecko.busy ? "Download" : nil,
                          info: "Installers and launchers that show a web page use Wine Gecko, the Wine project's open-source web engine. About 110 MB from WineHQ (a 32-bit and a 64-bit file), checked against fixed fingerprints before use. Without it Wine stops on its own \u{201C}Wine Gecko Installer\u{201D} window, whose download can hang. Programs that already installed it keep it.", chevron: false) {
                    if !gecko.installed && !gecko.busy { gecko.install() }
                }
                if let progress = gecko.progress { ProgressView(value: progress).tint(Theme.accent).padding(.horizontal, 8) }
                if gecko.installed && !gecko.busy {
                    ActionRow(id: "ad-gecko-remove", symbol: "trash", title: "Remove Wine Gecko", destructive: true, chevron: false) { gecko.remove() }
                }
            }
        }
    }

    private var vcSubtitle: String {
        switch installer.state {
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .unpacking: return "Checking and unpacking\u{2026}"
        case .failed(let message): return message
        case .idle: return installer.installed ? "Installed" : (installer.available ? "Included with this app" : "Not installed")
        }
    }
}

// MARK: - Links and remote control

struct LinksPage: View {
    @AppStorage(ShortcutRouter.remoteKey) private var remoteLinks = false
    @AppStorage(ShortcutRouter.confirmKey) private var confirmLinks = true

    var body: some View {
        SubPage(sub: .links, symbol: "link") {
            SettingsGroup(title: "Links", note: "A porthole:// link can start a game from a Home Screen shortcut, a web page or another app.") {
                ToggleRow(id: "ad-confirm-link", symbol: "link.badge.plus", title: "Ask before a link starts a game",
                          info: "A porthole://play link (a Home Screen shortcut, a web page, another app) starts a game that is in your library. With this on, Porthole asks first, so a link you did not expect cannot start one. Links from a computer you have paired are not asked.",
                          isOn: $confirmLinks)
            }
            SettingsGroup(title: "Remote control", note: "For testing from a computer. Leave this off normally.") {
                ToggleRow(id: "ad-remote", symbol: "antenna.radiowaves.left.and.right", title: "Allow remote-control links",
                          info: "Lets porthole:// links stop an ended game, change one setting line of a game, or install the newest update. For testing from a computer (tools/ipad.sh). Leave off normally: any app or web page that can open a link could use them.",
                          isOn: $remoteLinks)
            }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsPage: View {
    @AppStorage("f4.dumpSurfaces") private var dumpSurfaces = false
    @AppStorage("f4.wineDebug") private var wineDebug = ""

    var body: some View {
        SubPage(sub: .diagnostics, symbol: "stethoscope") {
            LogPage()
            SettingsGroup(title: "Debugging", note: "For finding out why something looks or behaves wrong. Leave these off normally.") {
                ToggleRow(id: "ad-pics", symbol: "photo.on.rectangle", title: "Save window pictures",
                          info: "Saves a picture of every Windows window about every 2 seconds to Files > Porthole > surfdump. Use them to report a window that looks wrong. Leave off normally.", isOn: $dumpSurfaces)
                TextFieldRow(id: "ad-debug", symbol: "terminal.fill", title: "Wine debug channels", placeholder: "for example +msg",
                             info: "Advanced: records extra Wine messages in the log (for example +msg for window messages). Leave empty normally.", monospaced: true, text: $wineDebug)
            }
        }
    }
}

// MARK: - Engine options

extension EngineOptions {
    /// One line about what a group holds.
    static let summaries: [String: String] = [
        "Starting a game": "How quickly Wine starts, and the memory set aside for translated code.",
        "CPU and power": "How many cores games see, and how slow Eco mode makes them.",
        "Memory": "Swap, donor memory, and how the engine spends the device's RAM.",
        "OpenGL": "How games that draw with OpenGL are shown.",
        "Direct3D 12": "Switches for games that use Direct3D 12.",
        "Graphics, video and sound": "Direct3D 9, video in games, the screen's refresh rate and the audio buffer.",
        "Controllers": "How controllers are presented to games.",
        "Controller menus and pointer": "Using a controller in Porthole's own menus and the in-game pointer.",
        "Keyboard and mouse": "A keyboard, mouse or trackpad in games: the keys for Porthole's menu and the pointer lock, mouse speed, scroll direction.",
    ]

    static let symbols: [String: String] = [
        "Starting a game": "bolt.fill", "CPU and power": "cpu", "Memory": "memorychip.fill", "OpenGL": "cube.transparent", "Direct3D 12": "square.3.layers.3d",
        "Graphics, video and sound": "tv.fill", "Controllers": "gamecontroller.fill", "Controller menus and pointer": "cursorarrow.rays", "Keyboard and mouse": "keyboard.fill",
    ]

    static func changed(in group: EngineOptionGroup) -> Int { group.options.filter { !value($0.key).isEmpty }.count }

    /// Small labels for a row, taken from its own explanation: whether it is experimental and when a change takes effect.
    static func tags(for option: EngineOption) -> String? {
        var tags: [String] = []
        if option.info.localizedCaseInsensitiveContains("experimental") { tags.append("Experimental") }
        if option.info.localizedCaseInsensitiveContains("next start") || option.info.localizedCaseInsensitiveContains("next time") { tags.append("Applies on the next start") }
        return tags.isEmpty ? nil : tags.joined(separator: " \u{00B7} ")
    }
}

/// One engine option: its choices, the label under it, the (i).
struct EngineOptionRow: View {
    let option: EngineOption
    @Binding var values: [String: String]

    var body: some View {
        ChoiceRow(id: "eo-\(option.key)", symbol: option.symbol, title: option.title, subtitle: EngineOptions.tags(for: option), info: option.info,
                  options: EngineOptions.choices(for: option, current: values[option.key] ?? ""),
                  selection: Binding(get: { values[option.key] ?? "" },
                                     set: { values[option.key] = $0; EngineOptions.set(option.key, $0); EngineOptionsChanged.post(option.key) }))
    }
}

private func loadEngineValues() -> [String: String] {
    var v: [String: String] = [:]
    for group in EngineOptions.groups { for option in group.options { v[option.key] = EngineOptions.value(option.key) } }
    return v
}

struct EngineGroupsPage: View {
    @Environment(AppRouter.self) private var router
    @State private var values: [String: String] = [:]

    var body: some View {
        let changed = values.values.filter { !$0.isEmpty }.count
        SubPage(sub: .engineGroups, symbol: "slider.horizontal.2.square") {
            Text("Switches of the game engine. Every option starts on Default, which leaves the engine as it is. Most apply the next time a game starts. Settings that have a page of their own, such as swap, video memory and resolution, are not repeated here.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            SettingsGroup {
                ActionRow(id: SettingsSub.engineChanged.rowID, symbol: "arrow.triangle.branch", tint: changed == 0 ? Theme.textDim : Theme.warn, title: "Changed from default",
                          subtitle: changed == 0 ? "Nothing is changed" : "\(changed) option\(changed == 1 ? "" : "s") set", detail: nil) { router.settingsSub = .engineChanged }
            }
            SettingsGroup(title: "Groups") {
                ForEach(EngineOptions.groups) { group in
                    let n = group.options.filter { !(values[$0.key] ?? "").isEmpty }.count
                    ActionRow(id: SettingsSub.engineGroup(group.title).rowID, symbol: EngineOptions.symbols[group.title] ?? "slider.horizontal.3", title: group.title,
                              subtitle: EngineOptions.summaries[group.title], detail: n == 0 ? "\(group.options.count)" : "\(n) changed") { router.settingsSub = .engineGroup(group.title) }
                }
            }
        }
        .onAppear { values = loadEngineValues() }
    }
}

struct EngineGroupPage: View {
    let title: String
    @State private var values: [String: String] = [:]
    @State private var rumbleMessage: String?

    var body: some View {
        SubPage(sub: .engineGroup(title), symbol: EngineOptions.symbols[title] ?? "slider.horizontal.3") {
            if let group = EngineOptions.groups.first(where: { $0.title == title }) {
                SettingsGroup(note: EngineOptions.summaries[title]) {
                    ForEach(group.options) { EngineOptionRow(option: $0, values: $values) }
                }
                if title == "Keyboard and mouse" {
                    SettingsGroup(title: "Keys for Porthole", note: "Tap a row, then press the key you want (hold Ctrl, Alt, Shift or Cmd with it for a combination). Esc cancels. Ctrl+Alt+M and Ctrl+Alt+P always work as well, so a key you cannot press never locks you out.") {
                        KeybindRow(id: "kb-menu", symbol: "line.3.horizontal.circle", title: "Open Porthole's menu in a game", key: InputSettings.menuKeyKey, fallback: .defaultMenu)
                        KeybindRow(id: "kb-lock", symbol: "lock.fill", title: "Lock or free the pointer", key: InputSettings.lockKeyKey, fallback: .defaultLock)
                    }
                }
                if title == "Controllers" {
                    SettingsGroup(title: "Try it") {
                        ActionRow(id: "eo-rumble-test", symbol: "waveform", title: "Test controller rumble", subtitle: rumbleMessage ?? "Buzzes the left, then the right motor of the first controller", chevron: false) {
                            rumbleMessage = "Testing\u{2026}"
                            PadRumble.shared.test { rumbleMessage = $0 }
                        }
                    }
                }
            }
        }
        .onAppear { values = loadEngineValues() }
    }
}

struct EngineChangedPage: View {
    @State private var values: [String: String] = [:]
    @State private var confirmReset = false

    private var changed: [EngineOption] { EngineOptions.groups.flatMap(\.options).filter { !(values[$0.key] ?? "").isEmpty } }

    var body: some View {
        SubPage(sub: .engineChanged, symbol: "arrow.triangle.branch") {
            if changed.isEmpty {
                Text("Every engine option is on its default.").foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                SettingsGroup(note: "These options are set to something other than the default. A game that stopped working after you changed one is the first place to look.") {
                    ForEach(changed) { EngineOptionRow(option: $0, values: $values) }
                }
                SettingsGroup {
                    ActionRow(id: "eo-reset-all", symbol: "arrow.counterclockwise", title: "Put every option back to Default", destructive: true, chevron: false) { confirmReset = true }
                }
            }
        }
        .onAppear { values = loadEngineValues() }
        .confirm("Put every engine option back to Default?", message: "Only these engine options change. Your games and other settings are not touched.", confirmTitle: "Put back", destructive: true, isPresented: $confirmReset) {
            for option in changed { EngineOptions.set(option.key, ""); EngineOptionsChanged.post(option.key) }
            values = loadEngineValues()
        }
    }
}

/// Lets live pieces (the screen-rate hold, the controller bridge) react to a change without waiting for the next start.
enum EngineOptionsChanged {
    static let name = Notification.Name("porthole.engineOptionChanged")
    static func post(_ key: String) { NotificationCenter.default.post(name: name, object: key) }
}
