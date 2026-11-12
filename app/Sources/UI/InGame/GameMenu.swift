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
    /// Lossless Scaling frame generation (only offered while its licence check passes): the live setting, and a sentence about what the engine reports.
    @Published var lsAvailable = false
    @Published var lsEnabled = false
    @Published var lsGenerated = 1
    @Published var lsFlow = 1.0
    @Published var lsPerformance = true
    @Published var lsStatus = ""
    /// Upscaling (MetalFX) changed live: 0 off, 1 to the screen, 2 a fixed factor, and the sentence about what the engine reports.
    @Published var upMode = 0
    @Published var upFactor = 2.0
    @Published var upMethod = 0       // 0 MetalFX, 1 Lossless Scaling LS1, 2 LS1 performance
    @Published var upSharpness = 3
    @Published var upLossless = false // the Lossless Scaling methods are offered (its copy is downloaded and licensed)
    @Published var upStatus = ""
    @Published var upAvailable = false
    @Published var fenceMode = 1

    // Controls
    /// The controller shown to the game: nil = Automatic, "xbox", "hid", "keys". `padHidReady`: the DualSense exists this session; `padKindName`: the connected controller.
    @Published var padMode: String?
    /// The on-screen game controller: on or off, its size and how opaque it is.
    @Published var virtualPad = false
    @Published var virtualPadScale = 1.0
    @Published var virtualPadLayout: VirtualPadLayout.Preset = .standard
    @Published var virtualPadStyle: VirtualPadStyle = .xbox
    @Published var virtualPadOpacity = 0.55
    @Published var padHidReady = false
    @Published var padKindName = ""
    @Published var layout: ControlLayout = .standard
    @Published var customLayoutInUse = false
    @Published var controlsShown = true
    /// Seconds without a touch after which the on-screen controls hide (0 = never); see TouchAutoHide.
    @Published var autoHideSeconds = 0
    /// Every on-screen stick floats: its base appears where the thumb lands (see FloatingStick).
    @Published var floatingSticks = false
    /// How a finger on the game works: as the cursor itself, or as a trackpad (TrackpadEngine), and the trackpad's speed.
    @Published var pointerMode = PointerMode.direct
    @Published var pointerSpeed = TrackpadEngine.Speed.normal
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
    var setLosslessEnabled: (Bool) -> Void = { _ in }
    var setLosslessGenerated: (Int) -> Void = { _ in }
    var setLosslessFlow: (Double) -> Void = { _ in }
    var setLosslessPerformance: (Bool) -> Void = { _ in }
    var refreshLosslessStatus: () -> Void = {}
    var setUpscaling: (Int, Double, Int, Int) -> Void = { _, _, _, _ in }
    var refreshUpscalingStatus: () -> Void = {}
    var setFence: (Int) -> Void = { _ in }
    var setHandleStyle: (MenuHandleStyle) -> Void = { _ in }
    var setLayout: (ControlLayout) -> Void = { _ in }
    var setControlsShown: (Bool) -> Void = { _ in }
    var setAutoHide: (Int) -> Void = { _ in }
    var setFloatingSticks: (Bool) -> Void = { _ in }
    var setPointerMode: (PointerMode) -> Void = { _ in }
    var setPointerSpeed: (TrackpadEngine.Speed) -> Void = { _ in }
    var adjustLook: (Double) -> Void = { _ in }
    var setPadMode: (String?) -> Void = { _ in }
    var setVirtualPad: (Bool) -> Void = { _ in }
    var setVirtualPadLayout: (VirtualPadLayout.Preset) -> Void = { _ in }
    var setVirtualPadStyle: (VirtualPadStyle) -> Void = { _ in }
    /// Changes the on-screen controller's size and opacity by these amounts (0.1 steps).
    var adjustVirtualPad: (Double, Double) -> Void = { _, _ in }
    var openKeyboard: () -> Void = {}
    var openFullKeyboard: () -> Void = {}
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

/// How much of the screen's right side the open menu covers. The launch screen's "Back to launch screen" pill sits in a window of its own above everything and keeps clear of it
/// (it used to be drawn over the menu's title).
@MainActor
final class MenuPresence: ObservableObject {
    static let shared = MenuPresence()
    @Published var panelWidth: CGFloat = 0
}

/// The side panel. Slides in from the right over a dimmed game; the game keeps running behind it.
struct GameMenuView: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings

    private func panelWidth(_ total: CGFloat) -> CGFloat { min(370, max(310, total * 0.4)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if model.isPresented {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { model.dismiss() }
                        .transition(.opacity)
                    GameMenuPanel(model: model, overlay: overlay)
                        .frame(width: panelWidth(geo.size.width))
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
        .background(GeometryReader { geo in
            Color.clear
                .onChange(of: model.isPresented) { _, open in MenuPresence.shared.panelWidth = open ? panelWidth(geo.size.width) : 0 }
                .onDisappear { MenuPresence.shared.panelWidth = 0 }
        })
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Menu").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                if let name = model.gameName {
                    Text(name).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { model.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.panelHigh)).overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    /// One row of equal tabs. The icon has a box of its own and the label is one line (scaled down a little when five tabs share a narrow panel), so every tab lines up and
    /// "Performance" never breaks in the middle of the word.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(model.availableTabs) { tab in
                let on = model.tab == tab
                Button { model.tab = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 16, weight: .semibold)).frame(height: 20)
                        Text(tab.title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.72).allowsTightening(true)
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background { if on { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accentGradient) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])      // the tabs change with LB and RB or a tap, not with the D-pad
            }
        }
        .padding(3)
        .background(Theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 12)
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
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
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
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 46)
            .background(selected ? Theme.accent.opacity(0.11) : Color.clear)          // the chosen one is easy to find
            .contentShape(Rectangle())
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

/// A row that opens to a few lines of explanation, closed at first: long text under a card pushed the choices off the screen of a phone held sideways.
struct MenuExpandRow: View {
    let title: String
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textDim).rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusTarget("expand:\(title)", radius: 8, scale: 1.0) { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }
}

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

        MenuCard(title: "Engine", footer: "Eco puts the game on the efficiency cores: cooler and longer battery, slower. GPU sync only matters if you see flicker or a freeze.") {
            MenuToggleRow(title: "Eco mode", detail: nil, isOn: Binding(get: { model.eco }, set: { model.setEco($0) }))
            MenuDivider()
            VStack(alignment: .leading, spacing: 0) {
                Text("GPU sync").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                ForEach(GameMenuModel.fenceModes, id: \.mode) { item in
                    MenuChoiceRow(title: item.name, detail: item.detail, selected: model.fenceMode == item.mode) { model.setFence(item.mode) }
                }
            }
        }

        if model.upAvailable { UpscalingCard(model: model) }

        if model.lsAvailable { LosslessCard(model: model) }

        OverlayCard(overlay: overlay)
    }
}

/// Lossless Scaling frame generation: on or off, how many frames to add, how detailed the motion search is, and what the engine says it is doing (refreshed every second while the menu is open).
/// MetalFX upscaling of the running game: off, to the screen, or a fixed factor. The engine takes the choice without a restart.
private struct UpscalingCard: View {
    @ObservedObject var model: GameMenuModel
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let choices: [(Int, Double, String, String)] = [
        (0, 2.0, "Off", "The picture is drawn as the game makes it."),
        (1, 2.0, "To the screen", "Enlarged to the screen\u{2019}s own pixels (at most 2\u{00D7}); nothing happens when the game already draws about as large as the screen."),
        (2, 1.5, "1.5\u{00D7}", "A fixed enlargement."),
        (2, 2.0, "2\u{00D7}", "A fixed doubling of the game\u{2019}s size."),
    ]
    private static let methods: [(Int, String, String)] = [
        (0, "MetalFX", "Apple\u{2019}s own spatial scaler. Works in Direct3D 11 and 12 games."),
        (1, "Lossless Scaling LS1", "Lossless Scaling\u{2019}s own upscaler, from your copy of the program: a small neural network that redraws the edges. Direct3D 11 and 12 games."),
        (2, "Lossless Scaling LS1 performance", "The same upscaler with a lighter network: less graphics work, a little less exact edges."),
    ]
    var body: some View {
        MenuCard(title: "Upscaling (MetalFX)", footer: model.upStatus) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Enlarge the game\u{2019}s picture").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                ForEach(Self.choices, id: \.2) { item in
                    MenuChoiceRow(title: item.2, detail: item.3, selected: model.upMode == item.0 && (item.0 != 2 || model.upFactor == item.1)) { model.setUpscaling(item.0, item.1, model.upMethod, model.upSharpness) }
                }
            }
            if model.upLossless && model.upMode != 0 {
                MenuDivider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Method").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                    ForEach(Self.methods, id: \.0) { item in
                        MenuChoiceRow(title: item.1, detail: item.2, selected: model.upMethod == item.0) { model.setUpscaling(model.upMode, model.upFactor, item.0, model.upSharpness) }
                    }
                }
                if model.upMethod != 0 {
                    MenuDivider()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Sharpness").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                        ForEach(1...5, id: \.self) { n in
                            MenuChoiceRow(title: "\(n)", detail: n == 1 ? "Softest: closest to a plain enlargement." : (n == 5 ? "Sharpest edges; can look over-processed." : nil), selected: model.upSharpness == n) { model.setUpscaling(model.upMode, model.upFactor, model.upMethod, n) }
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshUpscalingStatus() }
        .onReceive(tick) { _ in model.refreshUpscalingStatus() }
    }
}

private struct LosslessCard: View {
    @ObservedObject var model: GameMenuModel
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let flows: [(Double, String, String)] = [
        (1.0, "Full", "The motion search runs at the game\u{2019}s own size. Best picture, most work."),
        (1.5, "Medium", "Two thirds of the game\u{2019}s size."),
        (2.0, "Half", "Half the size: about a quarter of the work."),
        (3.0, "Third", "A third of the size."),
        (4.0, "Quarter", "A quarter of the size: fastest, roughest motion."),
    ]
    var body: some View {
        MenuCard(title: "Lossless Scaling", footer: model.lsStatus) {
            MenuToggleRow(title: "Frame generation", detail: "A picture between the game\u{2019}s frames, made with your copy of Lossless Scaling. Direct3D 11 and 12 games (12 needs more memory). The passes use graphics power, so the game itself runs slower: the screen shows more frames, but not double. The first seconds stutter while the shaders are prepared.",
                          isOn: Binding(get: { model.lsEnabled }, set: { model.setLosslessEnabled($0) }))
            if model.lsEnabled {
                MenuDivider()
                MenuToggleRow(title: "Lighter passes", detail: "Lossless Scaling\u{2019}s performance layout: fewer and smaller intermediate pictures, clearly less graphics work, a little less exact motion. Switch it off for the full layout.",
                              isOn: Binding(get: { model.lsPerformance }, set: { model.setLosslessPerformance($0) }))
                MenuDivider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Frames added between two").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                    ForEach([(1, "1", "One extra picture per game frame."), (2, "2", "Two extra: the passes run twice per game frame, so this costs a lot more."), (3, "3", "Three extra: three times the passes. Only for a strong device and a fast screen.")], id: \.0) { item in
                        MenuChoiceRow(title: item.1, detail: item.2, selected: model.lsGenerated == item.0) { model.setLosslessGenerated(item.0) }
                    }
                }
                MenuDivider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Motion search detail").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.top, 10)
                    ForEach(Self.flows, id: \.0) { item in
                        MenuChoiceRow(title: item.1, detail: item.2, selected: model.lsFlow == item.0) { model.setLosslessFlow(item.0) }
                    }
                }
            }
        }
        .onAppear { model.refreshLosslessStatus() }
        .onReceive(tick) { _ in model.refreshLosslessStatus() }
    }
}

/// Whether iOS is holding the phone's fast cores back (CPUClampMonitor).
private struct ProcessorCard: View {
    @ObservedObject private var monitor = CPUClampMonitor.shared
    var body: some View {
        MenuCard(title: "Processor") {
            HStack(alignment: .top, spacing: 12) {
                // A tile of its own (not a dot), so it is not mistaken for the choice buttons of the cards below.
                Image(systemName: "cpu").font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 36, height: 36).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                    Text("Heat: \(CPUClampMonitor.thermalName) \u{00B7} pressure: \(CPUClampMonitor.pressureName(monitor.pressure))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 46)
            MenuDivider()
            MenuExpandRow(title: "Why does iOS slow the phone down?",
                          text: "After a few minutes of load iOS pins the phone\u{2019}s fast cores at about 1.1 GHz, roughly half their speed, and the game slows down with them. Less power use delays it: a 30 FPS cap (Balanced) and the screen not held at 120 Hz help.")
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
            MenuToggleRow(title: "Game controller", detail: "An Xbox controller drawn on the screen, for games that want a pad. The touch layouts are put away while it is on; a real controller works with it.",
                          isOn: Binding(get: { model.virtualPad }, set: { model.setVirtualPad($0) }))
            if model.virtualPad {
                MenuDivider()
                HStack {
                    Text("Controller size").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    stepButton("minus", id: "vpad-smaller") { model.adjustVirtualPad(-0.1, 0) }
                    Text(String(format: "%.0f%%", model.virtualPadScale * 100)).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).frame(minWidth: 52)
                    stepButton("plus", id: "vpad-bigger") { model.adjustVirtualPad(0.1, 0) }
                }
                .padding(.horizontal, 12).frame(minHeight: 50)
                MenuDivider()
                HStack {
                    Text("Controller opacity").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    stepButton("minus", id: "vpad-fainter") { model.adjustVirtualPad(0, -0.1) }
                    Text(String(format: "%.0f%%", model.virtualPadOpacity * 100)).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).frame(minWidth: 52)
                    stepButton("plus", id: "vpad-stronger") { model.adjustVirtualPad(0, 0.1) }
                }
                .padding(.horizontal, 12).frame(minHeight: 50)
            }
            MenuDivider()
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
            MenuActionRow(title: "Keyboard", symbol: "keyboard", detail: "The iPhone's keyboard, for typing text") { model.openKeyboard() }
            MenuDivider()
            MenuActionRow(title: "Full keyboard", symbol: "keyboard.fill", detail: "Every key: F keys, arrows, Ctrl, Alt and Shift") { model.openFullKeyboard() }
        }

        MenuCard(title: "Touch pointer", footer: "For point-and-click and strategy games and anything with small targets: Trackpad keeps your finger off the thing you are aiming at. A first-person game's look-around is not affected.") {
            ForEach(Array(PointerMode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: mode.title, detail: mode.detail, selected: model.pointerMode == mode) { model.setPointerMode(mode) }
            }
            if model.pointerMode == .trackpad {
                MenuDivider()
                HStack(spacing: 8) {
                    Text("Cursor speed").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    ForEach(TrackpadEngine.Speed.allCases, id: \.self) { speed in
                        Button { model.setPointerSpeed(speed) } label: {
                            Text(speed.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(model.pointerSpeed == speed ? Theme.onAccent : Theme.text)
                                .padding(.horizontal, 11).frame(minHeight: 34)
                                .background(model.pointerSpeed == speed ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .focusTarget("pointer-speed:\(speed.rawValue)", radius: 17, scale: 1.0) { model.setPointerSpeed(speed) }
                        .accessibilityAddTraits(model.pointerSpeed == speed ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 50)
            }
        }

        MenuCard(title: "Sticks", footer: "A stick takes a touch near its place and puts its base where your thumb lands, so you do not have to find the circle. Not while you edit the layout.") {
            MenuToggleRow(title: "Floating sticks", detail: nil, isOn: Binding(get: { model.floatingSticks }, set: { model.setFloatingSticks($0) }))
        }

        MenuCard(title: "Hide when not touched", footer: "The on-screen controls hide when no finger has touched the screen for this long, and come back with a touch anywhere. They never hide while a menu is open or a finger is held on one.") {
            ForEach(Array(TouchAutoHide.choices.enumerated()), id: \.element) { index, seconds in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: TouchAutoHide.title(seconds), detail: nil, selected: model.autoHideSeconds == seconds) { model.setAutoHide(seconds) }
            }
        }

        if model.virtualPad {
            MenuCard(title: "Controller type", footer: "The controller it imitates: its look and its own layout. The game sees an Xbox pad whichever you choose.") {
                ForEach(Array(VirtualPadStyle.allCases.enumerated()), id: \.element) { index, style in
                    if index > 0 { MenuDivider() }
                    MenuChoiceRow(title: style.title, detail: style.detail, selected: model.virtualPadStyle == style) { model.setVirtualPadStyle(style) }
                }
            }
            MenuCard(title: "Controller layout", footer: "Choosing a type already picks its layout. Pick another here to change only where the controls are; a layout leaves out the controls it does not need.") {
                ForEach(Array(VirtualPadLayout.Preset.allCases.enumerated()), id: \.element) { index, preset in
                    if index > 0 { MenuDivider() }
                    MenuChoiceRow(title: preset.title, detail: preset.detail, selected: model.virtualPadLayout == preset) { model.setVirtualPadLayout(preset) }
                }
            }
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
