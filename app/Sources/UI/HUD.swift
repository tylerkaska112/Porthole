// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit
import GameController
import SwiftUI
import Combine

/// A view that takes touches itself (not a UIControl): the HUD lets a touch on it through instead of passing it to the game. Every interactive control of the HUD that is a plain UIView
/// conforms; forgetting it is how a control draws but never answers (the pad controls of a custom layout did so in 1.3.156 and 1.3.157).
protocol TakesHUDTouches: UIView {}

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
    private var lastState: SessionController.State? { didSet { updateBannerGate(); noteBandControls(); refreshBandOverlay() } }
    /// A controller, keyboard or mouse in use hides the on-screen controls (settings "Hide on-screen controls when a controller is used" and "... a keyboard or mouse");
    /// a touch on the screen brings them back until it is used again.
    private var hiddenByPad = false
    private var lastTouchAt: TimeInterval = 0
    private var padWatch: Timer?
    /// Controls that hide when nothing has touched the screen for a while (the in-game menu's Controls tab: Hide when not touched; TouchAutoHide). A touch anywhere brings them back.
    static let autoHideKey = "f4.controlsAutoHide"
    private var idle = TouchAutoHide()
    private let touchObserver = TouchObserver()
    /// The offer to switch to touch controls when the on-screen game controller is on and the game never asks for a controller (LayoutSuggestion).
    private var suggestion = LayoutSuggestion()
    private var suggestionCard: LayoutSuggestionCard?
    private var lastSuggestionCheck: TimeInterval = 0
    func noteTouch() {
        lastTouchAt = ProcessInfo.processInfo.systemUptime
        if hiddenByPad { hiddenByPad = false; refreshControlVisibility() }
    }
    /// About once a second: has a game that ignores the controller had the on-screen controller on for long enough to make the offer?
    private func checkSuggestion(now: TimeInterval) {
        let gameID = AppModel.shared.session.game?.id.uuidString
        let eligible = lastState == .running && virtualPadOn && GCController.controllers().isEmpty && layoutEditor.isHidden && !menuOpen && suggestionCard == nil
            && gameID.map { LayoutSuggestion.mayAsk(gameID: $0) } == true
        guard suggestion.update(now: now, reads: winios_gamepad_read_count(), eligible: eligible), let gameID else { return }
        showSuggestion(gameID: gameID)
    }

    private func showSuggestion(gameID: String) {
        LayoutSuggestion.remember(gameID: gameID)          // asked once, whatever the answer
        let card = LayoutSuggestionCard(text: LayoutSuggestion.text(gameName: gameName))
        card.onSwitch = { [weak self] in
            guard let self else { return }
            self.suggestionCard = nil
            LogStore.shared.log("[controls] switched from the on-screen controller to touch controls (the offer; the game never read the controller)")
            AppModel.shared.session.setVirtualPad(false)
            self.virtualPadOn = false
            self.controlsOn = true
            self.refreshControlVisibility()
            self.refreshMenuModel()
        }
        card.onDismiss = { [weak self] in self?.suggestionCard = nil }
        suggestionCard = card
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            card.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 56),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        LogStore.shared.log("[controls] the game has not read the controller while the on-screen controller is on: offered touch controls for keyboard and mouse")
    }

    private func watchPad() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSuggestionCheck >= 1 { lastSuggestionCheck = now; checkSuggestion(now: now) }
        idle.seconds = UserDefaults.standard.integer(forKey: Self.autoHideKey)
        if idle.tick(now: now, suspended: lastState != .running || !layoutEditor.isHidden || menuOpen) { refreshControlVisibility() }
        let enabled = EngineOptions.value("env.PORTHOLE_HIDE_TOUCH_ON_PAD") != "0"
        let activity = PadInput.shared.lastActivity
        let padWant = enabled && activity > 0 && activity > lastTouchAt && now - activity < 3600 && !GCController.controllers().isEmpty
        // A keyboard or mouse in use does the same (a touch brings the controls back until the next key or mouse movement).
        let keysActivity = HardwareInput.shared.lastActivity
        let keysWant = EngineOptions.value("env.PORTHOLE_HIDE_TOUCH_ON_KEYS") != "0" && keysActivity > 0 && keysActivity > lastTouchAt && now - keysActivity < 3600
            && (HardwareInput.shared.keyboardConnected || HardwareInput.shared.mouseConnected)
        let want = lastState == .running && layoutEditor.isHidden && (padWant || keysWant)
        if want != hiddenByPad { hiddenByPad = want; refreshControlVisibility() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        padWatch?.invalidate(); padWatch = nil
        touchObserver.view?.removeGestureRecognizer(touchObserver)
        guard let window else { return }
        touchObserver.onChange = { [weak self] fingers in
            guard let self else { return }
            if self.idle.touch(now: ProcessInfo.processInfo.systemUptime, fingers: fingers) { self.refreshControlVisibility() }
        }
        window.addGestureRecognizer(touchObserver)
        padWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.watchPad() }
    }
    static let shared = GameHUDView(frame: .zero)
    var onClose: (() -> Void)?
    var onBack: (() -> Void)?
    var onKeyboard: (() -> Void)?
    /// Opens the compatibility report form for the running game. nil (an installer, say) hides the menu entry.
    var onReport: (() -> Void)? { didSet { menuModel.hasReport = onReport != nil } }
    /// Where the last touch landed on the game (Wine desktop pixels); the zoom buttons scroll the wheel there.
    var cursor: (x: Int32, y: Int32) = (640, 360)

    // The in-game menu (a side panel) and the performance overlay, both SwiftUI, hosted above the controls.
    private let menuModel = GameMenuModel()
    /// The running game's name, for the menu's header.
    var gameName: String? { didSet {
        menuModel.gameName = gameName; isBlender = AppModel.shared.session.game?.isBlender == true
        virtualPad.style = VirtualPadStyle.style(game: AppModel.shared.session.game?.virtualPadStyle, last: UserDefaults.standard.string(forKey: VirtualPadStyle.lastKey))
        menuModel.virtualPadStyle = virtualPad.style
        virtualPad.preset = VirtualPadLayout.preset(game: AppModel.shared.session.game?.virtualPadLayout, last: UserDefaults.standard.string(forKey: VirtualPadLayout.lastKey))
        menuModel.virtualPadLayout = virtualPad.preset
        virtualPadOn = AppModel.shared.session.game?.effectiveVirtualPad == true
        // The HUD outlives a game and PadInput.endSession drops the on-screen controller's sample: a game that starts with the controller already on leaves virtualPadOn unchanged,
        // so its didSet does not run and the game would see no pad although the controller is drawn. Hand the sample over again at every start.
        publishPad()
    } }
    /// Blender is running: its touch navigation (pan, zoom, orbit) and the column of buttons for it. Nothing else gets either.
    private(set) var isBlender = false { didSet { guard isBlender != oldValue else { return }; if !isBlender { blenderNav.reset() }; refreshControlVisibility() } }
    var blenderNavMode: NavMode { blenderNav.mode }
    private let blenderNav = BlenderNavBar()
    /// The on-screen game controller (VirtualPadView): an Xbox pad drawn on the screen for a game that wants a pad. While it is on, the touch layouts (mouse and keys, first person, a bind set's) are put away.
    private let virtualPad = VirtualPadView()
    /// The full keyboard over the game (TouchKeyboardView): opened from the in-game menu or a layout's Keys button.
    private let touchKeyboard = TouchKeyboardView()
    private(set) var virtualPadOn = false { didSet {
        guard virtualPadOn != oldValue else { return }
        menuModel.virtualPad = virtualPadOn
        if !virtualPadOn { virtualPad.releaseAll(); padMixer.set(VirtualPadSample(), for: "pad") }
        publishPad()
        refreshControlVisibility()
        refreshBandOverlay()
    } }
    /// What drives the on-screen Xbox pad: the game controller view, and the pad controls of a custom layout (mixed layouts). The game sees one pad, all of them merged.
    private var padMixer = TouchPadMixer()
    /// Hands the merged pad to PadInput: there is a pad while the game controller is on or the layout has pad controls, none otherwise.
    private func publishPad() {
        let wanted = virtualPadOn || (customControls.usesPad && customLayout != nil)
        PadInput.shared.setVirtual(wanted ? padMixer.merged : nil)
    }
    static let padScaleKey = VirtualPadDefaults.scaleKey, padAlphaKey = VirtualPadDefaults.alphaKey
    /// The running game's Steam app id (nil for a game that is not from Steam), for the menu's Workshop tab.
    var steamAppID: Int? { didSet { menuModel.steamAppID = steamAppID } }
    private let perfModel = PerfOverlayModel()
    private var overlayWatch: AnyCancellable?

    // MARK: The picture moved up (iPad)
    /// The on-screen controls are showing, for the session view to decide whether the picture goes up (PictureBand): the on-screen controller or a custom layout, not hidden by the person or by a
    /// real controller. Whether they are idle-faded does not count, or the picture would move every time they fade.
    var bandControlsOn: Bool { lastState == .running && controlsOn && !hiddenByPad && (virtualPadOn || customLayout != nil) }
    /// Where the layout of the person's own that is showing wants the game's picture (nil = automatic, or no such layout showing).
    var layoutPicture: PicturePlacement? { customLayout != nil && !virtualPadOn ? customLayout?.picture : nil }
    /// Set by the session view when `bandControlsOn` or the layout's picture placement changes.
    var onBandControlsChange: (() -> Void)?
    private var lastBandKey: (Bool, PicturePlacement?) = (false, nil)
    private func noteBandControls() {
        let now = (bandControlsOn, layoutPicture)
        guard now != lastBandKey else { return }
        lastBandKey = now
        onBandControlsChange?()
    }
    /// The performance numbers and the call's people go where the layout in use puts them (the spots it has for them), instead of in a corner.
    private func applyOverlayPlacements() {
        var perf: OverlayPlacement?, call: OverlayPlacement?
        if let l = customLayout, !virtualPadOn {
            // The spot is where the editor shows it, which depends on the screen's size and on left-handed (ControlSpace): as a fraction of the room the controls use.
            let room = bounds.inset(by: safeAreaInsets).size
            let space = ControlSpace(field: room, mirrored: TouchHandedness.leftHanded)
            func spot(_ action: String) -> OverlayPlacement? {
                l.controls.first { $0.action == action }.map { c in
                    guard room.width > 0, room.height > 0 else { return OverlayPlacement(x: c.x, y: c.y, scale: c.overlayScale) }
                    let p = space.point(x: c.x, y: c.y)
                    return OverlayPlacement(x: Double(p.x / room.width), y: Double(p.y / room.height), scale: c.overlayScale)
                }
            }
            perf = spot("overlay-perf"); call = spot("overlay-discord")
        }
        if PerfOverlaySettings.shared.placement != perf { PerfOverlaySettings.shared.placement = perf; placeOverlay() }
        if DiscordOverlaySettings.shared.placement != call { DiscordOverlaySettings.shared.placement = call; updateDiscordFrame() }
    }
    /// The bottom of the game's picture (window points), and whether it has been moved to the top edge.
    var pictureBottom: CGFloat = 0
    var pictureUp = false { didSet { if pictureUp != oldValue { refreshBandOverlay() } } }
    /// While the picture is up and the on-screen controller is showing, the performance numbers and the call's people sit in the room between its trigger columns instead of in a corner.
    private var bandOverlayActive = false { didSet { if bandOverlayActive != oldValue { applyOverlaySettings(); applyDiscordOverlay() } } }
    private lazy var bandHost: UIView = {
        let v = UIHostingConfiguration { BandOverlayView(perfSettings: PerfOverlaySettings.shared, perfModel: self.perfModel, discordSettings: DiscordOverlaySettings.shared, discord: DiscordSession.shared) }
            .margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isHidden = true; v.isUserInteractionEnabled = false; v.translatesAutoresizingMaskIntoConstraints = true
        return v
    }()
    private func refreshBandOverlay() {
        var room: CGRect?
        if pictureUp, virtualPadOn, lastState == .running, bounds.width > 0 {
            let s = safeAreaInsets
            let f = VirtualPadLayout.frames(in: bounds.size, insets: .init(left: s.left, right: s.right, top: s.top, bottom: s.bottom), scale: virtualPad.scale, preset: virtualPad.preset, wide: virtualPad.wide)
            room = VirtualPadLayout.centreRoom(frames: f, top: pictureBottom)
        }
        if let room, bandHost.frame != room { bandHost.frame = room }
        bandOverlayActive = room != nil
        let perfOn = PerfOverlaySettings.shared.enabled, call = DiscordOverlaySettings.shared.enabled && !DiscordSession.shared.callMembers.isEmpty
        bandHost.isHidden = !(bandOverlayActive && lastState == .running && (perfOn || call))
    }
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
    /// The Discord message banner. Unlike the other overlays it takes touches (tap to answer, swipe up to send away), but only while a banner shows and only inside its card.
    private lazy var bannerHost: UIView = {
        let v = UIHostingConfiguration { DiscordBannerView() }.margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isUserInteractionEnabled = false; v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private var bannerTop: NSLayoutConstraint?
    private var bannerWatch: [AnyCancellable] = []

    /// Banners are for a running game with its menu closed (the menu shows the conversations itself).
    private func updateBannerGate() { DiscordNotifier.shared.gameShowing = lastState == .running && !menuOpen }

    private func openDiscordConversation(_ conversation: DiscordConversation) {
        menuModel.tab = .discord
        openMenu()
    }

    private lazy var perfHost: UIView = {
        let v = UIHostingConfiguration { PerfOverlayView(settings: PerfOverlaySettings.shared, model: self.perfModel) }.margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isHidden = true; v.isUserInteractionEnabled = false; v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// The Discord overlay (Discord branch): who is in the call and who is talking. Never takes touches.
    private lazy var discordHost: UIView = {
        let v = UIHostingConfiguration { DiscordOverlayView(settings: DiscordOverlaySettings.shared, discord: DiscordSession.shared) }.margins(.all, 0).makeContentView()
        v.backgroundColor = .clear; v.isHidden = true; v.isUserInteractionEnabled = false; v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private var discordWatch: [AnyCancellable] = []
    private var discordConstraints: [NSLayoutConstraint] = []

    private let message = UILabel()
    private let bar = UIStackView()
    /// A bind set's touch layout (BindSets.swift): when one is in use it replaces the built-in controls below.
    private let customControls = CustomControlsView()
    private var customLayout: TouchLayout?
    private lazy var layoutEditor = ControlsEditorView(controls: customControls)
    /// The arrow for a controller that drives the mouse; the session view says where the game's screen is.
    let padPointer = PadPointerView()
    private let editButton = UIButton(type: .system)      // the pencil, always on screen while a game runs
    private let keyboardButton = UIButton(type: .system)  // opens the keyboard without going through the menu
    private let talkButton = UIButton(type: .system)      // Discord push to talk: the microphone sends while it is held (only in a call with push to talk on)
    private var talkWatch: AnyCancellable?
    private var topColumn: UIStackView?
    private var wantsEditAfterCreate = false
    /// The in-game editor (the menu): open the full bind editor over the game, a new set was wanted from a starting layout, and a layout changed on screen.
    var onEditBinds: (() -> Void)?
    /// The in-game menu's quick layout switch: a set of the game (nil: its default controls), and "+ New" to add a layout from a starter.
    var onChooseLayout: ((UUID?) -> Void)?
    var onPickStarter: (() -> Void)?
    func setLayoutChoices(_ choices: [LayoutChoice]) { if menuModel.layoutChoices != choices { menuModel.layoutChoices = choices } }
    var onCreateLayout: ((TouchLayout) -> Void)? { didSet { _ = oldValue } }
    var onLayoutChanged: ((TouchLayout) -> Void)? { didSet { customControls.onChange = onLayoutChanged } }
    /// The look button of a custom layout flips this; the layout's own "Look" setting (the editor's Look on/off) is the starting point and is never changed by it.
    private var customLookFlipped = false
    private var customLook: Bool { customLayout.map { $0.look != customLookFlipped } ?? false }
    /// Look speed (points -> mouse counts) and the callback the menu buttons use to change it.
    var lookSensitivity: CGFloat = 2.4 { didSet { menuModel.lookSpeed = Double(lookSensitivity); menuModel.showLookSpeed = customLook } }
    var onAdjustLook: (Double) -> Void = { _ in }
    /// Touches on the game should turn into mouse LOOK movement instead of clicks.
    var lookActive: Bool { customLook }
    private var controlsOn = true
    private var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            updateBannerGate()
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
        buildTopBar(); buildControls(); buildCustomControls()
        NotificationCenter.default.addObserver(forName: PowerManager.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshPower() }
        NotificationCenter.default.addObserver(forName: TouchHandedness.changed, object: nil, queue: .main) { [weak self] _ in self?.applyOverlayPlacements() }
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
        talkButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        talkButton.tintColor = .white; talkButton.backgroundColor = UIColor(white: 0, alpha: 0.55); talkButton.layer.cornerRadius = 8
        talkButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        talkButton.accessibilityLabel = "Hold to talk"; talkButton.isHidden = true
        talkButton.addAction(UIAction { [weak self] _ in self?.talkButton.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.85); DiscordSession.shared.setTalking(true) }, for: .touchDown)
        let letGo = UIAction { [weak self] _ in self?.talkButton.backgroundColor = UIColor(white: 0, alpha: 0.55); DiscordSession.shared.setTalking(false) }
        talkButton.addAction(letGo, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        [editButton, keyboardButton, talkButton].forEach(bar.addArrangedSubview)
        // The button follows the call and the setting.
        talkWatch = DiscordSession.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTalkButton() } }
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
        blenderNav.translatesAutoresizingMaskIntoConstraints = false; blenderNav.isHidden = true
        addSubview(blenderNav)       // on the HUD itself: it stays whichever of the touch layouts is in use
        NSLayoutConstraint.activate([blenderNav.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
                                     blenderNav.centerYAnchor.constraint(equalTo: centerYAnchor)])

        virtualPad.translatesAutoresizingMaskIntoConstraints = false; virtualPad.isHidden = true
        let defaults = UserDefaults.standard
        virtualPad.scale = CGFloat(defaults.object(forKey: Self.padScaleKey) as? Double ?? 1); virtualPad.restingAlpha = CGFloat(defaults.object(forKey: Self.padAlphaKey) as? Double ?? 0.55)
        virtualPad.wide = UIDevice.current.userInterfaceIdiom == .pad
        virtualPad.onChange = { [weak self] in self?.padMixer.set($0, for: "pad"); self?.publishPad() }
        customControls.onPad = { [weak self] in self?.padMixer.set($0, for: "custom"); self?.publishPad() }
        addSubview(virtualPad)
        NSLayoutConstraint.activate([virtualPad.leadingAnchor.constraint(equalTo: leadingAnchor), virtualPad.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     virtualPad.topAnchor.constraint(equalTo: topAnchor), virtualPad.bottomAnchor.constraint(equalTo: bottomAnchor)])
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

    /// The pencil: edits the on-screen controls right on the game. With no layout of the game's own yet, one is made from Universal and used (a game with the on-screen game controller on has none),
    /// then editing starts at once; nothing else is asked.
    func beginLayoutEditing() {
        menuOpen = false
        guard lastState == .running else { return }
        if customLayout == nil {
            wantsEditAfterCreate = true
            onCreateLayout?(ShippedLayouts.universal.layout)
            return
        }
        startEditing()
    }

    private func startEditing() {
        controlsOn = true
        refreshControlVisibility()
        topColumn?.isHidden = true                 // the editor has its own bar; the game's top-left stack would sit under it
        editButton.isHidden = true; keyboardButton.isHidden = true; talkButton.isHidden = true
        layoutEditor.setActive(true)
    }

    func endLayoutEditing() {
        layoutEditor.setActive(false)
        topColumn?.isHidden = false
        refreshControlVisibility()
        refreshHandle(pulse: false)
    }

    /// Whether this layout is the one every game starts with: the same controls in the same places (the ids of the controls do not count).
    static func isMyDefault(_ layout: TouchLayout?) -> Bool {
        guard let layout, let d = DefaultControls.current.touchLayout else { return false }
        func shape(_ l: TouchLayout) -> [String] { l.controls.map { "\($0.action)|\($0.label)|\($0.mode)|\($0.x)|\($0.y)|\($0.size)" } }
        return shape(layout) == shape(d) && layout.look == d.look
    }

    /// The touch layout of the bind set in use (nil = the game's normal Controls choice).
    func setCustomLayout(_ new: TouchLayout?) {
        guard new != customLayout else { return }
        if new?.look != customLayout?.look { customLookFlipped = false }          // the layout's own setting changed: start from it
        customLayout = new
        customControls.apply(new)
        publishPad()          // a layout with pad controls makes the game see a controller; one without takes it away again
        menuModel.customLayoutInUse = new != nil          // the built-in layouts are not in use while a set's layout is
        menuModel.layoutIsMyDefault = Self.isMyDefault(new)
        refreshControlVisibility()
        if wantsEditAfterCreate, new != nil { wantsEditAfterCreate = false; startEditing() }
        if new == nil, layoutEditor.isHidden == false { endLayoutEditing() }
    }

    /// Floating sticks (FloatingStick) for every stick the HUD owns.
    private func applyFloating() {
        let on = FloatingStick.enabled
        customControls.floatingSticks = on
        virtualPad.floating = on
    }

    private func refreshControlVisibility() {
        applyFloating()
        let on = lastState == .running && controlsOn && !hiddenByPad && !idle.hidden
        // Blender's touch navigation is a gesture layer, not buttons: hiding it when idle would swallow the first gesture, so only the other reasons hide it.
        blenderNav.isHidden = !(lastState == .running && controlsOn && !hiddenByPad && isBlender && layoutEditor.isHidden)
        let padShown = on && virtualPadOn && layoutEditor.isHidden
        virtualPad.isHidden = !padShown
        if !padShown { virtualPad.releaseAll() }
        customControls.isHidden = !(on && customLayout != nil && !virtualPadOn)
        if !(on && customLayout != nil && !virtualPadOn) { customControls.release() }
        editButton.isHidden = !(lastState == .running) || !layoutEditor.isHidden
        keyboardButton.isHidden = editButton.isHidden
        refreshTalkButton()
        noteBandControls()
        applyOverlayPlacements()
    }

    // MARK: Behaviour

    private func showHelp() {
        let alert = UIAlertController(title: "Touch controls", message: """
            Tap: left click
            Drag: moves the mouse (or looks around, with Look on)
            Two-finger tap: right click
            Pinch: zoom
            Stick: W A S D
            Look / Mouse button: switches what dragging does
            Keys button: the full keyboard
            Shift / Ctrl / Alt: tap once to hold, again to release (a layout can latch them)
            """, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(alert, animated: true)
    }

    private func toggleControls() { controlsOn.toggle(); refreshControlVisibility(); menuModel.controlsShown = controlsOn }

    private func refreshTalkButton() {
        let show = !editButton.isHidden && DiscordSession.shared.talkButtonShowing
        if talkButton.isHidden == show { talkButton.isHidden = !show }
        if !show { DiscordSession.shared.setTalking(false); talkButton.backgroundColor = UIColor(white: 0, alpha: 0.55) }
    }

    /// Only the controls are interactive; everything else falls through to the game surface.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let v = super.hitTest(point, with: event) else { return nil }
        if !layoutEditor.isHidden, v.isDescendant(of: layoutEditor) { return v }
        if !menuHost.isHidden, v.isDescendant(of: menuHost) { return v }          // the open menu takes every touch, so none reach the game
        if bannerHost.isUserInteractionEnabled, v.isDescendant(of: bannerHost) { return v }   // a Discord banner (tap, Join, Decline) while one shows; not listed here, every touch on it fell through to the game
        return (v is UIControl || v is TakesHUDTouches || v is CustomStick || v is CustomControlsView || v is VirtualPadView) ? v : nil
    }

    // MARK: Menu and performance overlay

    /// Puts the two SwiftUI views over the controls and connects the menu's actions to what the HUD already does.
    private func buildMenuAndOverlay() {
        let m = menuModel
        m.dismiss = { [weak self] in self?.menuOpen = false }
        m.setPower = { PowerManager.shared.setForSession($0) }
        m.setPadMode = { [weak self] mode in AppModel.shared.session.setPadMode(mode); self?.refreshMenuModel() }
        m.setVirtualPad = { [weak self] on in AppModel.shared.session.setVirtualPad(on); self?.virtualPadOn = on; self?.refreshMenuModel() }
        // A style is a controller: the names and colours on the buttons (the controls are in the same places for every one).
        m.setVirtualPadStyle = { [weak self] style in
            AppModel.shared.session.setVirtualPadStyle(style)
            self?.virtualPad.style = style
            self?.refreshMenuModel()
        }
        // An arrangement is where the controls are: the same for every controller type.
        m.setVirtualPadLayout = { [weak self] preset in
            AppModel.shared.session.setVirtualPadLayout(preset)
            self?.virtualPad.preset = preset
            self?.refreshMenuModel()
            self?.refreshControlVisibility()
        }
        m.adjustVirtualPad = { [weak self] size, opacity in
            guard let self else { return }
            let scale = max(0.6, min(1.4, Double(self.virtualPad.scale) + size)), alpha = max(0.2, min(1, Double(self.virtualPad.restingAlpha) + opacity))
            self.virtualPad.scale = CGFloat(scale); self.virtualPad.restingAlpha = CGFloat(alpha)
            UserDefaults.standard.set(scale, forKey: Self.padScaleKey); UserDefaults.standard.set(alpha, forKey: Self.padAlphaKey)
            self.refreshMenuModel()
        }
        m.setEco = { [weak self] on in
            madeira_set_eco(on ? 1 : 0)
            LogStore.shared.log("[eco] \(on ? "on" : "off") from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setLosslessEnabled = { [weak self] on in
            var v = LosslessScaling.shared.live; v.enabled = on
            let ok = LosslessScaling.shared.apply(v)
            ProMotionHold.shared.setFrameGeneration(on && ok)
            LogStore.shared.log("[lossless] frame generation \(on ? (ok ? "on" : "could not start: the shaders could not be prepared") : "off") from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setLosslessGenerated = { [weak self] n in
            var v = LosslessScaling.shared.live; v.generated = n
            LosslessScaling.shared.apply(v)
            LogStore.shared.log("[lossless] \(n) frame(s) added from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setLosslessFlow = { [weak self] f in
            var v = LosslessScaling.shared.live; v.flow = f
            LosslessScaling.shared.apply(v)
            LogStore.shared.log("[lossless] motion search at 1/\(f) from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setLosslessPerformance = { [weak self] on in
            var v = LosslessScaling.shared.live; v.performance = on
            LosslessScaling.shared.apply(v)
            LogStore.shared.log("[lossless] \(on ? "lighter (performance)" : "full (quality)") passes from the in-game menu")
            self?.refreshMenuModel()
        }
        m.refreshLosslessStatus = { [weak self] in self?.menuModel.lsStatus = LosslessScaling.shared.statusText() }
        m.setUpscaling = { [weak self] mode, factor, method, sharpness in
            AppModel.shared.session.setUpscaling(LiveUpscaling.Live(mode: LiveUpscaling.Mode(rawValue: mode) ?? .off, factor: factor, method: LiveUpscaling.Method(rawValue: method) ?? .metalfx, sharpness: sharpness))
            self?.refreshMenuModel()
        }
        m.refreshUpscalingStatus = { [weak self] in self?.menuModel.upStatus = LiveUpscaling.shared.statusText() }
        m.setFence = { [weak self] mode in
            madeira_set_fence_mode(Int32(mode == 0 ? 7 : mode))
            self?.fenceMode = mode
            LogStore.shared.log("[gpu-sync] mode F\(mode) from the in-game menu")
            self?.refreshMenuModel()
        }
        m.setControlsShown = { [weak self] on in guard let self, on != self.controlsOn else { return }; self.toggleControls() }
        m.setPointerMode = { [weak self] mode in
            UserDefaults.standard.set(mode.rawValue, forKey: PointerMode.key)
            self?.menuModel.pointerMode = mode
            LogStore.shared.log("[controls] touch pointer: \(mode.rawValue) (from the in-game menu)")
        }
        m.setPointerSpeed = { [weak self] speed in
            UserDefaults.standard.set(speed.rawValue, forKey: PointerMode.speedKey)
            self?.menuModel.pointerSpeed = speed
            LogStore.shared.log("[controls] trackpad speed: \(speed.rawValue) (from the in-game menu)")
        }
        m.setFloatingSticks = { [weak self] on in
            UserDefaults.standard.set(on, forKey: FloatingStick.key)
            self?.applyFloating()
            self?.menuModel.floatingSticks = on
            LogStore.shared.log("[controls] floating sticks \(on ? "on" : "off") (from the in-game menu)")
        }
        m.setAutoHide = { [weak self] seconds in
            UserDefaults.standard.set(seconds, forKey: Self.autoHideKey)
            self?.idle.seconds = seconds
            self?.menuModel.autoHideSeconds = seconds
            LogStore.shared.log("[controls] hide when not touched: \(seconds == 0 ? "never" : "\(seconds) s") (from the in-game menu)")
        }
        m.adjustLook = { [weak self] factor in self?.onAdjustLook(factor) }
        m.openKeyboard = { [weak self] in self?.menuOpen = false; self?.onKeyboard?() }
        m.openFullKeyboard = { [weak self] in self?.menuOpen = false; self?.touchKeyboard.toggle() }
        m.openBinds = { [weak self] in self?.menuOpen = false; self?.onEditBinds?() }
        m.chooseLayout = { [weak self] id in self?.onChooseLayout?(id) }
        m.pickStarterLayout = { [weak self] in self?.menuOpen = false; self?.onPickStarter?() }
        m.setLeftHanded = { [weak self] on in
            TouchHandedness.set(on)
            self?.menuModel.leftHanded = on
            LogStore.shared.log("[controls] left-handed \(on ? "on" : "off") (from the in-game menu)")
        }
        m.editControls = { [weak self] in self?.beginLayoutEditing() }
        m.useAsDefault = { [weak self] in
            guard let self, let layout = self.customLayout else { return }
            var d = DefaultControls.current
            d.use(custom: layout)
            DefaultControls.current = d
            LogStore.shared.log("[controls] the layout on screen is now the default for every game (\(layout.controls.count) controls)")
            self.menuModel.layoutIsMyDefault = true
        }
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

        addSubview(touchKeyboard)
        let keyboardWidth = touchKeyboard.widthAnchor.constraint(equalToConstant: 860)
        keyboardWidth.priority = .defaultHigh                  // as wide as 860 points when the screen allows, else the margins decide
        NSLayoutConstraint.activate([touchKeyboard.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor), keyboardWidth,
                                     touchKeyboard.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
                                     touchKeyboard.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
                                     touchKeyboard.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4)])
        customControls.onToggleKeyboard = { [weak self] in self?.touchKeyboard.toggle() }
        addSubview(perfHost); addSubview(discordHost); addSubview(bandHost); addSubview(menuHost)
        NSLayoutConstraint.activate([menuHost.leadingAnchor.constraint(equalTo: leadingAnchor), menuHost.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     menuHost.topAnchor.constraint(equalTo: topAnchor), menuHost.bottomAnchor.constraint(equalTo: bottomAnchor)])
        addSubview(bannerHost)
        let top = bannerHost.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8)
        let width = bannerHost.widthAnchor.constraint(equalToConstant: 440); width.priority = .defaultHigh
        bannerTop = top
        NSLayoutConstraint.activate([top, width, bannerHost.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor), bannerHost.heightAnchor.constraint(equalToConstant: 96),
                                     bannerHost.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
                                     bannerHost.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12)])
        DiscordNotifier.shared.onOpen = { [weak self] conversation in self?.openDiscordConversation(conversation) }
        bannerWatch = [DiscordNotifier.shared.objectWillChange.sink { [weak self] _ in
                           DispatchQueue.main.async { self?.bannerHost.isUserInteractionEnabled = DiscordNotifier.shared.bannerTouchable }
                       },
                       // Below an achievement pop-up when both show at once.
                       AchievementToastCenter.shared.$current.sink { [weak self] toast in self?.bannerTop?.constant = toast == nil ? 8 : 92 }]
        addSubview(toastHost)
        NSLayoutConstraint.activate([toastHost.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor), toastHost.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
                                     toastHost.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), toastHost.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)])
        placeOverlay()
        applyOverlaySettings()
        overlayWatch = PerfOverlaySettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyOverlaySettings() }
        }
        discordWatch = [DiscordOverlaySettings.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.applyDiscordOverlay() } },
                        DiscordSession.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.applyDiscordOverlay() } }]
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
        menuModel.virtualPad = virtualPadOn
        menuModel.virtualPadStyle = virtualPad.style
        menuModel.virtualPadLayout = virtualPad.preset
        menuModel.virtualPadScale = Double(virtualPad.scale); menuModel.virtualPadOpacity = Double(virtualPad.restingAlpha)
        menuModel.padHidReady = PadInput.shared.hidReady
        menuModel.padKindName = ControllerInput.shared.kind == .none ? "" : ControllerInput.shared.kind.displayName
        menuModel.powerChosen = p.chosen
        menuModel.powerEffective = p.effective
        menuModel.eco = madeira_get_eco() != 0
        menuModel.lsAvailable = LosslessScaling.shared.usable
        let ls = LosslessScaling.shared.live
        menuModel.lsEnabled = ls.enabled; menuModel.lsGenerated = ls.generated; menuModel.lsFlow = ls.flow; menuModel.lsPerformance = ls.performance
        menuModel.lsStatus = LosslessScaling.shared.statusText()
        menuModel.upAvailable = LiveUpscaling.shared.controlled
        let up = LiveUpscaling.shared.live
        menuModel.upMode = up.mode.rawValue; menuModel.upFactor = up.factor
        menuModel.upMethod = up.method.rawValue; menuModel.upSharpness = up.sharpness; menuModel.upLossless = LosslessScaling.shared.usable
        menuModel.upStatus = LiveUpscaling.shared.statusText()
        menuModel.fenceMode = fenceMode
        menuModel.customLayoutInUse = customLayout != nil
        menuModel.layoutIsMyDefault = Self.isMyDefault(customLayout)
        menuModel.leftHanded = TouchHandedness.leftHanded
        menuModel.controlsShown = controlsOn
        menuModel.autoHideSeconds = UserDefaults.standard.integer(forKey: Self.autoHideKey)
        menuModel.floatingSticks = FloatingStick.enabled
        menuModel.pointerMode = PointerMode.current
        menuModel.pointerSpeed = PointerMode.speed
        menuModel.showLookSpeed = customLook
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
    override func layoutSubviews() {
        super.layoutSubviews(); updateOverlayRoom(); updateDiscordFrame(); refreshBandOverlay()
        // The overlays' spots follow the screen's size (the editor's mapping depends on it): work them out again when the room changes.
        let room = bounds.inset(by: safeAreaInsets).size
        if room != lastOverlayRoom { lastOverlayRoom = room; applyOverlayPlacements() }
    }
    private var lastOverlayRoom = CGSize.zero

    /// The overlay's host fills the room on screen (the safe area less a margin, and below the top-left stack when the overlay is in that corner) and the overlay itself
    /// sits in its corner inside it. The host never has to be re-sized when the overlay grows or shrinks, which a host sized to its content did not follow.
    private var overlayCorner: OverlayCorner?
    private var overlayWasPlaced = false
    private func placeOverlay() {
        let corner = PerfOverlaySettings.shared.corner
        let placed = PerfOverlaySettings.shared.placement != nil
        guard corner != overlayCorner || placed != overlayWasPlaced else { return }
        overlayCorner = corner; overlayWasPlaced = placed
        NSLayoutConstraint.deactivate(overlayConstraints)
        let g = safeAreaLayoutGuide
        // A spot the layout chose is a point of the room the controls use (the screen inside its safe area), so the room is exactly that.
        let top: NSLayoutConstraint = !placed && corner == .topLeading
            ? perfHost.topAnchor.constraint(equalTo: (topColumn ?? self).bottomAnchor, constant: 6)
            : perfHost.topAnchor.constraint(equalTo: g.topAnchor, constant: placed ? 0 : 8)
        overlayConstraints = [perfHost.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: placed ? 0 : 12), perfHost.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: placed ? 0 : -12),
                              top, perfHost.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: placed ? 0 : -8)]
        NSLayoutConstraint.activate(overlayConstraints)
    }

    /// The overlay settings changed (or the game started or ended): show or hide it, move it, and ask for the slower measurements only when a shown number needs them.
    private func applyOverlaySettings() {
        let settings = PerfOverlaySettings.shared
        placeOverlay()
        perfHost.isHidden = bandOverlayActive || !(settings.enabled && lastState == .running)
        Telemetry.detailWanted = settings.wantsDetail && lastState == .running
        InputLagMeter.shared.active = settings.wantsInputLag && lastState == .running
        if settings.wantsPresentTiming && lastState == .running { PresentTimer.shared.start() } else if PresentTimer.shared.isRunning { PresentTimer.shared.stop() }
        if settings.enabled && lastState == .running { showTelemetry(Telemetry.shared.latest) }
        applyDiscordOverlay()
    }

    /// Where the game's picture is on the screen (window points, set by the session view): the Discord overlay sits inside it, like Discord's own overlay over a game, instead of in a
    /// corner of the whole screen (in portrait the picture is a band in the middle, with black above and below).
    var gameArea: CGRect = .zero { didSet { if oldValue != gameArea { updateDiscordFrame() } } }

    /// The Discord overlay shows while a game runs, the overlay is on and a call has people in it.
    private func applyDiscordOverlay() {
        let settings = DiscordOverlaySettings.shared
        if discordConstraints.isEmpty {
            discordConstraints = [discordHost.leadingAnchor.constraint(equalTo: leadingAnchor), discordHost.trailingAnchor.constraint(equalTo: trailingAnchor),
                                  discordHost.topAnchor.constraint(equalTo: topAnchor), discordHost.bottomAnchor.constraint(equalTo: bottomAnchor)]
            NSLayoutConstraint.activate(discordConstraints)
        }
        updateDiscordFrame()
        discordHost.isHidden = bandOverlayActive || !(settings.enabled && lastState == .running && !DiscordSession.shared.callMembers.isEmpty)
        refreshBandOverlay()
    }

    /// Fits the overlay's room to the game's picture (inside the safe area, below the top-left buttons when they are in the way).
    private func updateDiscordFrame() {
        guard discordConstraints.count == 4, bounds.width > 0 else { return }
        var rect = (gameArea.isEmpty ? bounds : gameArea.intersection(bounds)).insetBy(dx: 12, dy: 8).intersection(bounds.inset(by: safeAreaInsets))
        if DiscordOverlaySettings.shared.placement != nil { rect = bounds.inset(by: safeAreaInsets) }          // a spot the layout chose: a point of the room the controls use
        else if DiscordOverlaySettings.shared.corner == .topLeading, let column = topColumn {
            let below = column.frame.maxY + 6
            if column.frame.minY < rect.maxY, below > rect.minY, below < rect.maxY { rect = CGRect(x: rect.minX, y: below, width: rect.width, height: rect.maxY - below) }
        }
        guard !rect.isNull, rect.width > 20, rect.height > 20 else { return }
        discordConstraints[0].constant = rect.minX
        discordConstraints[1].constant = rect.maxX - bounds.width
        discordConstraints[2].constant = rect.minY
        discordConstraints[3].constant = rect.maxY - bounds.height
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
            suggestion.begin(now: ProcessInfo.processInfo.systemUptime, reads: winios_gamepad_read_count())
            Telemetry.shared.onSample = { [weak self] s in self?.showTelemetry(s) }
            Telemetry.shared.onAlert = { [weak self] text in self?.showNotice(text) }
            Telemetry.shared.start()
        } else {
            touchKeyboard.hide()
            suggestionCard?.removeFromSuperview(); suggestionCard = nil
            Telemetry.shared.stop()
        }
        bar.isHidden = !running
        if !running { menuOpen = false; perfModel.reset() }
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
        default: message.isHidden = true; back.isHidden = true        // starting: the launch screen says what is happening; no line of text over the top of the screen
        }
    }
}
