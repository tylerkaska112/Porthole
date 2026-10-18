// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit
import GameController
import SwiftUI
import Combine

/// A movement stick that holds W/A/S/D (eight directions, so diagonals work).
final class MovementStickView: UIView {
    private let base = CAShapeLayer(), knob = CAShapeLayer()
    private var held: Set<Int32> = []
    private var tracking: UITouch?
    private let side: CGFloat

    /// `MovementStickView()` goes through UIView.init() -> init(frame:), so that path must work (a trap here crashed every game launch in 0.14.0).
    override init(frame: CGRect) { side = 104; super.init(frame: frame); setup() }
    init(side: CGFloat) { self.side = side; super.init(frame: .zero); setup() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        base.fillColor = UIColor(white: 0, alpha: 0.35).cgColor
        base.strokeColor = UIColor(white: 1, alpha: 0.5).cgColor; base.lineWidth = 2
        knob.fillColor = UIColor(white: 1, alpha: 0.55).cgColor
        layer.addSublayer(base); layer.addSublayer(knob)
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        base.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
        moveKnob(to: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func moveKnob(to p: CGPoint) {
        let r: CGFloat = side * 0.19
        knob.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).cgPath
    }

    private func update(with p: CGPoint) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var dx = p.x - c.x, dy = p.y - c.y
        let radius = side / 2, length = hypot(dx, dy)
        if length > radius { dx *= radius / length; dy *= radius / length }
        moveKnob(to: CGPoint(x: c.x + dx, y: c.y + dy))
        let dead = radius * 0.3
        var now: Set<Int32> = []
        if dy < -dead { now.insert(VK.w) }
        if dy > dead { now.insert(VK.s) }
        if dx < -dead { now.insert(VK.a) }
        if dx > dead { now.insert(VK.d) }
        for k in held.subtracting(now) { HUDKeys.up(k) }
        for k in now.subtracting(held) { HUDKeys.down(k) }
        held = now
    }

    private func end() {
        for k in held { HUDKeys.up(k) }
        held = []; tracking = nil
        moveKnob(to: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking == nil, let t = touches.first else { return }
        tracking = t; update(with: t.location(in: self))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = tracking, touches.contains(t) { update(with: t.location(in: self)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { end() } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { end() } }
    func release() { end() }
}

/// A round button that holds a mouse button while the finger is down. Relative events (no ABSOLUTE flag), so the cursor does not jump:
/// first-person games read the mouse as movement.
final class MouseHoldButton: UIButton {
    private let down: UInt32, up: UInt32
    init(_ title: String, right: Bool, side: CGFloat) {
        down = right ? 0x8 : 0x2; up = right ? 0x10 : 0x4
        super.init(frame: .zero)
        setTitle(title, for: .normal); setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 15, weight: .heavy)
        backgroundColor = UIColor(white: 0, alpha: 0.55); layer.cornerRadius = side / 2
        layer.borderWidth = 2; layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        addAction(UIAction { [weak self] _ in self?.press() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.release() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError() }
    private var isPressed = false
    private func press() { isPressed = true; backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8); winios_pointer(0, 0, down, 0) }
    func release() { guard isPressed else { return }; isPressed = false; backgroundColor = UIColor(white: 0, alpha: 0.55); winios_pointer(0, 0, up, 0) }
}

/// A container that is transparent to touches: points on empty parts fall through to the views below it. (A plain full-screen UIView claims every
/// point, so it shadowed the top-bar buttons underneath: they never received a touch.)
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }
}

/// Everything drawn over the game: top bar, telemetry, movement stick and key panel. It lives at window level above the Metal view; only the
/// controls take touches, everything else falls through to the game surface underneath.
final class GameHUDView: UIView {
    /// Diagnostics shown in the full readout: how often the HUD was told something, and how often it really changed.
    static var stateCalls = 0, stateChanges = 0, attaches = 0
    private var lastState: SessionController.State?
    /// A controller in use hides the on-screen controls (setting "Hide on-screen controls when a controller is used"); a touch on the screen brings them back
    /// until the controller is used again.
    private var hiddenByPad = false
    private var lastTouchAt: TimeInterval = 0
    private var padWatch: Timer?
    func noteTouch() {
        lastTouchAt = ProcessInfo.processInfo.systemUptime
        if hiddenByPad { hiddenByPad = false; refreshControlVisibility() }
    }
    private func watchPad() {
        let now = ProcessInfo.processInfo.systemUptime
        let enabled = EngineOptions.value("env.PORTHOLE_HIDE_TOUCH_ON_PAD") != "0"
        let activity = PadInput.shared.lastActivity
        let want = enabled && lastState == .running && layoutEditor.isHidden && activity > 0 && activity > lastTouchAt && now - activity < 3600
            && !GCController.controllers().isEmpty
        if want != hiddenByPad { hiddenByPad = want; refreshControlVisibility() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        padWatch?.invalidate(); padWatch = nil
        guard window != nil else { return }
        padWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.watchPad() }
    }
    static let shared = GameHUDView(frame: .zero)
    var onClose: (() -> Void)?
    var onBack: (() -> Void)?
    var onKeyboard: (() -> Void)?
    /// Opens the compatibility report form for the running game. nil (an installer, say) hides the menu entry.
    var onReport: (() -> Void)? { didSet { menuModel.hasReport = onReport != nil } }
    /// Switches the touch layout while playing (mouse and keys <-> first person); the session remembers the choice for this game.
    var onSwitchLayout: ((ControlLayout) -> Void)?
    /// Where the last touch landed on the game (Wine desktop pixels); the zoom buttons scroll the wheel there.
    var cursor: (x: Int32, y: Int32) = (640, 360)
    /// "Right mode": tap and drag use the right button, two-finger tap the left.
    private(set) var rightMode = false

    // The in-game menu (a side panel) and the performance overlay, both SwiftUI, hosted above the controls.
    private let menuModel = GameMenuModel()
    /// The running game's name, for the menu's header.
    var gameName: String? { didSet { menuModel.gameName = gameName } }
    /// The running game's Steam app id (nil for a game that is not from Steam), for the menu's Workshop tab.
    var steamAppID: Int? { didSet { menuModel.steamAppID = steamAppID } }
    private let perfModel = PerfOverlayModel()
    private var overlayWatch: AnyCancellable?
    private var overlayConstraints: [NSLayoutConstraint] = []
    private var fenceMode = Int(EngineOptions.value("fence-chain")) ?? 1
    private lazy var menuHost: UIView = {
        let v = UIHostingConfiguration { GameMenuView(model: self.menuModel, overlay: PerfOverlaySettings.shared) }.margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isHidden = true; v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private lazy var toastHost: UIView = {
        let v = UIHostingConfiguration { AchievementToastView() }.margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isUserInteractionEnabled = false; v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private lazy var perfHost: UIView = {
        let v = UIHostingConfiguration { PerfOverlayView(settings: PerfOverlaySettings.shared, model: self.perfModel) }.margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isHidden = true; v.isUserInteractionEnabled = false; v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let message = UILabel()
    private let bar = UIStackView()
    private let controls = PassthroughView()
    /// A bind set's touch layout (BindSets.swift): when one is in use it replaces the built-in controls below.
    private let customControls = CustomControlsView()
    private var customLayout: TouchLayout?
    private lazy var layoutEditor = ControlsEditorView(controls: customControls)
    /// The arrow for a controller that drives the mouse; the session view says where the game's screen is.
    let padPointer = PadPointerView()
    private let editButton = UIButton(type: .system)      // the pencil, always on screen while a game runs
    private let keyboardButton = UIButton(type: .system)  // opens the keyboard without going through the menu
    private var topColumn: UIStackView?
    private var wantsEditAfterCreate = false
    /// The in-game editor (the menu): open the full bind editor over the game, a new set was wanted from a starting layout, and a layout changed on screen.
    var onEditBinds: (() -> Void)?
    var onCreateLayout: ((TouchLayout) -> Void)? { didSet { _ = oldValue } }
    var onLayoutChanged: ((TouchLayout) -> Void)? { didSet { customControls.onChange = onLayoutChanged } }
    /// The look button of a custom layout flips this; the layout's own "Look" setting (the editor's Look on/off) is the starting point and is never changed by it.
    private var customLookFlipped = false
    private var customLook: Bool { customLayout.map { $0.look != customLookFlipped } ?? false }
    private let fpControls = PassthroughView()          // the first-person layout
    private let stick = MovementStickView()
    private let fpStick = MovementStickView(side: 120)
    private var fpHolds: [MouseHoldButton] = []
    private var fpKeys: [KeyButton] = []
    private(set) var layout: ControlLayout = .standard
    /// First person: false = drag on the screen looks around; true = the screen behaves as a normal mouse (menus).
    private(set) var cursorMode = false
    /// Look speed (points -> mouse counts) and the callback the menu buttons use to change it.
    var lookSensitivity: CGFloat = 2.4 { didSet { menuModel.lookSpeed = Double(lookSensitivity); menuModel.showLookSpeed = layout == .firstPerson || customLook } }
    var onAdjustLook: (Double) -> Void = { _ in }
    /// Touches on the game should turn into mouse LOOK movement instead of clicks.
    var lookActive: Bool { (layout == .firstPerson && !cursorMode) || customLook }
    private let cursorToggle = KeyButton("Look", .tap(0), side: 46)
    private let panel = UIStackView()          // the on-demand "More" keys
    private let quick = UIStackView()          // the always-visible E / F / Tab / Esc
    private var latches: [KeyButton] = []
    private var controlsOn = true
    private var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            if menuOpen {
                refreshMenuModel()
                menuHost.isHidden = false
                menuHost.isUserInteractionEnabled = true
            }
            menuModel.isPresented = menuOpen
            NavHub.shared.gameMenuOpen = menuOpen
            PadInput.shared.setCaptured(menuOpen)
            if !menuOpen { menuModel.openedByPad = false }
            refreshHandle(pulse: false)
            if !menuOpen {
                // Hide the host once the panel has slid out; a reopen in the meantime keeps it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.menuOpen else { return }
                    self.menuHost.isHidden = true; self.menuHost.isUserInteractionEnabled = false
                }
            }
        }
    }
    private var moreOpen = false { didSet { panel.isHidden = !moreOpen; moreButton.backgroundColor = moreOpen ? UIColor.systemBlue.withAlphaComponent(0.85) : UIColor(white: 0, alpha: 0.55) } }
    private let moreButton = KeyButton("•••", .tap(0), side: 46)
    private let mouse = KeyButton("Right mode", .tap(0))
    private let back = GameHUDView.barButton("Back to library")

    private static func barButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal); b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.backgroundColor = UIColor(white: 0, alpha: 0.55); b.layer.cornerRadius = 8
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return b
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        padPointer.frame = bounds; padPointer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layer.zPosition = 10_000        // draws above the game's own view even before the window's order is corrected
        addSubview(padPointer)
        buildTopBar(); buildControls(); buildFirstPerson(); buildCustomControls()
        NotificationCenter.default.addObserver(forName: PowerManager.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshPower() }
        // The controller's menu chord (PadChord.swift) opens and closes the menu; the pad is then the menu's, not the game's.
        NotificationCenter.default.addObserver(forName: .padMenuChord, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.menuOpen { self.menuOpen = false } else { self.menuModel.openedByPad = true; self.menuOpen = true }
        }
        // The game asked for Steam's overlay (its Workshop button, Shift+Tab): its own window cannot draw here, so the Steam menu opens instead, and an Escape press
        // closes the overlay's empty screen, which has taken the game's input (until then the game does not answer).
        NotificationCenter.default.addObserver(forName: .steamOverlayRequested, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.menuAvailable else { return }
            self.menuModel.steamAppID != nil ? (self.menuModel.tab = .steam) : ()
            self.menuModel.requestedSteamSection = "workshop"
            self.menuModel.openedByPad = false
            self.menuOpen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { HUDKeys.tap(VK.esc) }
        }
        buildMenuAndOverlay()
        update(state: .starting)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildTopBar() {
        message.textColor = .white; message.numberOfLines = 0; message.font = .systemFont(ofSize: 15, weight: .medium)
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)

        // `bar` is the always-present top row: the pencil and the keyboard button. The menu opens with a swipe in from the right edge.
        editButton.setImage(UIImage(systemName: "pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        editButton.tintColor = .white; editButton.backgroundColor = UIColor(white: 0, alpha: 0.55); editButton.layer.cornerRadius = 8
        editButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        editButton.accessibilityLabel = "Edit the on-screen controls"; editButton.isHidden = true
        editButton.addAction(UIAction { [weak self] _ in self?.beginLayoutEditing() }, for: .touchUpInside)
        editButton.addAction(UIAction { [weak self] _ in self?.refreshHandle(pulse: false) }, for: .touchDown)
        keyboardButton.setImage(UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        keyboardButton.tintColor = .white; keyboardButton.backgroundColor = UIColor(white: 0, alpha: 0.55); keyboardButton.layer.cornerRadius = 8
        keyboardButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        keyboardButton.accessibilityLabel = "Keyboard"; keyboardButton.isHidden = true
        keyboardButton.addAction(UIAction { [weak self] _ in self?.menuOpen = false; self?.onKeyboard?() }, for: .touchUpInside)
        keyboardButton.addAction(UIAction { [weak self] _ in self?.refreshHandle(pulse: false) }, for: .touchDown)
        [editButton, keyboardButton].forEach(bar.addArrangedSubview)
        bar.axis = .horizontal; bar.spacing = 6; bar.alignment = .top

        let column = UIStackView(arrangedSubviews: [message, bar, back]); topColumn = column
        column.axis = .vertical; column.alignment = .leading; column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
                                     column.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),   // long status text wraps instead of running off screen
                                     column.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8)])
    }

    private func buildControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     controls.topAnchor.constraint(equalTo: topAnchor), controls.bottomAnchor.constraint(equalTo: bottomAnchor)])

        stick.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stick)
        NSLayoutConstraint.activate([stick.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
                                     stick.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -56)])

        func row(_ buttons: [UIButton]) -> UIStackView { let s = UIStackView(arrangedSubviews: buttons); s.axis = .horizontal; s.spacing = 5; s.distribution = .fillEqually; return s }
        func letters(_ chars: String) -> [UIButton] { chars.map { KeyButton(String($0), .tap(VK.letter($0))) } }

        // Always visible: E (inventory), F, Tab, Esc, and the button that opens the rest.
        func quickKey(_ title: String, _ vk: Int32) -> UIButton { KeyButton(title, .tap(vk), side: 46) }
        let r1 = row([moreButton, quickKey("Tab", VK.tab), quickKey("Esc", VK.esc)])
        let r2 = row([quickKey("F", VK.letter("F")), quickKey("E", VK.letter("E"))])
        r1.distribution = .fill; r2.distribution = .fill
        [r1, r2].forEach(quick.addArrangedSubview)
        quick.axis = .vertical; quick.spacing = 6; quick.alignment = .trailing
        moreButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.moreOpen.toggle() }, for: .touchUpInside)

        // On demand: everything else. (No number keys: the quickbar is tapped on screen.)
        let shift = KeyButton("Shift", .latch(VK.shift)), ctrl = KeyButton("Ctrl", .latch(VK.ctrl)), alt = KeyButton("Alt", .latch(VK.alt))
        latches = [shift, ctrl, alt]
        mouse.addAction(UIAction { [weak self] _ in self?.toggleMouse() }, for: .touchUpInside)
        let zoomIn = KeyButton("Zoom +", .tap(0)), zoomOut = KeyButton("Zoom -", .tap(0))
        zoomIn.addAction(UIAction { [weak self] _ in self?.wheel(120) }, for: .touchUpInside)
        zoomOut.addAction(UIAction { [weak self] _ in self?.wheel(-120) }, for: .touchUpInside)
        let rows: [UIStackView] = [
            row([mouse, zoomIn, zoomOut]),
            row(letters("QRTMG")),
            row([KeyButton("Space", .hold(VK.space)), shift, ctrl, alt, KeyButton("Enter", .tap(VK.enter)), KeyButton("Del", .tap(VK.backspace))]),
        ]
        rows.forEach(panel.addArrangedSubview)
        panel.axis = .vertical; panel.spacing = 5; panel.alignment = .fill; panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        quick.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(panel); controls.addSubview(quick)
        NSLayoutConstraint.activate([quick.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
                                     quick.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -14),
                                     panel.trailingAnchor.constraint(equalTo: quick.trailingAnchor),
                                     panel.bottomAnchor.constraint(equalTo: quick.topAnchor, constant: -8),
                                     panel.widthAnchor.constraint(lessThanOrEqualToConstant: 400)])
    }

    private func buildFirstPerson() {
        fpControls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fpControls)
        NSLayoutConstraint.activate([fpControls.leadingAnchor.constraint(equalTo: leadingAnchor), fpControls.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     fpControls.topAnchor.constraint(equalTo: topAnchor), fpControls.bottomAnchor.constraint(equalTo: bottomAnchor)])
        fpStick.translatesAutoresizingMaskIntoConstraints = false
        fpControls.addSubview(fpStick)
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([fpStick.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28), fpStick.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -40)])

        func key(_ title: String, _ behavior: KeyButton.Behavior, _ side: CGFloat = 54) -> KeyButton {
            let b = KeyButton(title, behavior, side: side); fpKeys.append(b); return b
        }
        let fire = MouseHoldButton("FIRE", right: false, side: 76), alt = MouseHoldButton("ALT", right: true, side: 76)
        fpHolds = [fire, alt]
        let jump = key("Jump", .hold(VK.space), 60), crouch = key("Duck", .hold(VK.ctrl)), use = key("Use", .tap(VK.letter("E"))), sprint = key("Run", .hold(VK.shift))
        let reload = key("R", .tap(VK.letter("R")), 46), esc = key("Esc", .tap(VK.esc), 46), tab = key("Tab", .tap(VK.tab), 46)

        // Right thumb: fire / alt-fire on the bottom row, jump and use above them.
        let bottom = UIStackView(arrangedSubviews: [alt, fire]); bottom.spacing = 14; bottom.alignment = .center
        let upper = UIStackView(arrangedSubviews: [use, jump]); upper.spacing = 14; upper.alignment = .center
        let thumb = UIStackView(arrangedSubviews: [upper, bottom]); thumb.axis = .vertical; thumb.alignment = .trailing; thumb.spacing = 14
        // Beside the stick: duck and run.
        let legs = UIStackView(arrangedSubviews: [sprint, crouch]); legs.axis = .vertical; legs.spacing = 12; legs.alignment = .center
        // Top right: the rarely needed ones.
        cursorToggle.addAction(UIAction { [weak self] _ in self?.toggleCursorMode() }, for: .touchUpInside)
        let top = UIStackView(arrangedSubviews: [reload, tab, esc, cursorToggle]); top.spacing = 10; top.alignment = .center
        for v in [thumb, legs, top] { v.translatesAutoresizingMaskIntoConstraints = false; fpControls.addSubview(v) }
        NSLayoutConstraint.activate([
            thumb.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -22), thumb.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -22),
            legs.leadingAnchor.constraint(equalTo: fpStick.trailingAnchor, constant: 14), legs.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -40),
            top.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16), top.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
        ])
        fpControls.isHidden = true
    }

    private func buildCustomControls() {
        customControls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(customControls)
        NSLayoutConstraint.activate([customControls.leadingAnchor.constraint(equalTo: leadingAnchor), customControls.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     customControls.topAnchor.constraint(equalTo: topAnchor), customControls.bottomAnchor.constraint(equalTo: bottomAnchor)])
        customControls.isHidden = true
        customControls.lookProvider = { [weak self] in self?.customLook ?? false }
        customControls.onToggleLook = { [weak self] in self?.customLookFlipped.toggle() }
        layoutEditor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layoutEditor)
        NSLayoutConstraint.activate([layoutEditor.leadingAnchor.constraint(equalTo: leadingAnchor), layoutEditor.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     layoutEditor.topAnchor.constraint(equalTo: topAnchor), layoutEditor.bottomAnchor.constraint(equalTo: bottomAnchor)])
        layoutEditor.onDone = { [weak self] in self?.endLayoutEditing() }
    }

    /// The pencil: edits the on-screen controls right on the game. With no custom layout yet, one is made from the layout in use (mouse and keys or first person) and used,
    /// then editing starts at once; nothing else is asked.
    func beginLayoutEditing() {
        menuOpen = false
        guard lastState == .running else { return }
        if customLayout == nil {
            wantsEditAfterCreate = true
            onCreateLayout?(layout == .firstPerson ? .firstPerson : .mouseAndKeys)
            return
        }
        startEditing()
    }

    private func startEditing() {
        controlsOn = true
        refreshControlVisibility()
        topColumn?.isHidden = true                 // the editor has its own bar; the game's top-left stack would sit under it
        editButton.isHidden = true; keyboardButton.isHidden = true
        layoutEditor.setActive(true)
    }

    func endLayoutEditing() {
        layoutEditor.setActive(false)
        topColumn?.isHidden = false
        refreshControlVisibility()
        refreshHandle(pulse: false)
    }

    /// The touch layout of the bind set in use (nil = the game's normal Controls choice).
    func setCustomLayout(_ new: TouchLayout?) {
        guard new != customLayout else { return }
        if new?.look != customLayout?.look { customLookFlipped = false }          // the layout's own setting changed: start from it
        customLayout = new
        customControls.apply(new)
        menuModel.customLayoutInUse = new != nil          // the built-in layouts are not in use while a set's layout is
        if new == nil { cursorMode = false }
        refreshControlVisibility()
        if wantsEditAfterCreate, new != nil { wantsEditAfterCreate = false; startEditing() }
        if new == nil, layoutEditor.isHidden == false { endLayoutEditing() }
    }

    private func toggleCursorMode() {
        cursorMode.toggle()
        cursorToggle.setTitle(cursorMode ? "Menu" : "Look", for: .normal)
        cursorToggle.backgroundColor = cursorMode ? UIColor.systemBlue.withAlphaComponent(0.85) : UIColor(white: 0, alpha: 0.55)
    }

    func setLayout(_ l: ControlLayout) {
        guard l != layout else { return }
        layout = l
        menuModel.layout = l
        menuModel.showLookSpeed = l == .firstPerson || customLook
        if l != .firstPerson { cursorMode = false; cursorToggle.setTitle("Look", for: .normal); cursorToggle.backgroundColor = UIColor(white: 0, alpha: 0.55) }
        refreshControlVisibility()
    }

    private func refreshControlVisibility() {
        let on = lastState == .running && controlsOn && !hiddenByPad
        controls.isHidden = !(on && layout == .standard && customLayout == nil)
        fpControls.isHidden = !(on && layout == .firstPerson && customLayout == nil)
        customControls.isHidden = !(on && customLayout != nil)
        if !(on && customLayout != nil) { customControls.release() }
        editButton.isHidden = !(lastState == .running) || !layoutEditor.isHidden
        keyboardButton.isHidden = editButton.isHidden
        if !on || layout != .firstPerson || customLayout != nil { fpStick.release(); fpHolds.forEach { $0.release() } }
    }

    // MARK: Behaviour

    private func showHelp() {
        let alert = UIAlertController(title: "Touch controls", message: """
            Tap: left click
            Drag: left button held (belts, selections)
            Press and hold: right button held (mine, remove)
            Two-finger tap: right click
            Pinch: zoom
            Stick: W A S D
            E / F / Tab / Esc: always on screen; ••• opens more keys
            Right mode (under •••): tap and drag use the right button
            Shift / Ctrl / Alt: tap once to hold, again to release
            """, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(alert, animated: true)
    }

    private func toggleControls() { controlsOn.toggle(); refreshControlVisibility(); menuModel.controlsShown = controlsOn }

    private func toggleMouse() {
        rightMode.toggle()
        mouse.setTitle(rightMode ? "Right mode: ON" : "Right mode", for: .normal)
        mouse.backgroundColor = rightMode ? UIColor.systemOrange.withAlphaComponent(0.85) : UIColor(white: 0, alpha: 0.55)
    }

    private func wheel(_ delta: Int32) { winios_pointer(cursor.x, cursor.y, 0x800, UInt32(bitPattern: delta)) }

    /// Only the controls are interactive; everything else falls through to the game surface.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let v = super.hitTest(point, with: event) else { return nil }
        if !layoutEditor.isHidden, v.isDescendant(of: layoutEditor) { return v }
        if !menuHost.isHidden, v.isDescendant(of: menuHost) { return v }          // the open menu takes every touch, so none reach the game
        return (v is UIControl || v is MovementStickView || v is CustomStick || v is CustomControlsView) ? v : nil
    }

    // MARK: Menu and performance overlay

    /// Puts the two SwiftUI views over the controls and connects the menu's actions to what the HUD already does.
    private func buildMenuAndOverlay() {
        let m = menuModel
        m.dismiss = { [weak self] in self?.menuOpen = false }
        m.setPower = { PowerManager.shared.setForSession($0) }
        m.setPadMode = { [weak self] mode in AppModel.shared.session.setPadMode(mode); self?.refreshMenuModel() }
        m.setEco = { [weak self] on in
            madeira_set_eco(on ? 1 : 0)
            LogStore.shared.log("[eco] \(on ? "on" : "off") from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setFrameGen = { [weak self] on in
            let hz = Double(UIScreen.main.maximumFramesPerSecond)
            madeira_framegen_set(on ? 1 : 0, hz)
            ProMotionHold.shared.setFrameGeneration(on)
            LogStore.shared.log("[framegen] \(on ? "on" : "off") from the in-game menu (screen \(Int(hz)) Hz)")
            self?.refreshMenuModel()
        }
        m.setFence = { [weak self] mode in
            madeira_set_fence_mode(Int32(mode == 0 ? 7 : mode))
            self?.fenceMode = mode
            LogStore.shared.log("[gpu-sync] mode F\(mode) from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setLayout = { [weak self] l in guard let self, l != self.layout else { return }; self.onSwitchLayout?(l) }
        m.setControlsShown = { [weak self] on in guard let self, on != self.controlsOn else { return }; self.toggleControls() }
        m.adjustLook = { [weak self] factor in self?.onAdjustLook(factor) }
        m.openKeyboard = { [weak self] in self?.menuOpen = false; self?.onKeyboard?() }
        m.openBinds = { [weak self] in self?.menuOpen = false; self?.onEditBinds?() }
        m.editControls = { [weak self] in self?.beginLayoutEditing() }
        m.report = { [weak self] in self?.menuOpen = false; self?.onReport?() }
        m.help = { [weak self] in self?.menuOpen = false; self?.showHelp() }
        m.captureFrame = { [weak self] in
            self?.menuOpen = false
            // After the menu has closed, so the captured frame is the game and not the menu.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { madeira_capture_request(1); LogStore.shared.log("[capture] frame capture requested from the in-game menu") }
        }
        m.profile = { [weak self] in
            guard sample_profiler_running() == 0 else { return }
            self?.menuOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                LogStore.shared.log("[prof] profile of 30 s started from the in-game menu")
                if sample_profiler_start(30, 200, nil) == 0 { self?.watchProfile() }
            }
        }
        m.closeGame = { [weak self] in self?.menuOpen = false; self?.onClose?() }
        m.restartGame = { [weak self] in
            self?.menuOpen = false
            let session = AppModel.shared.session
            if let game = session.game { RestartCoordinator.shared.restart(game, session: session) }
        }
        m.hasReport = onReport != nil
        m.setHandleStyle = { [weak self] style in
            UserDefaults.standard.set(style.rawValue, forKey: MenuHandleStyle.key)
            self?.menuModel.handleStyle = style
        }
        buildHandle()

        addSubview(perfHost); addSubview(menuHost)
        NSLayoutConstraint.activate([menuHost.leadingAnchor.constraint(equalTo: leadingAnchor), menuHost.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     menuHost.topAnchor.constraint(equalTo: topAnchor), menuHost.bottomAnchor.constraint(equalTo: bottomAnchor)])
        addSubview(toastHost)
        NSLayoutConstraint.activate([toastHost.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor), toastHost.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
                                     toastHost.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), toastHost.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)])
        placeOverlay()
        applyOverlaySettings()
        overlayWatch = PerfOverlaySettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyOverlaySettings() }
        }
    }

    // MARK: Opening the menu

    /// The swipe in from the right edge (GameSurfaceView) or a tap on the handle.
    func openMenu() {
        guard menuAvailable else { return }
        menuOpen = true
    }
    var menuAvailable: Bool { lastState == .running && layoutEditor.isHidden }
    /// The handle sits in the middle of the right edge; a tap within this band of it opens the menu too (point in the HUD's coordinates).
    func handleBand(contains p: CGPoint) -> Bool { abs(p.y - bounds.midY) < 70 }

    // MARK: The profile indicator
    /// A pill at the top of the screen while "Profile where the time goes" runs: counts down, says when the result is being worked out and when it is in the log.
    private final class PaddedLabel: UILabel {
        override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12))) }
        override var intrinsicContentSize: CGSize { let s = super.intrinsicContentSize; return CGSize(width: s.width + 24, height: s.height + 10) }
    }
    private lazy var profileBadge: PaddedLabel = {
        let l = PaddedLabel()
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold); l.textColor = .white; l.textAlignment = .center
        l.layer.cornerRadius = 14; l.clipsToBounds = true; l.isHidden = true; l.isUserInteractionEnabled = false
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: centerXAnchor), l.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6)])
        return l
    }()
    private var profileWatchTimer: Timer?
    private var profileDoneAt: Date?
    private func watchProfile() {
        profileWatchTimer?.invalidate(); profileDoneAt = nil
        profileWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateProfileBadge() }
        updateProfileBadge()
    }
    private func updateProfileBadge() {
        var elapsed = 0.0, length = 0.0
        let phase = sample_profiler_status(&elapsed, &length)
        switch phase {
        case 1:
            profileBadge.text = String(format: "PROFILING  %.0f s left", max(0, length - elapsed))
            profileBadge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.88)
            profileBadge.isHidden = false
        case 2:
            profileBadge.text = "Profile done, working out the result..."
            profileBadge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.9)
            profileBadge.isHidden = false
        case 3:
            if profileDoneAt == nil { profileDoneAt = Date() }
            profileBadge.text = "Profile done: the result is in the log"
            profileBadge.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
            profileBadge.isHidden = false
            if Date().timeIntervalSince(profileDoneAt!) > 8 {
                profileBadge.isHidden = true; profileWatchTimer?.invalidate(); profileWatchTimer = nil
            }
        default:
            profileBadge.isHidden = true; profileWatchTimer?.invalidate(); profileWatchTimer = nil
        }
        bringSubviewToFront(profileBadge)
    }

    private let handle = UIView()
    private var handleFade: DispatchWorkItem?
    private func buildHandle() {
        handle.backgroundColor = .white; handle.layer.cornerRadius = 2.5; handle.alpha = 0
        handle.isUserInteractionEnabled = false
        handle.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(handle, at: 1)            // below the controls, so a button placed there still works
        NSLayoutConstraint.activate([handle.widthAnchor.constraint(equalToConstant: 5), handle.heightAnchor.constraint(equalToConstant: 56),
                                     handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3), handle.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    /// Shows the handle (after a game starts, after the menu closes, when the style changes) and, in the fading style, dims it again after a moment.
    /// The pencil and keyboard buttons (the top bar) fade with it: bright for a moment, then faint, bright again when touched. They keep working while faint.
    private static let barDimAlpha: CGFloat = 0.22
    private func refreshHandle(pulse: Bool) {
        handleFade?.cancel(); handleFade = nil
        guard menuAvailable, !menuOpen else { UIView.animate(withDuration: 0.2) { self.handle.alpha = 0 }; return }
        let style = menuModel.handleStyle
        switch style {
        case .hidden: UIView.animate(withDuration: 0.2) { self.handle.alpha = 0 }
        case .always: UIView.animate(withDuration: 0.2) { self.handle.alpha = 0.5 }
        case .fade: UIView.animate(withDuration: 0.2) { self.handle.alpha = 0.6 }
        }
        UIView.animate(withDuration: 0.2) { self.bar.alpha = 1 }
        guard style != .always else { return }            // "Always visible" keeps the buttons bright too
        let dim = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 1.2) {
                if style == .fade { self?.handle.alpha = 0.14 }
                self?.bar.alpha = Self.barDimAlpha
            }
        }
        handleFade = dim
        DispatchQueue.main.asyncAfter(deadline: .now() + (pulse ? 4 : 2.5), execute: dim)
    }

    /// Reads the HUD's and the engine's current state into the menu. Runs when the menu opens and when something it shows changes underneath it.
    private func refreshMenuModel() {
        let p = PowerManager.shared
        menuModel.padMode = AppModel.shared.session.game?.engine?.controllerMode
        menuModel.padHidReady = PadInput.shared.hidReady
        menuModel.padKindName = ControllerInput.shared.kind == .none ? "" : ControllerInput.shared.kind.displayName
        menuModel.powerChosen = p.chosen
        menuModel.powerEffective = p.effective
        menuModel.eco = madeira_get_eco() != 0
        menuModel.frameGen = madeira_framegen_get() != 0
        menuModel.fenceMode = fenceMode
        menuModel.layout = layout
        menuModel.customLayoutInUse = customLayout != nil
        menuModel.controlsShown = controlsOn
        menuModel.showLookSpeed = layout == .firstPerson || customLook
        menuModel.lookSpeed = Double(lookSensitivity)
        menuModel.hasReport = onReport != nil
        menuModel.gameName = gameName
    }

    private func refreshPower() { if menuOpen { refreshMenuModel() } }

    /// The most height the overlay's list of numbers should take: about half the screen, so on a small phone it spreads into columns and leaves the game visible.
    private var overlayTallest: CGFloat = 0
    private func updateOverlayRoom() {
        let tallest = max(110, bounds.height * 0.5)
        guard tallest != overlayTallest else { return }
        overlayTallest = tallest
        perfModel.tallest = tallest
    }
    override func layoutSubviews() { super.layoutSubviews(); updateOverlayRoom() }

    /// The overlay's host fills the room on screen (the safe area less a margin, and below the top-left stack when the overlay is in that corner) and the overlay itself
    /// sits in its corner inside it. The host never has to be re-sized when the overlay grows or shrinks, which a host sized to its content did not follow.
    private var overlayCorner: OverlayCorner?
    private func placeOverlay() {
        let corner = PerfOverlaySettings.shared.corner
        guard corner != overlayCorner else { return }
        overlayCorner = corner
        NSLayoutConstraint.deactivate(overlayConstraints)
        let g = safeAreaLayoutGuide
        let top: NSLayoutConstraint = corner == .topLeading
            ? perfHost.topAnchor.constraint(equalTo: (topColumn ?? self).bottomAnchor, constant: 6)
            : perfHost.topAnchor.constraint(equalTo: g.topAnchor, constant: 8)
        overlayConstraints = [perfHost.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12), perfHost.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
                              top, perfHost.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8)]
        NSLayoutConstraint.activate(overlayConstraints)
    }

    /// The overlay settings changed (or the game started or ended): show or hide it, move it, and ask for the slower measurements only when a shown number needs them.
    private func applyOverlaySettings() {
        let settings = PerfOverlaySettings.shared
        placeOverlay()
        perfHost.isHidden = !(settings.enabled && lastState == .running)
        Telemetry.detailWanted = settings.wantsDetail && lastState == .running
        if !perfHost.isHidden { showTelemetry(Telemetry.shared.latest) }
    }

    private func showTelemetry(_ s: TelemetrySample) {
        guard PerfOverlaySettings.shared.enabled else { return }          // nothing draws the numbers while the overlay is off
        perfModel.extra = "Input: \(HUDKeys.sent) keys sent (last \(HUDKeys.last)), \(GameSurfaceView.touchCount) touches\nHUD: \(Self.stateChanges) changes / \(Self.stateCalls) updates, \(Self.attaches) attaches"
        perfModel.push(s)
    }

    private var statusText: String?
    private var statusHide: DispatchWorkItem?

    /// A warning from the game itself (memory nearly full): shown over the game for a while, then cleared.
    func showNotice(_ text: String) {
        guard lastState == .running else { return }
        statusHide?.cancel()
        message.text = text; message.isHidden = false
        let hide = DispatchWorkItem { [weak self] in if self?.lastState == .running { self?.message.isHidden = true } }
        statusHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: hide)
    }

    /// What Valve's client is doing during a Steam launch. Valve's client keeps running for the whole game, so it never says "done" and its last line
    /// (Loading...) would stay over the game forever: each line is shown for a while once the game is running, then cleared. Before the game runs it stays,
    /// because that is when it explains the wait.
    func setStatus(_ text: String?) {
        guard text != statusText else { return }      // SwiftUI repeats the same text on every refresh
        statusText = text
        statusHide?.cancel(); statusHide = nil
        guard let text else { if lastState == .running { message.isHidden = true }; return }
        message.text = text; message.isHidden = false
        let hide = DispatchWorkItem { [weak self] in if self?.lastState == .running { self?.message.isHidden = true } }
        statusHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: hide)
    }

    func update(state: SessionController.State) {
        Self.stateCalls += 1
        guard state != lastState else { return }       // SwiftUI calls this on every refresh; only react to a real change
        lastState = state; Self.stateChanges += 1
        LogStore.shared.log("[f4-hud] state -> \(state)")
        let running = state == .running
        if running {
            Telemetry.shared.onSample = { [weak self] s in self?.showTelemetry(s) }
            Telemetry.shared.onAlert = { [weak self] text in self?.showNotice(text) }
            Telemetry.shared.start()
        } else {
            Telemetry.shared.stop()
            stick.release(); fpStick.release(); fpHolds.forEach { $0.release() }; latches.forEach { $0.release() }
        }
        bar.isHidden = !running
        if !running { menuOpen = false; moreOpen = false; perfModel.reset() }
        refreshControlVisibility()
        applyOverlaySettings()
        refreshHandle(pulse: true)
        switch state {
        case .running:
            back.isHidden = true
            // Anything Valve's client said while starting stays readable for a few seconds, then goes.
            if statusText != nil && !message.isHidden {
                statusHide?.cancel()
                let hide = DispatchWorkItem { [weak self] in if self?.lastState == .running { self?.message.isHidden = true } }
                statusHide = hide
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: hide)
            } else { message.isHidden = true }
        case .ended: message.text = "Game ended. To play another game, close Porthole and open it again. The Home screen has a button for that."; message.isHidden = false; back.isHidden = false
        default: message.text = "Starting..."; message.isHidden = false; back.isHidden = true
        }
    }
}
