// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

enum GameMenuTab: String, CaseIterable, Identifiable {
    case performance, controls, game, steam
    var id: String { rawValue }
    var title: String { switch self { case .performance: "Performance"; case .controls: "Controls"; case .game: "Game"; case .steam: "Steam" } }
    var symbol: String { switch self { case .performance: "gauge.with.dots.needle.67percent"; case .controls: "gamecontroller"; case .game: "ellipsis.circle"; case .steam: "person.2.fill" } }
}

/// How visible the strip on the right edge is. The swipe in from that edge works with every choice.
enum MenuHandleStyle: String, CaseIterable, Identifiable {
    case fade, always, hidden
    var id: String { rawValue }
    var title: String { switch self { case .fade: "Fades out"; case .always: "Always visible"; case .hidden: "Hidden" } }
    var detail: String {
        switch self {
        case .fade: "Shows for a few seconds when a game starts, then fades."
        case .always: "A thin line stays on the right edge."
        case .hidden: "Nothing is drawn. Swipe in from the right edge."
        }
    }
    static let key = "f4.menuHandle"
    static var current: MenuHandleStyle { MenuHandleStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .fade }
}

/// What the in-game menu shows and does. The HUD owns the real state and the actions; it fills this in whenever the menu opens or something changes,
/// so the menu itself holds nothing the game depends on.
@MainActor
final class GameMenuModel: ObservableObject {
    @Published var isPresented = false
    /// The menu was opened with the controller's chord, so the focus glow is on from the start.
    var openedByPad = false
    @Published var tab: GameMenuTab = UserDefaults.standard.string(forKey: "f4.menuTab").flatMap(GameMenuTab.init(rawValue:)) ?? .performance {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "f4.menuTab") }
    }

    // Performance
    @Published var powerChosen: PowerMode = .balanced
    @Published var powerEffective: PowerMode = .balanced
    @Published var eco = false
    @Published var frameGen = false
    @Published var fenceMode = 1

    // Controls
    /// The controller shown to the game: nil = Automatic, "xbox", "hid", "keys". `padHidReady`: the DualSense exists this session; `padKindName`: the connected controller.
    @Published var padMode: String?
    @Published var padHidReady = false
    @Published var padKindName = ""
    @Published var layout: ControlLayout = .standard
    @Published var customLayoutInUse = false
    @Published var controlsShown = true
    @Published var showLookSpeed = false
    @Published var lookSpeed = 2.4

    // Game
    @Published var handleStyle = MenuHandleStyle.current
    @Published var hasReport = false
    @Published var gameName: String?
    /// The Steam app id of the running game, when it has one: the Steam tab needs it.
    @Published var steamAppID: Int?
    /// A part of the Steam tab to show when the tab opens (set when a game asked for Steam's overlay); the tab takes it and clears it.
    @Published var requestedSteamSection: String?
    /// The tabs that make sense for this game: Steam only for a Steam game when the person is signed in to Steam.
    var availableTabs: [GameMenuTab] { GameMenuTab.allCases.filter { $0 != .steam || (steamAppID != nil && SteamStore.shared.signedIn) } }

    // Actions, set by the HUD.
    var close: () -> Void = {}
    var dismiss: () -> Void = {}
    var setPower: (PowerMode) -> Void = { _ in }
    var setEco: (Bool) -> Void = { _ in }
    var setFrameGen: (Bool) -> Void = { _ in }
    var setFence: (Int) -> Void = { _ in }
    var setHandleStyle: (MenuHandleStyle) -> Void = { _ in }
    var setLayout: (ControlLayout) -> Void = { _ in }
    var setControlsShown: (Bool) -> Void = { _ in }
    var adjustLook: (Double) -> Void = { _ in }
    var setPadMode: (String?) -> Void = { _ in }
    var openKeyboard: () -> Void = {}
    var openBinds: () -> Void = {}
    var editControls: () -> Void = {}
    var report: () -> Void = {}
    var help: () -> Void = {}
    var captureFrame: () -> Void = {}
    var profile: () -> Void = {}
    var closeGame: () -> Void = {}
    var restartGame: () -> Void = {}

    static let fenceModes: [(mode: Int, name: String, detail: String)] = [
        (1, "Accurate", "Waits for the GPU the way the game expects. The safe choice."),
        (6, "Barrier-driven", "Waits only at barriers. Can be faster, can show glitches."),
        (5, "Fragment stage", "Waits at the fragment stage."),
        (0, "No fences", "Never waits. Fastest, but can break the picture or crash."),
    ]
}

/// The side panel. Slides in from the right over a dimmed game; the game keeps running behind it.
struct GameMenuView: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if model.isPresented {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { model.dismiss() }
                        .transition(.opacity)
                    GameMenuPanel(model: model, overlay: overlay)
                        .frame(width: min(370, max(310, geo.size.width * 0.4)))
                        .frame(maxHeight: .infinity)
                        // Swipe the panel back to the right to close it.
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                            if v.translation.width > 70, abs(v.translation.height) < v.translation.width * 0.6 { model.dismiss() }
                        })
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: model.isPresented)
    }
}

private struct GameMenuPanel: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings
    /// The first time the menu opens: a short explanation of its three tabs at the top (until it is dismissed).
    @State private var showTip = GuideCenter.shared.wantsTip(GuideCatalog.gameMenu.id)
    /// The controller's layer: D-pad moves the glow, A presses, B or Options closes, the shoulder buttons switch tabs.
    @State private var scope = FocusScope()

    private func dismissTip() {
        GuideCenter.shared.markSeen(GuideCatalog.gameMenu.id)
        withAnimation { showTip = false }
    }

    private func configureNav() {
        scope.onBack = { [model] in model.dismiss() }
        scope.onMenu = { [model] in model.dismiss() }
        scope.onSection = { [model] step in
            let all = model.availableTabs
            if let i = all.firstIndex(of: model.tab) { model.tab = all[(i + step + all.count) % all.count] }
        }
        if model.openedByPad { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [scope] in scope.ensureFocus() } }
    }

    /// The controller in use, for naming its buttons (Xbox names when none is known).
    private var padKind: ControllerKind { let k = ControllerInput.shared.kind; return k == .none ? .xbox : k }

    private var menuTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill").foregroundStyle(Theme.accent)
                Text("The menu has tabs").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            }
            ForEach(GuideCatalog.gameMenu.steps, id: \.title) { step in
                (Text(step.title + ": ").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text) + Text(step.text).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.85)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Swipe the menu back to the right, or tap outside it, to close it. With a controller: hold \(padKind.menuChordName) to open it, the D-pad to move, \(padKind.glyph("A")) to press, \(padKind.glyph("B")) to close, \(padKind.glyph("LB")) and \(padKind.glyph("RB")) to change tab.").font(.system(size: 12)).foregroundStyle(Theme.textDim)
            Button { dismissTip() } label: {
                Text("Got it").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 8).background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .focusTarget("tip-ok", radius: 16) { dismissTip() }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().overlay(Theme.line)
            FocusScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if showTip { menuTip }
                    switch model.tab {
                    case .performance: PerformanceTab(model: model, overlay: overlay)
                    case .controls: ControlsTab(model: model)
                    case .game: GameTab(model: model)
                    case .steam: SteamTab(model: model)
                    }
                }
                .padding(16)
            }
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(red: 0.04, green: 0.06, blue: 0.1).opacity(0.78)
            }
            .ignoresSafeArea()
        )
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .navScope(scope)
        .onAppear { configureNav() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Menu").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                if let name = model.gameName {
                    Text(name).font(.system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            Button { model.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.panelHigh))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(model.availableTabs) { tab in
                let on = model.tab == tab
                Button { model.tab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 16, weight: .semibold))
                        Text(tab.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background { if on { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentGradient) } }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])      // the tabs change with LB and RB or a tap, not with the D-pad
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

// MARK: - Pieces

struct MenuCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.label(title)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MenuChoiceRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19)).foregroundStyle(selected ? Theme.accent : Theme.textDim.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("choice:\(title)", radius: 8, scale: 1.0, action: action)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MenuToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 46)
        .focusTarget("toggle:\(title)", radius: 8, scale: 1.0) { isOn.toggle() }
    }
}

struct MenuActionRow: View {
    let title: String
    var symbol: String?
    var detail: String?
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 24).foregroundStyle(destructive ? Theme.bad : Theme.accent) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(destructive ? Theme.bad : Theme.text)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textDim.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("action:\(title)", radius: 8, scale: 1.0, action: action)
    }
}

struct MenuDivider: View { var body: some View { Divider().overlay(Theme.line).padding(.leading, 12) } }

// MARK: - Performance

private struct PerformanceTab: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings

    var body: some View {
        ProcessorCard()

        MenuCard(title: "Power", footer: model.powerChosen == .auto
             ? "Auto plays at a locked 60 FPS while iOS lets the fast cores run, drops to a steady 30 FPS for a minute or more once it holds them back, then tries again. Right now: \(model.powerEffective == .performance ? "60 FPS" : model.powerEffective.title)."
             : model.powerEffective != model.powerChosen
             ? "The phone is warm, so it is running as \(model.powerEffective.title) until it cools. Your choice comes back by itself."
             : "Applies to this game only. Your default is in Settings.") {
            ForEach(Array(PowerMode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: mode.title, detail: mode.detail, selected: model.powerChosen == mode) { model.setPower(mode) }
            }
        }

        MenuCard(title: "Engine", footer: "Eco puts the game on the efficiency cores: cooler and longer battery, slower. Frame generation helps a game running at no more than half the screen\u{2019}s rate (60 FPS on a 120 Hz screen); try it and look at the overlay. GPU sync only matters if you see flicker or a freeze.") {
            MenuToggleRow(title: "Eco mode", detail: nil, isOn: Binding(get: { model.eco }, set: { model.setEco($0) }))
            MenuDivider()
            MenuToggleRow(title: "Frame generation", detail: "Experimental. A picture between game frames, for a screen that can show twice the game's rate.",
                          isOn: Binding(get: { model.frameGen }, set: { model.setFrameGen($0) }))
            MenuDivider()
            VStack(alignment: .leading, spacing: 0) {
                Text("GPU sync").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                ForEach(GameMenuModel.fenceModes, id: \.mode) { item in
                    MenuChoiceRow(title: item.name, detail: item.detail, selected: model.fenceMode == item.mode) { model.setFence(item.mode) }
                }
            }
        }

        OverlayCard(overlay: overlay)
    }
}

/// Whether iOS is holding the phone's fast cores back (CPUClampMonitor).
private struct ProcessorCard: View {
    @ObservedObject private var monitor = CPUClampMonitor.shared
    var body: some View {
        MenuCard(title: "Processor", footer: "After a few minutes of load iOS pins the phone\u{2019}s fast cores at about 1.1 GHz, roughly half their speed, and the game slows down with them. Less power use delays it: a 30 FPS cap (Balanced) and the screen not held at 120 Hz help. Heat as iOS reports it: \(CPUClampMonitor.thermalName), pressure \(CPUClampMonitor.pressureName(monitor.pressure)).") {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 46)
        }
    }
    private var color: Color {
        switch monitor.state { case .clamped: Theme.bad; case .full: Theme.good; case .light: Theme.textDim; case .measuring: Theme.warn }
    }
    private var title: String {
        switch monitor.state {
        case .clamped: String(format: "Clamped by iOS: %.1f GHz", monitor.ghz)
        case .full: String(format: "Full speed: %.1f GHz", monitor.ghz)
        case .light: "Light load"
        case .measuring: "Measuring..."
        }
    }
    private var energyText: String {
        if let at = monitor.energyAtFirstClamp { return String(format: " Processor energy used: %.0f J when iOS first slowed them, %.0f J now.", at, monitor.energyJ) }
        return String(format: " Processor energy used: %.0f J. iOS has slowed the fast cores after about %.0f J in every test so far.", monitor.energyJ, CPUClampMonitor.observedBudgetJ)
    }
    private var shareText: String { monitor.fastShare >= 0 ? String(format: ". The fast cores carry %.0f%% of the game\u{2019}s work.", monitor.fastShare * 100) : "" }
    private var detail: String? {
        switch monitor.state {
        case .clamped:
            let n = monitor.clampedSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let first = monitor.firstClampAfter.map { Int($0) }
            return "Fast cores held back for \(n / 60) min \(n % 60) s" + (first.map { ", first \($0 / 60) min \($0 % 60) s into the game" } ?? "") + shareText + energyText
        case .full: return "The fast cores are not held back." + shareText + energyText
        case .light: return "Too little load to tell. The cores idle down by themselves." + energyText
        case .measuring: return "Needs a few seconds of play."
        }
    }
}

private struct OverlayCard: View {
    @ObservedObject var overlay: PerfOverlaySettings

    var body: some View {
        MenuCard(title: "Performance overlay", footer: "Drawn over the game. It never takes touches. Off until you turn it on.") {
            MenuToggleRow(title: "Show overlay", detail: nil, isOn: $overlay.enabled)
        }
        if overlay.enabled {
            MenuCard(title: "What to show") {
                FlowChips(overlay: overlay).padding(12)
            }
            MenuCard(title: "Look") {
                VStack(alignment: .leading, spacing: 12) {
                    labeled("Position") {
                        let cols = [GridItem(.flexible()), GridItem(.flexible())]
                        LazyVGrid(columns: cols, spacing: 6) {
                            ForEach(OverlayCorner.allCases) { corner in
                                pill(corner.title, on: overlay.corner == corner) { overlay.corner = corner }
                            }
                        }
                    }
                    labeled("Size") {
                        HStack(spacing: 6) {
                            ForEach(OverlaySize.allCases) { size in pill(size.title, on: overlay.size == size) { overlay.size = size } }
                        }
                    }
                    labeled("Layout") {
                        HStack(spacing: 6) {
                            pill("List", on: !overlay.asLine) { overlay.asLine = false }
                            pill("One line", on: overlay.asLine) { overlay.asLine = true }
                        }
                    }
                    labeled("Background \(Int(overlay.opacity * 100))%") {
                        Slider(value: $overlay.opacity, in: 0.15...1).tint(Theme.accent)
                            .focusTarget("slider:opacity", radius: 8, scale: 1.0, adjust: { step in overlay.opacity = min(1, max(0.15, overlay.opacity + Double(step) * 0.05)) }) {}
                    }
                }
                .padding(12)
                MenuDivider()
                MenuToggleRow(title: "Frame graph", detail: "FPS over the last minute", isOn: $overlay.showGraph)
                MenuDivider()
                MenuToggleRow(title: "Developer details", detail: "Input counters, engine memory and swap lines", isOn: $overlay.developerDetails)
            }
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
            content()
        }
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(on ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusTarget("pill:\(title)", radius: 9, scale: 1.0, action: action)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct FlowChips: View {
    @ObservedObject var overlay: PerfOverlaySettings
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(PerfMetric.allCases) { metric in
                let on = overlay.metrics.contains(metric)
                Button { overlay.toggle(metric) } label: {
                    HStack(spacing: 4) {
                        if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                        Text(metric.title).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.text)
                    .padding(.horizontal, 11).frame(minHeight: 34)
                    .background(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh), in: Capsule())
                }
                .buttonStyle(.plain)
                .focusTarget("metric:\(metric.title)", radius: 17, scale: 1.0) { overlay.toggle(metric) }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Controls

private struct ControlsTab: View {
    @ObservedObject var model: GameMenuModel

    var body: some View {
        MenuCard(title: "Controller", footer: (model.padKindName.isEmpty ? "No controller is connected." : "Connected: \(model.padKindName).")
                 + " The choice applies at once and is remembered for this game. A game that picks its controller only when it starts may need a restart to notice. The DualSense is available when a PlayStation controller was connected as the game started.") {
            MenuChoiceRow(title: "Automatic", detail: "Xbox pad, a DualSense for a PlayStation controller, keyboard and mouse if the game ignores it", selected: model.padMode == nil) { model.setPadMode(nil) }
            MenuDivider()
            MenuChoiceRow(title: "Xbox controller", detail: "The game sees an Xbox pad only", selected: model.padMode == "xbox") { model.setPadMode("xbox") }
            MenuDivider()
            MenuChoiceRow(title: "DualSense and Xbox", detail: model.padHidReady ? "The game sees a DualSense, with the Xbox pad kept for games that only read that" : "Saved, but it starts with the next launch of the game",
                          selected: model.padMode == "hid") { model.setPadMode("hid") }
            MenuDivider()
            MenuChoiceRow(title: "Keyboard and mouse", detail: "Sticks and buttons as keys and the mouse (the game's controller binds)", selected: model.padMode == "keys") { model.setPadMode("keys") }
        }

        MenuCard(title: "Layout", footer: model.customLayoutInUse
             ? "A layout from a bind set is on screen, so the built-in layouts are off. Change it under Binds."
             : "How the touch screen plays the game.") {
            if model.customLayoutInUse {
                MenuActionRow(title: "Binds and layouts", symbol: "square.grid.2x2", detail: "Pick a set or edit its controls") { model.openBinds() }
            } else {
                MenuChoiceRow(title: "Mouse and keys", detail: "Tap to click, a stick for W A S D", selected: model.layout == .standard) { model.setLayout(.standard) }
                MenuDivider()
                MenuChoiceRow(title: "First person", detail: "Drag to look around", selected: model.layout == .firstPerson) { model.setLayout(.firstPerson) }
            }
        }

        MenuCard(title: "On screen") {
            MenuToggleRow(title: "Show controls", detail: nil, isOn: Binding(get: { model.controlsShown }, set: { model.setControlsShown($0) }))
            if model.showLookSpeed {
                MenuDivider()
                HStack {
                    Text("Look speed").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    stepButton("minus", id: "look-less") { model.adjustLook(1 / 1.25) }
                    Text(String(format: "%.1f\u{00D7}", model.lookSpeed)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text).frame(minWidth: 52)
                    stepButton("plus", id: "look-more") { model.adjustLook(1.25) }
                }
                .padding(.horizontal, 12).frame(minHeight: 50)
            }
            MenuDivider()
            MenuActionRow(title: "Keyboard", symbol: "keyboard") { model.openKeyboard() }
        }

        MenuCard(title: "Binds") {
            if !model.customLayoutInUse {
                MenuActionRow(title: "Binds and layouts", symbol: "square.grid.2x2", detail: "Pick a set or edit its controls") { model.openBinds() }
                MenuDivider()
            }
            MenuActionRow(title: "Edit on-screen controls", symbol: "pencil", detail: "Move, resize and add buttons on the game") { model.editControls() }
        }
    }

    private func stepButton(_ symbol: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 40, height: 36).background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 9, scale: 1.0, action: action)
    }
}

// MARK: - Game

private struct GameTab: View {
    @ObservedObject var model: GameMenuModel

    var body: some View {
        MenuCard(title: "Help") {
            if model.hasReport {
                MenuActionRow(title: "Report how it runs", symbol: "text.bubble", detail: "Tell others how this game works on your device") { model.report() }
                MenuDivider()
            }
            MenuActionRow(title: "Touch controls guide", symbol: "questionmark.circle") { model.help() }
        }
        MenuCard(title: "Tools", footer: "A frame capture is for bug reports: it is taken a moment after the menu closes. The profile looks 200 times a second at what every busy thread is doing, names the busiest game modules and functions and writes them to the log; it slows the game a little while it runs.") {
            MenuActionRow(title: "Capture the next frame", symbol: "camera.viewfinder") { model.captureFrame() }
            MenuDivider()
            MenuActionRow(title: "Profile where the time goes", symbol: "waveform.path.ecg",
                          detail: "Close the menu and play for 30 seconds; the result goes into the log") { model.profile() }
        }
        MenuCard(title: "Edge handle and quick buttons", footer: "Swipe in from the right edge of the screen to open this menu, and swipe it back to the right to close it. The pencil and keyboard buttons fade along with the handle (Hidden dims them like Fades out) and light up when touched.") {
            ForEach(Array(MenuHandleStyle.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: style.title, detail: style.detail, selected: model.handleStyle == style) { model.setHandleStyle(style) }
            }
        }
        MenuCard(title: "Session") {
            MenuActionRow(title: "Restart game", symbol: "arrow.clockwise", detail: "Closes the game and Porthole, then starts the game again when you open Porthole") { model.restartGame() }
            MenuDivider()
            MenuActionRow(title: "Close game", symbol: "power", destructive: true) { model.closeGame() }
        }
    }
}
