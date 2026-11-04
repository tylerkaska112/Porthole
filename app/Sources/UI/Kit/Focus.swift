// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import GameController
import Observation

// Controller-first navigation. Every tappable thing in the new screens is a "focus target": it reports where it is on screen, the D-pad (or arrow keys) move a
// glowing focus between targets by position, A (or Return) presses it, B (or Escape) goes back, and the shoulder buttons switch sections. Touch still works exactly
// as before; a tap just also moves the glow to what was tapped.

/// Who receives controller input right now: the top-most layer.
@MainActor @Observable
final class NavHub {
    static let shared = NavHub()
    private var stack: [FocusScope] = []
    /// Off while a game is running, so a controller drives the game instead.
    var enabled = true
    /// The in-game menu is open: the controller drives it even though a game is running.
    var gameMenuOpen = false
    private(set) var lastWasController = false
    /// True while a command from a controller or a hardware keyboard is being carried out, so an action can tell a press of A from a tap on the same thing.
    private(set) var isControllerCommand = false
    /// When a controller or keyboard last drove the interface. A pointer resting over a view that scrolls underneath it reports a new "hover" every time the content moves,
    /// which used to pull focus away from where the D-pad had just put it; the pointer is ignored for a moment after any controller input.
    private(set) var lastCommandAt: TimeInterval = 0
    /// The view a resting pointer just gave the glow to: its `onFocus` (open a Settings page, show a game in the hero) is for a controller or a click, not for hovering.
    var pointerFocusID: AnyHashable?
    var pointerMayMoveFocus: Bool { ProcessInfo.processInfo.systemUptime - lastCommandAt > 1.2 }

    /// The layer controller input goes to now.
    var top: FocusScope? { stack.last }

    func push(_ scope: FocusScope) { stack.removeAll { $0 === scope }; stack.append(scope) }
    func pop(_ scope: FocusScope) { stack.removeAll { $0 === scope } }
    /// A swipe in from the left edge: the same as B, but it does not count as the controller having been used (the glow stays off).
    func swipeBack() {
        guard enabled || gameMenuOpen, let top = stack.last else { return }
        top.handle(.back)
    }
    func dispatch(_ command: NavCommand) {
        guard enabled || gameMenuOpen, let top = stack.last else { return }
        lastWasController = true
        // iOS's keyboard is for touch and a hardware keyboard: if one is up when a controller button is pressed (a field was tapped, an alert's text field), it goes away.
        if TextEntry.padMode { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        lastCommandAt = ProcessInfo.processInfo.systemUptime
        isControllerCommand = true
        defer { isControllerCommand = false }
        top.handle(command)
    }
}

private struct FocusScopeKey: EnvironmentKey { static let defaultValue: FocusScope? = nil }
extension EnvironmentValues { var focusScope: FocusScope? { get { self[FocusScopeKey.self] } set { self[FocusScopeKey.self] = newValue } } }

private struct FocusEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues { var focusEnabled: Bool { get { self[FocusEnabledKey.self] } set { self[FocusEnabledKey.self] = newValue } } }

extension View {
    /// Keeps a screen alive but out of the D-pad's reach (a list that stays in memory under the page opened from it).
    func focusSuspended(_ suspended: Bool) -> some View { environment(\.focusEnabled, !suspended) }
}

extension View {
    /// Makes this view the layer controller input goes to while it is on screen, and gives its content a scope to register targets in.
    func navScope(_ scope: FocusScope) -> some View { modifier(NavScopeModifier(scope: scope)) }

    /// A thing the D-pad can land on. `action` runs on A / Return (and should do what a tap does).
    /// `label` and `secondaryLabel` are what the bar of controller hints says A and X do while this target has the glow (default "Select"; X only shows when `secondary` is set).
    func focusTarget(_ id: AnyHashable, radius: CGFloat = 18, scale: CGFloat = 1.04, glow: Bool = true, secondary: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil,
                     label: String? = nil, secondaryLabel: String? = nil, engageToAdjust: Bool = false,
                     onFocus: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(FocusTargetModifier(id: id, radius: radius, scale: scale, glow: glow, secondary: secondary, adjust: adjust, label: label, secondaryLabel: secondaryLabel, engageToAdjust: engageToAdjust, onFocus: onFocus, action: action))
    }

    /// A swipe from the left edge goes back, as in any iOS app: it does what B does, so every screen that handles B is covered.
    func edgeSwipeBack() -> some View { modifier(EdgeSwipeBackModifier()) }

    /// Runs when B is pressed while this view is on screen, before the screen's default. Return true when it handled the press.
    func onNavBack(_ handler: @escaping () -> Bool) -> some View { modifier(NavBackModifier(handler: handler)) }
}

private struct NavScopeModifier: ViewModifier {
    let scope: FocusScope
    func body(content: Content) -> some View {
        content
            .environment(\.focusScope, scope)
            .onAppear { NavHub.shared.push(scope) }
            .onDisappear { NavHub.shared.pop(scope) }
    }
}

private struct FocusTargetModifier: ViewModifier {
    let id: AnyHashable
    let radius: CGFloat
    let scale: CGFloat
    let glow: Bool
    let secondary: (() -> Void)?
    let adjust: ((Int) -> Void)?
    let label: String?
    let secondaryLabel: String?
    let engageToAdjust: Bool
    let onFocus: (() -> Void)?
    let action: () -> Void
    @Environment(\.focusScope) private var scope
    @Environment(\.focusEnabled) private var enabled
    @State private var lastFrame: CGRect?

    func body(content: Content) -> some View {
        let active = scope?.focused == id
        content
            .id(id)
            .focusGlow(active && glow, radius: radius, scale: scale)
            .onChange(of: active) { _, now in
                guard now else { return }
                if NavHub.shared.pointerFocusID == id { NavHub.shared.pointerFocusID = nil; return }     // hovered, not chosen: the glow only
                onFocus?()
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                lastFrame = frame
                if enabled { scope?.register(id, frame: frame, action: action, secondary: secondary, adjust: adjust, label: label, secondaryLabel: secondaryLabel, engageToAdjust: engageToAdjust) }
            }
            .onChange(of: secondaryLabel) { _, _ in if enabled, let lastFrame { scope?.register(id, frame: lastFrame, action: action, secondary: secondary, adjust: adjust, label: label, secondaryLabel: secondaryLabel, engageToAdjust: engageToAdjust) } }
            .onChange(of: enabled) { _, now in
                if now, let lastFrame { scope?.register(id, frame: lastFrame, action: action, secondary: secondary, adjust: adjust, label: label, secondaryLabel: secondaryLabel, engageToAdjust: engageToAdjust) } else { scope?.unregister(id) }
            }
            .onDisappear { scope?.unregister(id) }
            .simultaneousGesture(TapGesture().onEnded { NavHub.shared.pointerFocusID = nil; scope?.focus(id); onFocus?() })     // a click chooses
            .onHover { inside in
                guard inside, NavHub.shared.pointerMayMoveFocus, scope?.focused != id else { return }
                NavHub.shared.pointerFocusID = id
                scope?.focus(id)
                // If the glow was already there nothing changes and the mark would wait for a later controller move: drop it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if NavHub.shared.pointerFocusID == id { NavHub.shared.pointerFocusID = nil } }
            }
    }
}

private struct EdgeSwipeBackModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            // A thin strip at the very edge (past the notch's inset too) that only listens for a drag to the right; everything else keeps its own touches.
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .global).onEnded { drag in
                    guard drag.translation.width > 60, abs(drag.translation.height) < drag.translation.width * 0.8 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    NavHub.shared.swipeBack()
                })
                .ignoresSafeArea()
        }
    }
}

private struct NavBackModifier: ViewModifier {
    let handler: () -> Bool
    @State private var token = UUID()
    @Environment(\.focusScope) private var scope
    func body(content: Content) -> some View {
        content
            .onAppear { scope?.addBack(token, handler) }
            .onDisappear { scope?.removeBack(token) }
    }
}

/// A scroll view that follows the focus: when the D-pad moves to something out of sight, it scrolls it into view.
struct FocusScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    @ViewBuilder var content: Content
    @Environment(\.focusScope) private var scope

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axes, showsIndicators: false) { content.background(PointerScroll()) }
                .onChange(of: scope?.scrollTick) { _, _ in
                    if let id = scope?.scrollRequest { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                }
        }
    }
}

// MARK: - Input

/// Reads game controllers and a hardware keyboard and turns them into navigation commands.
@MainActor @Observable
final class ControllerInput {
    static let shared = ControllerInput()
    private(set) var connected = false
    /// What kind of controller is in use (PlayStation, Xbox, Nintendo...), so guides can name its buttons as they are printed on it.
    private(set) var kind: ControllerKind = .none
    private var started = false
    @ObservationIgnored private var repeater = NavRepeater()
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    /// Controllers whose buttons are wired up, so one that announces itself twice (or becomes current later) is not wired twice.
    @ObservationIgnored private var wired: Set<ObjectIdentifier> = []

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        }
        center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let controller = note.object as? GCController { self?.wired.remove(ObjectIdentifier(controller)) }
                self?.connected = !GCController.controllers().isEmpty
                self?.updateKind()
                self?.releaseAll()
            }
        }
        for c in GCController.controllers() { attach(c) }
        updateKind()
        // The keyboard's one key handler belongs to HardwareInput: while a game runs its keys go to the game, otherwise they come back here (navigate).
        HardwareInput.shared.navKey = { [weak self] code in MainActor.assumeIsolated { self?.navigate(code) } }
        HardwareInput.shared.start()
        // The app going to the background (or a game starting) must not leave a direction held.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.releaseAll() } }
        }
        GCController.startWirelessControllerDiscovery {}
    }

    private func send(_ command: NavCommand) { NavHub.shared.dispatch(command) }

    /// Looks at the connected controllers again: which kind the person is using (the one used last, else the first).
    private func updateKind() {
        let now = ControllerKind.current()?.kind ?? .none
        if now != kind {
            kind = now
            LogStore.shared.log("[pad] controller in use: \(now.displayName)")
        }
    }

    /// Stops any held direction (a pad that disconnects with a button down never reports the release).
    func releaseAll() {
        repeater.reset()
        repeatTask?.cancel(); repeatTask = nil
    }

    /// A controller can announce itself before its extended profile exists; try again for a few seconds instead of never wiring it.
    private func attach(_ controller: GCController, attempt: Int = 0) {
        connected = true
        guard !wired.contains(ObjectIdentifier(controller)) else { return }
        guard let pad = controller.extendedGamepad else {
            if attempt < 20 { Task { @MainActor [weak self] in try? await Task.sleep(for: .milliseconds(300)); self?.attach(controller, attempt: attempt + 1) } }
            return
        }
        wired.insert(ObjectIdentifier(controller))
        updateKind()
        // Handlers run on the main queue (the default handlerQueue), so a press is delivered in the order it happened.
        func press(_ button: GCControllerButtonInput?, _ command: NavCommand) {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { MainActor.assumeIsolated { self?.send(command) } } }
        }
        press(pad.buttonA, .select); press(pad.buttonB, .back); press(pad.buttonX, .secondary); press(pad.buttonY, .tertiary)
        press(pad.leftShoulder, .previousSection); press(pad.rightShoulder, .nextSection); press(pad.buttonMenu, .menu)
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.step(self?.repeater.updateDPad(x: x, y: y, now: Self.now) ?? []) } }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.step(self?.repeater.updateStick(x: x, y: y, now: Self.now) ?? []) } }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Sends the steps a push produced and keeps the repeat clock running while a direction is held.
    private func step(_ directions: [NavDirection]) {
        for d in directions { send(.move(d)) }
        guard repeater.isHolding else { repeatTask?.cancel(); repeatTask = nil; return }
        guard repeatTask == nil else { return }
        repeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.repeater.isHolding {
                try? await Task.sleep(for: .milliseconds(20))
                for d in self.repeater.tick(now: Self.now) { self.send(.move(d)) }
            }
            self?.repeatTask = nil
        }
    }

    /// A key press from a keyboard, outside a game (or while the in-game menu is open): the app's own screens move with it.
    private func navigate(_ code: GCKeyCode) {
        let command: NavCommand?
        switch code {
        case .upArrow: command = .move(.up)
        case .downArrow: command = .move(.down)
        case .leftArrow: command = .move(.left)
        case .rightArrow: command = .move(.right)
        case .returnOrEnter, .spacebar: command = .select
        case .escape, .deleteOrBackspace: command = .back
        case .openBracket: command = .previousSection
        case .closeBracket: command = .nextSection
        default: command = nil
        }
        if let command { send(command) }
    }
}
