// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

enum GameMenuTab: String, CaseIterable, Identifiable {
    case performance, controls, game, steam, discord
    var id: String { rawValue }
    var title: String { switch self { case .performance: "Performance"; case .controls: "Controls"; case .game: "Game"; case .steam: "Steam"; case .discord: "Discord" } }
    var symbol: String { switch self { case .performance: "gauge.with.dots.needle.67percent"; case .controls: "gamecontroller"; case .game: "ellipsis.circle"; case .steam: "person.2.fill"; case .discord: "bubble.left.and.bubble.right.fill" } }
}

/// A page that opens from a row of a tab (a setting with options of its own). The row's focus id is "nav:" + the raw value, so Back can put the glow on it again.
enum MenuPage: String {
    case power, upscaling, frameGeneration, overlay, controller, touchLayout, onScreenPad, handle
    case discordServers, discordVoice, discordFriends, discordNotify, discordPeople, discordLive, discordConversation
    var title: String {
        switch self {
        case .power: "Power"
        case .upscaling: "Upscaling"
        case .frameGeneration: "Frame generation"
        case .overlay: "Overlay"
        case .controller: "Controller"
        case .touchLayout: "Layout"
        case .onScreenPad: "Appearance"
        case .handle: "Edge handle"
        case .discordServers: "Servers and channels"
        case .discordVoice: "Voice and sound"
        case .discordFriends: "Friends"
        case .discordNotify: "Notifications"
        case .discordPeople: "People in the call"
        case .discordLive: "Go Live"
        case .discordConversation: "Messages"
        }
    }
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
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "f4.menuTab"); page = nil }
    }
    /// The page open on the tab (nil = the tab's own list of rows).
    @Published var page: MenuPage?

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
    @Published var virtualPadStyle: VirtualPadStyle = .xbox
    @Published var virtualPadLayout: VirtualPadLayout.Preset = .porthole
    @Published var virtualPadOpacity = 0.55
    @Published var padHidReady = false
    @Published var padKindName = ""
    @Published var customLayoutInUse = false
    /// The quick layout switch: the game's default controls and its sets with a touch layout (see GameLayouts).
    @Published var layoutChoices: [LayoutChoice] = []
    /// Every touch layout is shown flipped left to right (TouchHandedness).
    @Published var leftHanded = false
    /// The layout on screen is already the default for every game.
    @Published var layoutIsMyDefault = false
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
    var availableTabs: [GameMenuTab] { GameMenuTab.allCases.filter { ($0 != .steam || (steamAppID != nil && SteamStore.shared.signedIn)) && ($0 != .discord || DiscordSession.shared.enabled) } }

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
    var setControlsShown: (Bool) -> Void = { _ in }
    var setAutoHide: (Int) -> Void = { _ in }
    var setFloatingSticks: (Bool) -> Void = { _ in }
    var setPointerMode: (PointerMode) -> Void = { _ in }
    var setPointerSpeed: (TrackpadEngine.Speed) -> Void = { _ in }
    var adjustLook: (Double) -> Void = { _ in }
    var setPadMode: (String?) -> Void = { _ in }
    var setVirtualPad: (Bool) -> Void = { _ in }
    var setVirtualPadStyle: (VirtualPadStyle) -> Void = { _ in }
    var setVirtualPadLayout: (VirtualPadLayout.Preset) -> Void = { _ in }
    /// Changes the on-screen controller's size and opacity by these amounts (0.1 steps).
    var adjustVirtualPad: (Double, Double) -> Void = { _, _ in }
    var openKeyboard: () -> Void = {}
    var openFullKeyboard: () -> Void = {}
    var openBinds: () -> Void = {}
    var chooseLayout: (UUID?) -> Void = { _ in }
    var pickStarterLayout: () -> Void = {}
    var setLeftHanded: (Bool) -> Void = { _ in }
    var editControls: () -> Void = {}
    /// Makes the layout on screen the one every game starts with (Settings > Controls).
    var useAsDefault: () -> Void = {}
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
    /// The open menu leaves less than a pill's width of the screen (a phone: the menu fills it).
    var coversScreen: Bool { panelWidth > 0 && UIScreen.main.bounds.width - panelWidth < 240 }
}

/// The side panel. Slides in from the right over a dimmed game; the game keeps running behind it.
struct GameMenuView: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings

    /// An iPad gets a floating card instead (see `padCard`).
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private static let cardMargin = MenuCardSizing.margin
    /// The width the person gave the card (or the standard one), kept between games.
    @ObservedObject private var cardSize = MenuCardSize.shared
    private func cardWidth(_ total: CGFloat) -> CGFloat { cardSize.width(total: total) }

    /// A phone (held either way) gets the whole screen: a 350-point strip left only about five rows. An iPad held sideways gets a panel on the right and the game stays in view,
    /// and playable, beside it (nothing is dimmed or blocked there).
    private func panelWidth(_ total: CGFloat) -> CGFloat { total < 900 ? total : min(total, 760) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if model.isPresented, isPad {
                    padCard(geo)
                } else if model.isPresented {
                    // A panel that fills the screen is tinted by one backdrop over the whole screen (the panel itself stops at the notch); a narrower one tints itself.
                    if panelWidth(geo.size.width) >= geo.size.width - 1 { MenuBackdrop().transition(.opacity) }
                    GameMenuPanel(model: model, overlay: overlay, ownBackdrop: panelWidth(geo.size.width) < geo.size.width - 1)
                        .frame(width: panelWidth(geo.size.width))
                        .frame(maxHeight: .infinity)
                        // Swipe the panel to the right: back out of a page, or close the menu.
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                            if v.translation.width > 70, abs(v.translation.height) < v.translation.width * 0.6 { if model.page != nil { model.page = nil } else { model.dismiss() } }
                        })
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: model.isPresented)
        .background(GeometryReader { geo in
            Color.clear
                .onChange(of: model.isPresented) { _, open in MenuPresence.shared.panelWidth = open ? occupiedWidth(geo.size.width) : 0 }
                .onChange(of: cardSize.custom) { _, _ in if model.isPresented { MenuPresence.shared.panelWidth = occupiedWidth(geo.size.width) } }
                .onDisappear { MenuPresence.shared.panelWidth = 0 }
        })
    }

    /// How much of the screen's width the open menu takes, for the things that keep out of its way.
    private func occupiedWidth(_ total: CGFloat) -> CGFloat { isPad ? cardWidth(total) + Self.cardMargin + 24 : panelWidth(total) }

    /// The iPad's menu: a floating card on the right (MenuCardFrame). The game stays in view and playable beside it.
    private func padCard(_ geo: GeometryProxy) -> some View {
        MenuCardFrame(total: geo.size.width, safe: geo.safeAreaInsets, close: { model.dismiss() },
                      swipeBack: { if model.page != nil { model.page = nil } else { model.dismiss() } }) {
            GameMenuPanel(model: model, overlay: overlay, ownBackdrop: false, card: true, total: geo.size.width)
        }
    }
}

private struct GameMenuPanel: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings
    /// False when the menu draws one backdrop over the whole screen.
    var ownBackdrop = true
    /// An iPad's floating card (its surface and edge are drawn by the frame around it), and the width of the screen it sits on (for the expand button).
    var card = false
    var total: CGFloat = 0
    @ObservedObject private var cardSize = MenuCardSize.shared
    /// The first time the menu opens: a short explanation of its three tabs at the top (until it is dismissed).
    @State private var showTip = GuideCenter.shared.wantsTip(GuideCatalog.gameMenu.id)
    /// The controller's layer: D-pad moves the glow, A presses, B or Options closes, the shoulder buttons switch tabs.
    @State private var scope = FocusScope()

    private func dismissTip() {
        GuideCenter.shared.markSeen(GuideCatalog.gameMenu.id)
        withAnimation { showTip = false }
    }

    private func configureNav() {
        scope.onBack = { [model] in if model.page != nil { model.page = nil } else { model.dismiss() } }      // B: out of a page first, then the menu
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
            Text("Close it with the Close button (on an iPad also the handle on its edge), or swipe it to the right. With a controller: hold \(padKind.menuChordName) to open it, the D-pad to move, \(padKind.glyph("A")) to press, \(padKind.glyph("B")) to close, \(padKind.glyph("LB")) and \(padKind.glyph("RB")) to change tab.").font(.system(size: 12)).foregroundStyle(Theme.textDim)
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

    /// Back from a page: the list it was opened from, with the glow on the row that opened it.
    private func goBack() {
        guard let old = model.page else { return }
        model.page = nil
        DispatchQueue.main.async { [scope] in scope.focused = "nav:\(old.rawValue)" }
    }

    var body: some View {
        MenuChrome(title: "Menu", subtitle: model.gameName, page: model.page?.title, backTitle: model.tab.title,
                   tabs: model.availableTabs.map { MenuTabItem(id: $0.rawValue, title: $0.title, symbol: $0.symbol) }, tab: model.tab.rawValue,
                   selectTab: { id in if let tab = GameMenuTab(rawValue: id) { model.tab = tab } },
                   back: goBack, close: { model.dismiss() }, card: card,
                   toggleSize: card ? { [cardSize, total] in withAnimation(.easeOut(duration: 0.22)) { cardSize.toggleLarge(total: total) } } : nil,
                   sizeIsLarge: card && cardSize.isLarge(total: total)) {
            if showTip && model.page == nil { menuTip }
            switch model.tab {
            case .performance: PerformanceTab(model: model, overlay: overlay)
            case .controls: ControlsTab(model: model)
            case .game: GameTab(model: model)
            case .steam: SteamTab(model: model)
            case .discord: DiscordTab(model: model)
            }
        }
        .background { if ownBackdrop { MenuBackdrop() } }
        .overlay(alignment: .leading) { if !card { Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea() } }
        .environment(\.colorScheme, .dark)
        .navScope(scope)
        .onAppear { model.page = nil; configureNav() }
    }
}

// MARK: - Pieces

// MARK: - Performance

private struct PerformanceTab: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject var overlay: PerfOverlaySettings

    var body: some View {
        switch model.page {
        case .power?: powerPage
        case .upscaling?: UpscalingCard(model: model)
        case .frameGeneration?: LosslessCard(model: model)
        case .overlay?: OverlayDetails(overlay: overlay)
        default: root
        }
    }

    // The tab's list: how the phone is doing, then one row for each setting with the value it has now.
    @ViewBuilder private var root: some View {
        ProcessorCard()

        MenuCard(title: "Speed") {
            MenuNavRow(id: MenuPage.power.rawValue, symbol: "bolt.fill", tint: .orange, title: "Power", value: powerValue) { model.page = .power }
        }

        if model.upAvailable || model.lsAvailable {
            MenuCard(title: "Picture") {
                if model.upAvailable {
                    MenuNavRow(id: MenuPage.upscaling.rawValue, symbol: "arrow.up.left.and.arrow.down.right", tint: .blue, title: "Upscaling", value: upscalingValue) { model.page = .upscaling }
                }
                if model.upAvailable && model.lsAvailable { MenuDivider() }
                if model.lsAvailable {
                    MenuNavRow(id: MenuPage.frameGeneration.rawValue, symbol: "film.stack", tint: .purple, title: "Frame generation", value: model.lsEnabled ? "On, \(model.lsGenerated) extra" : "Off") { model.page = .frameGeneration }
                }
            }
        }

        MenuCard(title: "On the screen") {
            MenuToggleRow(title: "Performance overlay", detail: nil, isOn: $overlay.enabled)
            if overlay.enabled {
                MenuDivider()
                MenuNavRow(id: MenuPage.overlay.rawValue, symbol: "chart.xyaxis.line", tint: .green, title: "Overlay details", value: "\(overlay.metrics.count) shown") { model.page = .overlay }
            }
        }
    }

    private var powerValue: String {
        let base: String
        if model.powerChosen == .auto { base = "Auto, \(model.powerEffective == .performance ? "60 FPS" : model.powerEffective.title)" }
        else { base = model.powerEffective != model.powerChosen ? "\(model.powerChosen.title), warm" : model.powerChosen.title }
        return model.eco ? "\(base), eco" : base
    }
    private var upscalingValue: String {
        let size: String
        switch model.upMode {
        case 0: return "Off"
        case 1: size = "To the screen"
        default: size = model.upFactor == 1.5 ? "1.5\u{00D7}" : "\(Int(model.upFactor))\u{00D7}"
        }
        return model.upLossless && model.upMethod != 0 ? "\(size), LS1" : size
    }

    @ViewBuilder private var powerPage: some View {
        MenuCard(title: "Power", footer: model.powerChosen == .auto
             ? "Auto plays at a locked 60 FPS while iOS lets the fast cores run, drops to a steady 30 FPS for a minute or more once it holds them back, then tries again. Right now: \(model.powerEffective == .performance ? "60 FPS" : model.powerEffective.title)."
             : model.powerEffective != model.powerChosen
             ? "The phone is warm, so it is running as \(model.powerEffective.title) until it cools. Your choice comes back by itself."
             : "Applies to this game only. Your default is in Settings.") {
            ForEach(Array(PowerMode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: mode.title, detail: mode.detail, selected: model.powerChosen == mode) { model.setPower(mode) }
            }
            MenuDivider()
            MenuToggleRow(title: "Eco mode", detail: "Plays on the efficiency cores: cooler and longer battery, slower.", isOn: Binding(get: { model.eco }, set: { model.setEco($0) }))
        }
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
        MenuCard(title: "Upscaling", footer: model.upStatus) {
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

/// Whether iOS is holding the phone's fast cores back (CPUClampMonitor): a state and a line of heat, with the long detail one tap away.
private struct ProcessorCard: View {
    @ObservedObject private var monitor = CPUClampMonitor.shared
    var body: some View {
        MenuCard(title: "Processor") {
            HStack(alignment: .center, spacing: 12) {
                // A tile of its own (not a dot), so it is not mistaken for the choice buttons of the cards below.
                Image(systemName: "cpu").font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 36, height: 36).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Heat: \(CPUClampMonitor.thermalName) \u{00B7} pressure: \(CPUClampMonitor.pressureName(monitor.pressure))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 46)
            MenuDivider()
            MenuExpandRow(title: "Details and why iOS slows the phone down",
                          text: (detail.map { $0 + "\n\n" } ?? "")
                          + "After a few minutes of load iOS pins the phone\u{2019}s fast cores at about 1.1 GHz, roughly half their speed, and the game slows down with them. Less power use delays it: a 30 FPS cap (Balanced) and the screen not held at 120 Hz help.")
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

/// What the overlay shows and how it looks (the page behind "Overlay details"; the on/off switch is a row of the tab).
private struct OverlayDetails: View {
    @Environment(\.menuRegular) private var regular
    @ObservedObject var overlay: PerfOverlaySettings

    var body: some View {
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
        Text("Drawn over the game. It never takes touches.").font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.horizontal, 4)
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
            content()
        }
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: regular ? 15 : 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(on ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity, minHeight: regular ? 44 : 36)
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

/// A name with a value and a minus and a plus: the controller's size and opacity, the look speed.
private struct MenuStepper: View {
    let title: String
    let value: String
    let id: String
    let less: () -> Void
    let more: () -> Void
    @Environment(\.menuRegular) private var regular
    var body: some View {
        HStack {
            Text(title).font(.system(size: regular ? 17 : 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            button("minus", "\(id)-less", less)
            Text(value).font(.system(size: regular ? 17 : 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).frame(minWidth: regular ? 64 : 52)
            button("plus", "\(id)-more", more)
        }
        .padding(.horizontal, regular ? 16 : 12).frame(minHeight: regular ? 62 : 50)
    }
    private func button(_ symbol: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: regular ? 16 : 14, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: regular ? 52 : 40, height: regular ? 44 : 36).background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: regular ? 12 : 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 9, scale: 1.0, action: action)
    }
}

/// The layouts of the game as a wrapping row of chips, the one in use marked, and a chip to add another from a starter layout.
private struct LayoutChips: View {
    let choices: [LayoutChoice]
    let choose: (UUID?) -> Void
    let add: () -> Void
    @Environment(\.menuRegular) private var regular

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(choices) { c in chip(c.title, selected: c.selected, id: "layout-chip:\(c.id)") { choose(c.setID) } }
            chip("+ New", selected: false, id: "layout-chip:new", action: add)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: regular ? 15 : 13, weight: .semibold)).foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .padding(.horizontal, regular ? 16 : 12).frame(minHeight: regular ? 42 : 34)
                .background(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh), in: Capsule())
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 17, scale: 1.0, action: action)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ControlsTab: View {
    @ObservedObject var model: GameMenuModel

    var body: some View {
        switch model.page {
        case .controller?: controllerPage
        case .touchLayout?: layoutPage
        case .onScreenPad?: padPage
        default: root
        }
    }

    // The tab's list: which layout is in use (and a quick switch to another), the controller, what the game screen shows, and the editing shortcuts.
    @ViewBuilder private var root: some View {
        MenuCard(title: "Layout", footer: model.virtualPad ? "The on-screen game controller is on, so the touch layouts are put away. Turn it off under Controller." : "Tap a layout to switch to it. Your layouts are kept, so another tap goes back.") {
            if !model.virtualPad {
                LayoutChips(choices: model.layoutChoices, choose: { model.chooseLayout($0) }, add: { model.pickStarterLayout() })
                MenuDivider()
            }
            MenuToggleRow(title: "Left-handed", detail: "Flips every layout left to right", isOn: Binding(get: { model.leftHanded }, set: { model.setLeftHanded($0) }))
            MenuDivider()
            MenuNavRow(id: MenuPage.touchLayout.rawValue, symbol: "hand.tap.fill", tint: .teal, title: "Touch settings", value: model.pointerMode.title) { model.page = .touchLayout }
        }

        MenuCard(title: "Controller") {
            MenuNavRow(id: MenuPage.controller.rawValue, symbol: "gamecontroller.fill", tint: .blue, title: "Controller", value: controllerValue) { model.page = .controller }
            MenuDivider()
            MenuToggleRow(title: "On-screen game controller", detail: "Draws an Xbox controller on the screen, for games that want a pad.",
                          isOn: Binding(get: { model.virtualPad }, set: { model.setVirtualPad($0) }))
            if model.virtualPad {
                MenuDivider()
                MenuNavRow(id: MenuPage.onScreenPad.rawValue, symbol: "slider.horizontal.3", tint: .pink, title: "Appearance",
                           value: "\(model.virtualPadStyle.title), \(model.virtualPadLayout.title)") { model.page = .onScreenPad }
            }
        }

        MenuCard(title: "On the game screen") {
            MenuToggleRow(title: "Show controls", detail: nil, isOn: Binding(get: { model.controlsShown }, set: { model.setControlsShown($0) }))
            if model.showLookSpeed {
                MenuDivider()
                MenuStepper(title: "Look speed", value: String(format: "%.1f\u{00D7}", model.lookSpeed), id: "look", less: { model.adjustLook(1 / 1.25) }, more: { model.adjustLook(1.25) })
            }
            MenuDivider()
            MenuActionRow(title: "Keyboard", symbol: "keyboard") { model.openKeyboard() }
            MenuDivider()
            MenuActionRow(title: "Full keyboard", symbol: "keyboard.fill", detail: "Every key: F keys, arrows, Ctrl, Alt and Shift") { model.openFullKeyboard() }
        }

        MenuCard(title: "Edit and share") {
            MenuActionRow(title: "Binds and layouts", symbol: "square.grid.2x2", detail: "Every set of this game: edit, add or share them") { model.openBinds() }
            MenuDivider()
            MenuActionRow(title: "Edit on-screen controls", symbol: "pencil", detail: "Move, resize and add buttons on the game") { model.editControls() }
            if model.customLayoutInUse {
                MenuDivider()
                if model.layoutIsMyDefault {
                    MenuActionRow(title: "These are your default controls", symbol: "star.fill", detail: "Every game without controls of its own starts with them") {}
                } else {
                    MenuActionRow(title: "Use as my default controls", symbol: "star", detail: "Every game without controls of its own will start with these") { model.useAsDefault() }
                }
            }
        }
    }

    private var controllerValue: String {
        switch model.padMode {
        case nil: "Automatic"
        case "xbox"?: "Xbox"
        case "hid"?: "DualSense and Xbox"
        case "keys"?: "Keyboard and mouse"
        default: "Automatic"
        }
    }

    @ViewBuilder private var controllerPage: some View {
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
    }

    @ViewBuilder private var layoutPage: some View {
        MenuCard(title: "Touch pointer", footer: "For point-and-click and strategy games and anything with small targets: Trackpad keeps your finger off the thing you are aiming at. Looking around with the Look button is not affected.") {
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
    }

    @ViewBuilder private var padPage: some View {
        MenuCard(title: "Size and opacity") {
            MenuStepper(title: "Size", value: String(format: "%.0f%%", model.virtualPadScale * 100), id: "vpad-size", less: { model.adjustVirtualPad(-0.1, 0) }, more: { model.adjustVirtualPad(0.1, 0) })
            MenuDivider()
            MenuStepper(title: "Opacity", value: String(format: "%.0f%%", model.virtualPadOpacity * 100), id: "vpad-opacity", less: { model.adjustVirtualPad(0, -0.1) }, more: { model.adjustVirtualPad(0, 0.1) })
        }
        MenuCard(title: "Layout", footer: "Where the controls are. Every controller type has both.") {
            ForEach(Array(VirtualPadLayout.Preset.allCases.enumerated()), id: \.element) { index, preset in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: preset.title, detail: preset.detail, selected: model.virtualPadLayout == preset) { model.setVirtualPadLayout(preset) }
            }
        }
        MenuCard(title: "Controller type", footer: "The controller it imitates: the names and colours on the buttons. The game sees an Xbox pad whichever you choose.") {
            ForEach(Array(VirtualPadStyle.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: style.title, detail: style.detail, selected: model.virtualPadStyle == style) { model.setVirtualPadStyle(style) }
            }
        }
    }
}

// MARK: - Game

private struct GameTab: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject private var look = MenuAppearance.shared

    var body: some View {
        switch model.page {
        case .handle?: handlePage
        default: root
        }
    }

    @ViewBuilder private var root: some View {
        MenuCard(title: "Help") {
            if model.hasReport {
                MenuActionRow(title: "Report how it runs", symbol: "text.bubble", detail: "Tell others how this game works on your device") { model.report() }
                MenuDivider()
            }
            MenuActionRow(title: "Touch controls guide", symbol: "questionmark.circle") { model.help() }
            MenuDivider()
            MenuActionRow(title: "Show me around this menu", symbol: "hand.point.up.left.fill", detail: "A tour that points at each tab and what it does") { TutorialLibrary.shared.start("game-menu") }
        }
        MenuCard(title: "Tools") {
            MenuActionRow(title: "Capture the next frame", symbol: "camera.viewfinder") { model.captureFrame() }
            MenuDivider()
            MenuActionRow(title: "Profile where the time goes", symbol: "waveform.path.ecg",
                          detail: "Close the menu and play for 30 seconds; the result goes into the log") { model.profile() }
            MenuDivider()
            MenuExpandRow(title: "What are these for?",
                          text: "A frame capture is for bug reports: it is taken a moment after the menu closes. The profile looks 200 times a second at what every busy thread is doing, names the busiest game modules and functions and writes them to the log; it slows the game a little while it runs.")
        }
        MenuCard(title: "This menu") {
            MenuNavRow(id: MenuPage.handle.rawValue, symbol: "rectangle.righthalf.inset.filled", tint: .indigo, title: "Edge handle", value: model.handleStyle.title) { model.page = .handle }
            MenuDivider()
            MenuStepper(title: "Background", value: "\(Int((look.solidity * 100).rounded()))%", id: "menu-solid", less: { look.step(-1) }, more: { look.step(1) })
        }
        MenuCard(title: "Session") {
            MenuActionRow(title: "Restart game", symbol: "arrow.clockwise", detail: "Closes the game and Porthole, then starts the game again when you open Porthole") { model.restartGame() }
            MenuDivider()
            MenuActionRow(title: "Close game", symbol: "power", destructive: true) { model.closeGame() }
        }
    }

    @ViewBuilder private var handlePage: some View {
        MenuCard(title: "Edge handle", footer: "Swipe in from the right edge of the screen to open this menu, and swipe it to the right to go back or close it. The pencil and keyboard buttons fade along with the handle (Hidden dims them like Fades out) and light up when touched.") {
            ForEach(Array(MenuHandleStyle.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 { MenuDivider() }
                MenuChoiceRow(title: style.title, detail: style.detail, selected: model.handleStyle == style) { model.setHandleStyle(style) }
            }
        }
    }
}
