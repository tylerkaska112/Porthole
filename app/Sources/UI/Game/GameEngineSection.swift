// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A game's page, "Engine" section: what this one game asks of the engine, on top of the app-wide settings. Every row starts on Default, which changes nothing.
struct GameEngineSection: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @State private var showBinds = false
    @State private var showRemap = false
    @State private var showConfig = false
    @State private var showApplySetup = false
    @State private var shareItems: [Any]?
    @State private var workText = ""
    @State private var loaded = false

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        if let g = game {
            let e = g.engine ?? GameEngine()
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(title: "Compatibility") {
                    OverrideRow(id: "ge-avx", symbol: "cpu", title: "AVX and AVX2", info: "Lets the translator run programs built for AVX processors through its 128-bit emulation. A game that closes the moment it starts, or after a message about unsupported instructions, may need it. Only 64-bit games. Costs some speed.",
                                value: e.avx, globalText: "Off", options: [(true, "On"), (false, "Off")]) { v in change(g) { $0.avx = v } }
                    OverrideRow(id: "ge-fg", symbol: "wand.and.rays", title: "Frame generation (experimental)", info: "Shows a MetalFX-generated picture between every two frames the game draws, so the screen can show twice the game\u{2019}s frame rate. It needs a screen that can run at least twice as fast as the game: on a 120 Hz screen a game at 60 FPS or less (the screen is held at its top rate while it is on). A game faster than that, or a moment when the screen\u{2019}s picture queue is full, is shown as it is. It adds about half a game frame of delay and can smear edges and the on-screen controls. Frame limits do not apply while it is on. Needs iOS 26.",
                                value: e.frameGeneration, globalText: "Off", options: [(true, "On"), (false, "Off")]) { v in change(g) { $0.frameGeneration = v } }
                    OverrideRow(id: "ge-cpu", symbol: "memorychip", title: "CPU cores reported", info: "How many processor cores this game is told about. Some games size their worker threads from it.",
                                value: e.cpuCount, globalText: EngineOptions.value("cpu-count").isEmpty ? "the device" : EngineOptions.value("cpu-count"),
                                options: [(1, "1"), (2, "2"), (4, "4"), (6, "6")]) { v in change(g) { $0.cpuCount = v } }
                    OverrideRow(id: "ge-aniso", symbol: "square.3.layers.3d.down.right", title: "Direct3D 9 anisotropic filtering", info: "Limits (or raises) texture filtering quality for Direct3D 9 games. The game's own setting is used by default.",
                                value: e.anisotropy, globalText: "the game's own", options: [(1, "1\u{00D7}"), (2, "2\u{00D7}"), (4, "4\u{00D7}"), (8, "8\u{00D7}")]) { v in change(g) { $0.anisotropy = v } }
                    OverrideRow(id: "ge-x87", symbol: "function", title: "Reduced-precision x87", info: "Makes old floating-point instructions faster and less exact. The engine turns it on by itself for 32-bit games; Off asks for full precision, which some games need (Assassin's Creed's character cannot be moved with the left stick otherwise). Leave it alone for games that run well.",
                                value: e.reducedX87, globalText: "the engine's own (on for 32-bit games)", options: [(true, "On"), (false, "Off")]) { v in change(g) { $0.reducedX87 = v } }
                    OverrideRow(id: "ge-gpu", symbol: "display", title: "Graphics card the game sees", info: "Which graphics card this game is told it has, everywhere it can ask: Direct3D 9, 10, 11 and 12, Windows' own adapter list and NVIDIA's NVAPI. For a game that refuses to start or picks poor settings because it does not know the card, or that needs an NVIDIA one. This changes only what the game reads; the device draws the same.",
                                value: e.gpuCard, globalText: "the engine's own", options: GPUCards.all.map { ($0.id, $0.title) }) { v in change(g) { $0.gpuCard = v } }
                    OverrideRow(id: "ge-oversize", symbol: "arrow.up.left.and.arrow.down.right", title: "Large memory reservations", info: "Turn this on when a game quits at start because it reserves far more address space than iOS gives the app (64 GB or more, as Final Fantasy Tactics - The Ivalice Chronicles does). Porthole then really backs 16 GB of it and tells the game it got everything. Off (the default) leaves such a reservation to fail, as before.",
                                value: e.largeReservations, globalText: "Off", options: [(true, "On"), (false, "Off")]) { v in change(g) { $0.largeReservations = v } }
                }
                SettingsGroup(title: "Keyboard and mouse") {
                    OverrideRow(id: "ge-mouse-speed", symbol: "computermouse", title: "Mouse speed", info: "How fast the mouse turns this game's camera. 1\u{00D7} sends the mouse's own movement unchanged. Applies at once.",
                                value: e.mouseSpeed, globalText: EngineOptions.value(InputSettings.sensKey).isEmpty ? "1\u{00D7}" : EngineOptions.value(InputSettings.sensKey) + "\u{00D7}",
                                options: [(0.25, "0.25\u{00D7}"), (0.5, "0.5\u{00D7}"), (0.75, "0.75\u{00D7}"), (1.5, "1.5\u{00D7}"), (2.0, "2\u{00D7}"), (3.0, "3\u{00D7}"), (4.0, "4\u{00D7}"), (6.0, "6\u{00D7}")]) { v in change(g) { $0.mouseSpeed = v } }
                    OverrideRow(id: "ge-mouse-look", symbol: "viewfinder", title: "Always use the mouse to look", info: "For a game that turns the camera with the mouse but never says it hides its cursor: the mouse always moves the camera and the pointer is locked to the game (Ctrl+Alt+P frees it). Off lets the game's cursor decide.",
                                value: e.mouseLook, globalText: EngineOptions.value(InputSettings.relativeKey) == "1" ? "On" : "the game decides", options: [(true, "On"), (false, "Off")]) { v in change(g) { $0.mouseLook = v } }
                }
                if PadInput.keyboardMouseAvailable {
                    SettingsGroup(title: "Controller") {
                        ToggleRow(id: "ge-padkeys", symbol: "keyboard", title: "Controller as keyboard and mouse",
                                  subtitle: g.activeBindSet?.pad != nil ? "A bind set with controller binds is in use and decides" : nil,
                                  info: "Forces this game to use the controller as a keyboard and mouse (left stick W A S D, right stick the mouse, buttons as keys), for games with no controller support. Off goes back to Automatic. Change what each button does under Controller buttons.",
                                  isOn: Binding(get: { e.controllerMode == "keys" }, set: { on in change(g) { $0.controllerMode = on ? "keys" : nil; $0.padAuto = nil } }))
                        OverrideRow(id: "ge-pad", symbol: "gamecontroller.fill", title: "Controller", info: "Automatic (the default): the controller appears to the game as an Xbox pad, and if the game does not read it at all within about 25 seconds it becomes keyboard and mouse instead (and goes back to an Xbox pad the moment the game starts reading it). Xbox controller: always an Xbox pad. DualSense (HID) and Xbox: the pad is also shown as a DualSense on the HID path, for games that look for a HID gamepad and ignore XInput (Hollow Knight: Silksong); rumble does not work in this mode. Keyboard and mouse: always keys and mouse, for games with no controller support. Also DirectInput joystick: the same Xbox pad plus an old-style joystick for games that only look for one.",
                                    value: e.controllerMode, globalText: "Automatic", options: [("xbox", "Xbox controller"), ("hid", "DualSense (HID) and Xbox"), ("keys", "Keyboard and mouse"), ("dinput", "Xbox and DirectInput joystick")]) { v in change(g) { $0.controllerMode = v; $0.padAuto = nil } }
                        ActionRow(id: "ge-binds", symbol: "gamecontroller", title: "Controller buttons", subtitle: (e.binds?.isEmpty ?? true) ? "Standard layout" : "\(e.binds?.count ?? 0) changed") { showBinds = true }
                        if e.controllerMode != "keys" {
                            ActionRow(id: "ge-remap", symbol: "arrow.left.arrow.right", title: "Remap buttons",
                                      subtitle: PadRemap(map: e.padRemap ?? [:]).isEmpty ? "Standard buttons" : "\((e.padRemap ?? [:]).filter { $0.key != $0.value }.count) changed",
                                      info: "Changes which controller button the game sees for each button on your pad, for this game only: swap A and B, put a bumper on a trigger, turn a button off. It applies while the controller is an Xbox or DualSense pad for the game.") { showRemap = true }
                        }
                        if e.controllerMode == "keys" {
                            SliderRow(id: "ge-vert", symbol: "arrow.up.and.down", title: "Right stick up and down speed", info: "How fast the mouse moves up and down compared with left and right. Many games turn the view at different speeds in each direction.",
                                      value: Binding(get: { e.padMouseVertical ?? 1 }, set: { v in change(g) { $0.padMouseVertical = abs(v - 1) < 0.05 ? nil : v } }), range: 0.25...2.0, step: 0.05, format: { String(format: "%.2f\u{00D7}", $0) })
                        }
                    }
                }
                PadAssistGroup(settings: Binding(get: { e.padAssist }, set: { v in change(g) { $0.padAssist = v } }))
                SettingsGroup(title: "Starting") {
                    TextFieldRow(id: "ge-workdir", symbol: "folder.fill", title: "Working folder", placeholder: "the program's own",
                                 info: "The folder the program starts in, as a Windows path such as C:\\Games\\Foo. Leave empty to start in the program's own folder. A batch file (.bat or .cmd) as the program runs through cmd.exe.", monospaced: true,
                                 text: Binding(get: { workText }, set: { workText = $0; let t = $0.trimmingCharacters(in: .whitespaces); change(g) { $0.workDir = t.isEmpty ? nil : t } }))
                    ActionRow(id: "ge-config", symbol: "text.alignleft", title: "This game's engine lines",
                              subtitle: configSummary(e.config), info: "Lines in madeira.cfg's syntax that apply to this game only, for example env.MADEIRA_FEX_AVX = 1. A key here wins over the app-wide madeira.cfg while this game runs.") { showConfig = true }
                }
                SettingsGroup(title: "Share this game's setup") {
                    ActionRow(id: "ge-share", symbol: "square.and.arrow.up", title: "Share this game's setup", subtitle: "A file for a chat or the Files app",
                              info: "Puts this game's launch options, per-game settings, engine choices and saved controls into one file you can send. It holds nothing of yours: no program path, account or play history.") {
                        if let file = GameSetupShare.file(GameSetupShare.make(from: g)) { shareItems = [file] }
                    }
                    ActionRow(id: "ge-share-text", symbol: "doc.on.doc", title: "Copy this setup as text", subtitle: "One line to paste into a message", chevron: false) {
                        if let text = GameSetupShare.text(GameSetupShare.make(from: g)) { UIPasteboard.general.string = text }
                    }
                    ActionRow(id: "ge-apply-setup", symbol: "square.and.arrow.down", title: "Apply a shared setup", subtitle: "From a file or the clipboard") { showApplySetup = true }
                }
                SettingsGroup(title: "Home Screen shortcut") {
                    ActionRow(id: "ge-link", symbol: "link", title: "Copy this game's shortcut link", subtitle: "porthole://play\u{2026}",
                              info: "Starts this game from outside the app. Copy the link, then in the Shortcuts app make a shortcut with an Open URL action that uses it, and choose Add to Home Screen.", chevron: false) {
                        UIPasteboard.general.string = ShortcutRouter.link(for: g.exe)
                    }
                }
                if !e.isEmpty {
                    ActionRow(id: "ge-reset", symbol: "arrow.counterclockwise", title: "Reset this game's engine settings", chevron: false) { model.update(g) { $0.engine = nil }; workText = "" }
                }
            }
            .onAppear { if !loaded { workText = e.workDir ?? ""; loaded = true } }
            .sheet(isPresented: $showBinds) { PadBindsSheet(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
            .sheet(isPresented: $showRemap) { PadRemapSheet(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
            .sheet(isPresented: $showConfig) { GameConfigSheet(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
            .sheet(isPresented: $showApplySetup) { SharedSetupSheet(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
            .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ActivityView(items: shareItems ?? []) }
        }
    }

    private func configSummary(_ text: String?) -> String {
        let n = MadeiraConfig.parse(text ?? "").count
        return n == 0 ? "None" : "\(n) line\(n == 1 ? "" : "s")"
    }

    private func change(_ g: Game, _ edit: (inout GameEngine) -> Void) {
        model.update(g) { var e = $0.engine ?? GameEngine(); edit(&e); $0.engine = e.isEmpty ? nil : e }
    }
}

// MARK: - Controller buttons

/// The controller buttons of keyboard-and-mouse mode and what each does for this game.
struct PadBindsSheet: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @StateObject private var listener = PadPressListener()
    @State private var picked: String?
    @State private var heardNote: String?

    private var game: Game? { model.games.first { $0.id == gameID } }
    /// The buttons are named the way they are printed on the connected controller (A (✕) on a PlayStation pad).
    private var padKind: ControllerKind { ControllerInput.shared.kind }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Controller buttons").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "pb-close", title: "Done", symbol: "checkmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    if let g = game {
                        let custom = g.engine?.binds ?? [:]
                        VStack(alignment: .leading, spacing: 18) {
                            Text("What each controller input does in this game. Anything you leave on its standard choice uses the usual keyboard-and-mouse layout.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                            SettingsGroup(title: "Change one by pressing it") {
                                if listener.listening {
                                    ActionRow(id: "pb-listen", symbol: "gamecontroller.fill", title: "Press the button, or push the stick, now\u{2026}", subtitle: "Tap here to cancel", chevron: false) { listener.stop() }
                                } else {
                                    ActionRow(id: "pb-press", symbol: "hand.point.up.left.fill", title: "Press a controller button to change it",
                                              subtitle: heardNote ?? "Then pick what it does", chevron: false) { listen() }
                                }
                                if let name = picked { pickerRow(g, name, custom: custom) }
                            }
                            SettingsGroup(title: "Sticks") {
                                stickRow(g, "LS", title: "Left stick", symbol: "l.joystick.fill", custom: custom, standard: "wasd")
                                stickRow(g, "RS", title: "Right stick", symbol: "r.joystick.fill", custom: custom, standard: "mouse")
                            }
                            SettingsGroup(title: "Buttons") {
                                ForEach(PadActions.buttons, id: \.self) { name in buttonRow(g, name, custom: custom) }
                            }
                            if !custom.isEmpty {
                                ActionRow(id: "pb-reset", symbol: "arrow.counterclockwise", title: "Back to the standard layout", chevron: false) { clear(g) }
                            }
                        }
                        .frame(maxWidth: 680).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "pb-close"; scope.focused = "pb-close" }
        .onDisappear { listener.stop() }
        .presentationBackground(Theme.background)
    }

    private func buttonRow(_ g: Game, _ name: String, custom: [String: String]) -> some View {
        let standard = PadActions.template[name] ?? "none"
        return ChoiceRow(id: "pb-\(name)", symbol: "circle.circle", title: padKind.label(name),
                         options: PadActions.list.map { ($0.id, $0.label + ($0.id == standard ? " (standard)" : "")) },
                         selection: Binding(get: { custom[name] ?? standard }, set: { v in set(g, name, v == standard ? nil : v) }))
    }

    /// The row for the button the person just pressed (a stick has its own choices).
    @ViewBuilder private func pickerRow(_ g: Game, _ name: String, custom: [String: String]) -> some View {
        if name == "LS" { stickRow(g, "LS", title: "Left stick does", symbol: "l.joystick.fill", custom: custom, standard: "wasd", id: "pb-picked") }
        else if name == "RS" { stickRow(g, "RS", title: "Right stick does", symbol: "r.joystick.fill", custom: custom, standard: "mouse", id: "pb-picked") }
        else {
            let standard = PadActions.template[name] ?? "none"
            ChoiceRow(id: "pb-picked", symbol: "circle.circle", title: "\(padKind.label(name)) does",
                      options: PadActions.list.map { ($0.id, $0.label + ($0.id == standard ? " (standard)" : "")) },
                      selection: Binding(get: { custom[name] ?? standard }, set: { v in set(g, name, v == standard ? nil : v) }))
        }
    }

    private func listen() {
        heardNote = nil
        listener.start { name in
            switch name {
            case "": heardNote = "No controller is connected."
            case "-": heardNote = "Nothing was pressed."
            default:
                picked = name
                heardNote = "You pressed \(name). Pick what it does below."
                scope.focus("pb-picked")
            }
        }
    }

    private func stickRow(_ g: Game, _ name: String, title: String, symbol: String, custom: [String: String], standard: String, id: String? = nil) -> some View {
        ChoiceRow(id: id ?? "pb-\(name)", symbol: symbol, title: title,
                  options: PadActions.stickModes.map { ($0.id, $0.label + ($0.id == standard ? " (standard)" : "")) },
                  selection: Binding(get: { custom[name] ?? standard }, set: { v in set(g, name, v == standard ? nil : v) }))
    }

    private func set(_ g: Game, _ name: String, _ id: String?) {
        model.update(g) {
            var e = $0.engine ?? GameEngine()
            var b = e.binds ?? [:]
            if let id { b[name] = id } else { b.removeValue(forKey: name) }
            e.binds = b.isEmpty ? nil : b
            $0.engine = e.isEmpty ? nil : e
        }
    }
    private func clear(_ g: Game) { model.update(g) { var e = $0.engine ?? GameEngine(); e.binds = nil; $0.engine = e.isEmpty ? nil : e } }
}

// MARK: - The game's own engine lines

struct GameConfigSheet: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var text = ""
    @State private var loaded = false

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Engine lines").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "gc-close", title: "Done", symbol: "checkmark") { save(); dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Lines in madeira.cfg's syntax, one per line, that apply only while \(game?.name ?? "this game") runs. A key set here wins over the app-wide madeira.cfg. Examples: env.MADEIRA_FEX_AVX = 1, swap-mb = 2048. Lines starting with # are notes.")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        TextEditor(text: $text)
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text)
                            .scrollContentBackground(.hidden).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .frame(minHeight: 220).padding(10)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                        let n = MadeiraConfig.parse(text).count
                        Text(n == 0 ? "No lines yet." : "\(n) line\(n == 1 ? "" : "s") will be used.").font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 24).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear {
            if !loaded { text = game?.engine?.config ?? ""; loaded = true }
            scope.onBack = { save(); dismiss() }; scope.defaultFocus = "gc-close"; scope.focused = "gc-close"
        }
        .presentationBackground(Theme.background)
    }

    private func save() {
        guard let g = game else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        model.update(g) { var e = $0.engine ?? GameEngine(); e.config = t.isEmpty ? nil : t; $0.engine = e.isEmpty ? nil : e }
    }
}
