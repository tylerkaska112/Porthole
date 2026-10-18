// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Physical game controllers inside a game. The runtime keeps a snapshot of up to four Xbox pads (winios_gamepad_set_state) that Wine's XInput reads, an
// optional HID player 1 (a DualSense or a generic gamepad) and, from the same pad, keys and mouse for games that have no controller support.
// The sampling loop follows Madeira's own (its GamepadInput.swift): one serial queue, a 4 ms timer while a session runs, nothing published otherwise.
@preconcurrency import GameController
import UIKit

// MARK: - The input loop

final class PadInput: @unchecked Sendable {
    static let shared = PadInput()

    /// Controllers reach games at all: env.MADEIRA_XINPUT in madeira.cfg (or the environment), anything but "0".
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_XINPUT") }
    /// The keyboard-and-mouse mode is offered.
    static var keyboardMouseAvailable: Bool { enabled && MadeiraConfig.flag("MADEIRA_PAD_KBM") }

    private let queue = DispatchQueue(label: "porthole.gamepad", qos: .userInteractive)
    private var controllers = [GCController?](repeating: nil, count: 4)
    private var profiles = [GCExtendedGamepad?](repeating: nil, count: 4)
    private var timer: DispatchSourceTimer?
    private var active = false
    private var keyboardMouse: [String: String]?           // the binds, while keyboard-and-mouse mode is on
    private var mouseVertical = 1.0
    private var hidActive = false, hidKeepsXInput = false
    private var hidBattery: (level: UInt8, charging: UInt8) = (UInt8(WINIOS_HIDPAD_BATTERY_UNKNOWN), 0)
    private var hidBatteryCountdown = 0
    private var published = [Bool](repeating: false, count: 4), hidPublished = false
    private var auto: PadAuto?                          // automatic mode: Xbox pad until the game proves it does not read it (PadAuto)
    private var autoKeys: [String: String] = [:]        // the keyboard-and-mouse binds automatic mode switches to
    private var autoGameID: UUID?
    private var lastWatch = 0.0
    private let slotLock = NSLock()
    /// The in-game menu chord (PadChord.swift), and the menu holding the pad: while it is open the game sees a neutral controller.
    private var chord = PadChord()
    private var chordMask = PadChordSetting.menuView
    private var captured = false
    private var releaseMask = PadReleaseMask()
    private var lastButtons: UInt16 = 0
    private var remap: PadRemap?                           // this game's button remap (nil = none)
    /// The DualSense identity exists for this session (MADEIRA_HIDPAD was exported before the wineserver started; it cannot appear or go away later). Whether the game is shown
    /// the DualSense can still be switched while it runs, by publishing or withdrawing its reports. `autoHID`: what Automatic means this session.
    private var hidAvailable = false, autoHID = false
    private let hidReadyLock = NSLock()
    private var hidReadyValue = false
    /// From any thread: the in-game menu asks whether "DualSense and Xbox" can be chosen right now.
    var hidReady: Bool { hidReadyLock.lock(); defer { hidReadyLock.unlock() }; return hidReadyValue }
    /// When a controller was last pushed or pressed (system uptime; 0 = never since launch), from any thread. The on-screen controls step aside while it is recent.
    private let activityLock = NSLock()
    private var activityAt: TimeInterval = 0
    var lastActivity: TimeInterval { activityLock.lock(); defer { activityLock.unlock() }; return activityAt }
    private var slotSnapshot = [GCController?](repeating: nil, count: 4)
    /// The controller in a player's slot, from any thread (the rumble code asks).
    func controller(at index: Int) -> GCController? { slotLock.lock(); defer { slotLock.unlock() }; return (0..<4).contains(index) ? slotSnapshot[index] : nil }
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var observing = false
    @MainActor private var inSession = false          // a game is running: the controller's system gestures are switched off

    // MARK: Session

    /// Called right before a game starts (before the wineserver, which reads MADEIRA_HIDPAD). `game` supplies the controller mode and binds.
    /// `viaSteam`: the game starts through Valve's Steam client. Its Steam Input finds controllers through SDL3, which looks for HID gamepads: with Steam's controller support
    /// downloaded (SteamSDL3) the PlayStation pad is shown to Steam as a DualSense so games that take their pad from Steam Input (Portal) can get it. Without that download Steam
    /// Input cannot start at all, and a Steam launch keeps the Xbox pad (as in 0.50.366) unless the game's own Controller choice or env.PORTHOLE_PAD_IDENTITY = steam asks for it.
    @MainActor func beginSession(for game: Game?, viaSteam: Bool = false) {
        PadPointerView.enableReports()
        Self.forgetEarlyKeyVerdicts()
        unsetenv("MADEIRA_HIDPAD"); unsetenv("MADEIRA_HIDPAD_NAME")
        guard Self.enabled else {
            LogStore.shared.log("[pad] controllers are off (MADEIRA_XINPUT=0)")
            return
        }
        // Player 1's controller type (Xbox unless HID was chosen in Settings > Engine options).
        // This game's own choice "DualSense (HID)" wins over the app-wide Engine option: the pad is shown as a HID DualSense (with the Xbox pad kept too).
        let gameHID = game?.engine?.controllerMode == "hid"
        let mode = gameHID ? "hid" : EngineOptions.value("env.MADEIRA_PAD_MODE").lowercased()
        let first = GCController.controllers().first { $0.extendedGamepad != nil }
        var hid = false, keepXInput = false, identityHID = false
        if ["hid", "dualsense", "generic"].contains(mode) {
            let sony = first?.extendedGamepad is GCDualSenseGamepad || first?.extendedGamepad is GCDualShockGamepad
            let kind = ["dualsense", "generic"].contains(mode) ? mode : (first == nil || sony ? "dualsense" : "generic")
            setenv("MADEIRA_HIDPAD", kind, 1)
            if kind == "generic", let name = first?.vendorName { setenv("MADEIRA_HIDPAD_NAME", name, 1) }
            hid = true
            keepXInput = gameHID || EngineOptions.value("env.MADEIRA_HIDPAD_XINPUT") == "1"
            LogStore.shared.log("[pad] player 1 as a HID \(kind) (pad: \(first?.productCategory ?? "none"), Xbox kept: \(keepXInput))")
        } else if let first, game?.engine?.controllerMode == nil, mode.isEmpty, ControllerKind.detect(first).isPlayStation, viaSteam, !SteamSDL3.installed,
                  EngineOptions.value("env.PORTHOLE_PAD_IDENTITY") != "steam" {
            LogStore.shared.log("[pad] not shown as a DualSense: the game starts through Steam and Steam's controller support is not downloaded (Steam page), so Steam Input cannot run (the Xbox pad is used)")
        } else if let first, game?.engine?.controllerMode == nil, mode.isEmpty, !["0"].contains(EngineOptions.value("env.PORTHOLE_PAD_IDENTITY")),
                  ControllerKind.detect(first).isPlayStation, !Self.wantsXboxPad(game) {
            // Automatic, and the person is holding a PlayStation pad: the game is told so. It sees a DualSense (so it can show PlayStation buttons and read the touchpad) next to
            // the Xbox pad that games without HID support still read. A game's own "Xbox controller" choice, or env.PORTHOLE_PAD_IDENTITY = 0, keeps the old Xbox-only pad.
            setenv("MADEIRA_HIDPAD", "dualsense", 1)
            hid = true; keepXInput = true; identityHID = true
            LogStore.shared.log("[pad] player 1 shown to the game as a DualSense (\(ControllerKind.detect(first).displayName) connected), Xbox pad kept")
        }
        let autoHIDNow = identityHID || (!gameHID && hid)         // what "Automatic" shows the game: the identity, or the app-wide HID choice
        let (binds, vertical) = Self.resolveBinds(for: game)
        if binds != nil { LogStore.shared.log("[pad] controller as keyboard and mouse for this game" + (game?.activeBindSet?.pad != nil ? " (bind set \"\(game?.activeBindSet?.name ?? "")\")" : "")) }
        PadRumble.shared.configure(scale: PadRumble.scale(from: EngineOptions.value("env.PORTHOLE_RUMBLE")))
        inSession = true
        observe()
        refreshControllers()
        // Automatic mode: the game's controller mode is not set, nothing else decides, and keyboard and mouse is available.
        let isAuto = Self.keyboardMouseAvailable && binds == nil && (!hid || identityHID) && game?.engine?.controllerMode == nil
        var automatic: PadAuto?
        var startBinds = binds
        if isAuto {
            var a = PadAuto()
            a.begin(now: ProcessInfo.processInfo.systemUptime, reads: winios_gamepad_read_count(), preferKeys: game?.engine?.padAuto == "keys")
            automatic = a
            if a.usingKeys { startBinds = PadActions.bindings(game?.engine?.binds); LogStore.shared.log("[pad] automatic: this game did not read the controller last time, starting as keyboard and mouse") }
        }
        let keysForAuto = PadActions.bindings(game?.engine?.binds)
        let gameID = game?.id
        let menuMask = PadChordSetting.mask(for: EngineOptions.value("env.PORTHOLE_PAD_MENU"))
        let remapNow = Self.remap(of: game)
        if remapNow != nil { LogStore.shared.log("[pad] buttons remapped for this game: \(remapNow?.map.filter { $0.key != $0.value }.sorted { $0.key < $1.key }.map { "\($0.key)->\($0.value)" }.joined(separator: " ") ?? "")") }
        if let first { Self.announceChord(mask: menuMask, kind: ControllerKind.detect(first)) }
        queue.async { [self] in
            chordMask = menuMask; chord = PadChord(); captured = false; releaseMask = PadReleaseMask(); lastButtons = 0; remap = remapNow
            hidActive = hid; hidKeepsXInput = keepXInput; keyboardMouse = startBinds; mouseVertical = vertical
            hidAvailable = hid; autoHID = autoHIDNow
            hidReadyLock.lock(); hidReadyValue = hid; hidReadyLock.unlock()
            auto = automatic; autoKeys = keysForAuto; autoGameID = gameID; lastWatch = 0
            active = true; readLogAt = 0
            updateTimer(); sample()
        }
    }

    /// The game reads Xbox gamepads only (a known game, or Rewired's Windows.Gaming.Input plugin): Automatic keeps the Xbox pad instead of showing a PlayStation controller as a DualSense.
    private static func wantsXboxPad(_ game: Game?) -> Bool {
        guard let game else { return false }
        if GameFixes.fix(forSteamAppID: game.dockAppID ?? game.steamAppID)?.xboxPad == true { return true }
        return GameFixes.usesRewiredWindowsGamingInput(program: AppModel.unixURL(forWindows: game.exe))
    }

    /// The in-game menu opened or closed: while it is open the controller drives the menu and the game sees a neutral pad. The buttons held when it closes (the B that
    /// closed it) stay hidden from the game until they are let go.
    @MainActor func setCaptured(_ on: Bool) {
        queue.async { [self] in
            guard captured != on else { return }
            captured = on
            if on { releaseAll() } else { releaseMask.latch(lastButtons) }
            sample()
        }
    }

    /// A note over the game, the first few times, saying how to open the menu from the controller.
    @MainActor private static func announceChord(mask: UInt16, kind: ControllerKind) {
        let key = "f4.padMenuHint"
        let shown = UserDefaults.standard.integer(forKey: key)
        guard mask != 0, shown < 3 else { return }
        UserDefaults.standard.set(shown + 1, forKey: key)
        let name = PadChordSetting.name(mask: mask, kind: kind)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            AppModel.shared.session.showPadNotice("Hold \(name) for half a second to open the Porthole menu.")
        }
    }

    private func fireMenuChord() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .padMenuChord, object: nil) }
    }

    /// The game's button remap, or nil when it has none that changes anything.
    static func remap(of game: Game?) -> PadRemap? {
        guard let map = game?.engine?.padRemap else { return nil }
        let r = PadRemap(map: map)
        return r.isEmpty ? nil : r
    }

    /// The keys-and-mouse binds (nil = the pad stays an Xbox controller) and the right stick's vertical speed for `game`: a bind set in use that has a controller part decides,
    /// otherwise the game's own controller settings do.
    static func resolveBinds(for game: Game?) -> (binds: [String: String]?, vertical: Double) {
        let set = game?.activeBindSet?.pad
        let binds: [String: String]? = keyboardMouseAvailable
            ? (set.map { PadActions.bindings($0.binds) } ?? (game?.engine?.controllerMode == "keys" ? PadActions.bindings(game?.engine?.binds) : nil)) : nil
        return (binds, min(max(set?.mouseVertical ?? game?.engine?.padMouseVertical ?? 1, 0.25), 2.0))
    }

    /// While a game runs: apply a changed bind set at once. Nothing happens when what the controller does has not changed (so dragging an on-screen control
    /// never lets go of a held key). The controller type (Xbox or HID) is fixed at the start and does not change here.
    @MainActor func updateLive(for game: Game?) {
        let (resolved, vertical) = Self.resolveBinds(for: game)
        let explicit = game?.engine?.controllerMode != nil
        let keysForAuto = PadActions.bindings(game?.engine?.binds)
        let remapNow = Self.remap(of: game)
        let mode = game?.engine?.controllerMode
        queue.async { [self] in
            remap = remapNow
            // The DualSense identity: shown for "DualSense and Xbox", hidden for the other explicit choices, and what Automatic means this session otherwise.
            if hidAvailable {
                // "dinput" only adds the DirectInput joystick: it leaves the DualSense as the session started it (as Automatic does).
                let wantHID = mode == "hid" ? true : ((mode == nil || mode == "dinput") ? autoHID : false)
                if wantHID != hidActive {
                    hidActive = wantHID
                    if wantHID { hidKeepsXInput = true } else { clearHID() }
                    LogStore.shared.log("[pad] the game is now shown \(wantHID ? "a DualSense and the Xbox pad" : "the Xbox pad only")")
                }
            }
            if explicit { auto = nil }                                   // the player chose a mode: automatic stands down
            // Automatic mode may have switched the controller to keyboard and mouse; a refresh of the settings must not undo that.
            let binds = (!explicit && resolved == nil && auto?.usingKeys == true) ? keysForAuto : resolved
            autoKeys = keysForAuto
            guard active, binds != keyboardMouse || vertical != mouseVertical else { return }
            releaseAll()
            keyboardMouse = binds; mouseVertical = vertical
            LogStore.shared.log("[pad] controls changed in the game: " + (binds == nil ? "Xbox controller" : "keyboard and mouse"))
            sample()
        }
    }

    /// Called when the game has ended: nothing stays pressed and the players are shown as disconnected.
    @MainActor func endSession() {
        inSession = false
        setSystemGestures(.enabled)
        PadRumble.shared.stopAll(); PadPointer.shared.reset()
        queue.async { [self] in
            active = false; captured = false; chord = PadChord(); releaseMask = PadReleaseMask()
            hidAvailable = false; autoHID = false
            hidReadyLock.lock(); hidReadyValue = false; hidReadyLock.unlock()
            releaseAll()
            for i in 0..<4 { clearPad(i) }
            clearHID()
            hidActive = false; keyboardMouse = nil; auto = nil
            updateTimer()
        }
    }

    // MARK: Controllers coming and going

    @MainActor private func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshControllers() } })
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.queue.async { [weak self] in self?.pause(true) } })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
            self?.queue.async { [weak self] in self?.pause(false) }
        })
    }

    private var paused = false
    private func pause(_ value: Bool) { paused = value; if value { releaseAll(); PadRumble.shared.stopAll() }; sample() }

    /// iOS binds some controller buttons to system gestures (the DualSense's Create button: a press takes a screenshot, a hold starts a screen recording; the PS button). While a
    /// game runs the game, and Porthole's menu chord, own those buttons, so the app asks iOS to leave them alone; the request is withdrawn when the game ends.
    @MainActor private func setSystemGestures(_ state: GCControllerElement.SystemGestureState) {
        var report: [String] = []
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            let named: [(String, GCControllerButtonInput?)] = [("Home", pad.buttonHome), ("Options", pad.buttonOptions), ("Menu", pad.buttonMenu)]
            for (name, button) in named {
                guard let button, button.isBoundToSystemGesture else { continue }
                button.preferredSystemGestureState = state
                report.append(name)
            }
        }
        if state == .disabled { LogStore.shared.log("[pad] system gestures \(report.isEmpty ? "none bound on these buttons" : "turned off for " + report.joined(separator: ", ") + " while the game runs")") }
    }

    /// The live profiles are captured on the main thread: fetching extendedGamepad on the polling queue gave stale axes on some devices.
    @MainActor private func refreshControllers() {
        if inSession { setSystemGestures(.disabled) }
        let live = GCController.controllers().compactMap { c -> (GCController, GCExtendedGamepad)? in c.extendedGamepad.map { (c, $0) } }
        queue.async { [self] in
            for i in controllers.indices {
                guard let old = controllers[i], !live.contains(where: { $0.0 === old }) else { continue }
                controllers[i] = nil; profiles[i] = nil
                clearPad(i)
                LogStore.shared.log("[pad] player \(i + 1) disconnected")
            }
            for (controller, profile) in live where !controllers.contains(where: { $0 === controller }) {
                guard let i = controllers.firstIndex(where: { $0 == nil }) else { continue }
                controllers[i] = controller; profiles[i] = profile
                LogStore.shared.log("[pad] player \(i + 1) connected: \(controller.vendorName ?? "controller") (\(controller.productCategory))")
            }
            slotLock.lock(); slotSnapshot = controllers; slotLock.unlock()
            updateTimer(); sample()
        }
    }

    private func updateTimer() {
        let needed = active && profiles.contains { $0 != nil }
        if !needed { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    // MARK: Sampling

    private func clearPad(_ i: Int) { if published[i] { winios_gamepad_set_state(Int32(i), nil); published[i] = false } }
    private func clearHID() { if hidPublished { winios_hidpad_set_state(nil); hidPublished = false } }

    private static func axis(_ v: Float) -> Int16 {
        guard v.isFinite else { return 0 }
        let c = max(-1, min(1, v))
        return Int16((c * (c < 0 ? 32768 : 32767)).rounded())
    }
    private static func trigger(_ v: Float) -> UInt8 { v.isFinite ? UInt8((max(0, min(1, v)) * 255).rounded()) : 0 }

    /// About once a second: has the game read the controller? (PadAuto decides; see its notes.)
    private func watchAuto() {
        guard var a = auto, active, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWatch >= 1 else { return }
        lastWatch = now
        let decision = a.update(now: now, reads: winios_gamepad_read_count(), padConnected: profiles[0] != nil)
        auto = a
        guard decision != .none else { return }
        releaseAll()
        let gameID = autoGameID
        switch decision {
        case .useKeys:
            keyboardMouse = autoKeys
            clearPad(0); clearHID()
            LogStore.shared.log("[pad] automatic: the game has not read the controller, so it is used as keyboard and mouse now")
            // Not remembered yet: a run that never got going (a launcher, a wrong program, a long load) must not leave the game starting as keyboard and mouse next time.
            keysSince = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                AppModel.shared.session.showPadNotice("This game isn't reading the controller, so it works as keyboard and mouse. Game details > Controller changes this.")
            }
        case .useXInput:
            keysSince = 0
            keyboardMouse = nil
            LogStore.shared.log("[pad] automatic: the game reads the controller now, back to an Xbox controller")
            Task { @MainActor in
                AppModel.shared.session.showPadNotice("This game reads the controller now, so it works as an Xbox controller.")
                Self.remember(nil, for: gameID)
            }
        case .none: break
        }
    }

    /// Once, after the update that stopped a short or wrong run from setting it: automatic mode's remembered "this game ignores the controller" verdicts are cleared, because some of them
    /// came from runs that never got going (Hollow Knight: Silksong, started from the wrong program, was left starting as keyboard and mouse).
    @MainActor private static func forgetEarlyKeyVerdicts() {
        let key = "f4.padAutoCleared.1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for game in AppModel.shared.games where game.engine?.padAuto != nil {
            AppModel.shared.update(game) { g in var e = g.engine ?? GameEngine(); e.padAuto = nil; g.engine = e.isEmpty ? nil : e }
        }
        LogStore.shared.log("[pad] cleared the remembered keyboard-and-mouse verdicts of earlier runs")
    }

    /// Keeps what automatic mode found with the game, so the next run starts in the right mode without waiting.
    @MainActor private static func remember(_ value: String?, for id: UUID?) {
        guard let id, let game = AppModel.shared.games.first(where: { $0.id == id }), game.engine?.controllerMode == nil, game.engine?.padAuto != value else { return }
        AppModel.shared.update(game) { g in
            var e = g.engine ?? GameEngine()
            e.padAuto = value
            g.engine = e.isEmpty ? nil : e
        }
    }

    /// When automatic mode switched to keyboard and mouse (0 = it has not, or the game has read the controller since).
    private var keysSince: TimeInterval = 0
    private static let rememberKeysAfter: TimeInterval = 180

    /// For the log: how many times the game has asked for the controller (XInput slots and the HID pad), at 10 s, 30 s and then every minute. 0 means the game is not looking at
    /// the controller through either of them (it may be using something else, or waiting for a menu).
    private var readLogAt: TimeInterval = 0, readLogStep = 0
    private func logReads() {
        let now = ProcessInfo.processInfo.systemUptime
        if readLogAt == 0 { readLogAt = now; readLogStep = 0; return }
        let due: TimeInterval = readLogStep == 0 ? 10 : readLogStep == 1 ? 30 : 60 * Double(readLogStep - 1)
        guard now - readLogAt >= due else { return }
        readLogStep += 1
        let pads = profiles.enumerated().compactMap { $0.element == nil ? nil : "player \($0.offset + 1)" }.joined(separator: ", ")
        LogStore.shared.log("[pad] the game has asked for the controller \(winios_gamepad_read_count()) times so far (XInput or HID); mode \(keyboardMouse == nil ? (hidActive ? "HID pad" : "Xbox pad") : "keyboard and mouse"); connected: \(pads.isEmpty ? "none" : pads)")
    }

    private func sample() {
        watchAuto()
        if active { logReads() }
        if keysSince > 0, ProcessInfo.processInfo.systemUptime - keysSince >= Self.rememberKeysAfter {
            keysSince = 0
            let gameID = autoGameID
            Task { @MainActor in Self.remember("keys", for: gameID) }
        }
        for i in 0..<4 {
            guard active, !paused, let pad = profiles[i] else {
                if i == 0, keyboardMouse != nil { releaseAll() }
                clearPad(i)
                if i == 0 { clearHID() }
                continue
            }
            var state = winios_gamepad()
            state.connected = 1
            let buttons: [(GCControllerButtonInput?, UInt16)] = [
                (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002), (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
                (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020), (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
                (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200), (pad.buttonHome, 0x0400),
                (pad.buttonA, 0x1000), (pad.buttonB, 0x2000), (pad.buttonX, 0x4000), (pad.buttonY, 0x8000),
            ]
            for (button, mask) in buttons where button?.isPressed == true { state.buttons |= mask }
            state.left_trigger = Self.trigger(pad.leftTrigger.value); state.right_trigger = Self.trigger(pad.rightTrigger.value)
            state.lx = Self.axis(pad.leftThumbstick.xAxis.value); state.ly = Self.axis(pad.leftThumbstick.yAxis.value)
            state.rx = Self.axis(pad.rightThumbstick.xAxis.value); state.ry = Self.axis(pad.rightThumbstick.yAxis.value)
            if state.buttons != 0 || state.left_trigger > 80 || state.right_trigger > 80
                || abs(Int(state.lx)) > 10_000 || abs(Int(state.ly)) > 10_000 || abs(Int(state.rx)) > 10_000 || abs(Int(state.ry)) > 10_000 {
                activityLock.lock(); activityAt = ProcessInfo.processInfo.systemUptime; activityLock.unlock()
            }
            if i == 0 {
                // The menu chord: two buttons held half a second. Its buttons are kept from the game while both are down.
                let held = state.buttons
                lastButtons = held
                if chord.update(held: held, mask: chordMask, now: ProcessInfo.processInfo.systemUptime) { fireMenuChord() }
                if chord.isDown(held: held, mask: chordMask) { state.buttons &= ~chordMask }
                if !captured { state.buttons = releaseMask.apply(state.buttons) }
            }
            if captured {
                // The menu is open: the game sees a pad with nothing pressed (not a missing one, which some games answer with a pause screen).
                if i == 0 { releaseAll() }
                var neutral = winios_gamepad(); neutral.connected = 1
                if i == 0, hidActive {
                    publishHID(neutral, pad: pad)
                    if !hidKeepsXInput { clearPad(0); continue }
                }
                winios_gamepad_set_state(Int32(i), &neutral); published[i] = true
                continue
            }
            if i == 0, let binds = keyboardMouse {
                // Keyboard and mouse: the pad is not an Xbox pad for this game.
                feed(state, binds: binds)
                clearPad(0); clearHID()
                continue
            }
            if let r = remap {
                let out = r.apply(buttons: state.buttons, lt: state.left_trigger, rt: state.right_trigger)
                state.buttons = out.buttons; state.left_trigger = out.lt; state.right_trigger = out.rt
            }
            if i == 0, hidActive {
                publishHID(state, pad: pad)
                if !hidKeepsXInput { clearPad(0); continue }
            }
            winios_gamepad_set_state(Int32(i), &state); published[i] = true
        }
    }

    /// Player 1 as the HID controller: the Xbox sample plus what only a HID report carries (the digital trigger bits, the touchpad click, the battery).
    private func publishHID(_ state: winios_gamepad, pad: GCExtendedGamepad) {
        var hid = winios_hidpad()
        hid.connected = 1
        hid.buttons = UInt32(state.buttons)
        hid.lx = state.lx; hid.ly = state.ly; hid.rx = state.rx; hid.ry = state.ry
        hid.left_trigger = state.left_trigger; hid.right_trigger = state.right_trigger
        if state.left_trigger > 25 { hid.buttons |= WINIOS_HIDPAD_L2 }
        if state.right_trigger > 25 { hid.buttons |= WINIOS_HIDPAD_R2 }
        let touchpad = (pad as? GCDualSenseGamepad)?.touchpadButton ?? (pad as? GCDualShockGamepad)?.touchpadButton
        if touchpad?.isPressed == true { hid.buttons |= WINIOS_HIDPAD_TOUCHPAD }
        if hidBatteryCountdown <= 0 {
            hidBatteryCountdown = 250
            if let battery = pad.controller?.battery, battery.batteryState != .unknown {
                let level = UInt8(max(0, min(100, ((battery.batteryLevel.isFinite ? battery.batteryLevel : 0) * 100).rounded())))
                hidBattery = (level, battery.batteryState == .charging ? 1 : battery.batteryState == .full ? 2 : 0)
            } else { hidBattery = (UInt8(WINIOS_HIDPAD_BATTERY_UNKNOWN), 0) }
        }
        hidBatteryCountdown -= 1
        hid.battery = hidBattery.level; hid.charging = hidBattery.charging
        winios_hidpad_set_state(&hid); hidPublished = true
    }

    // MARK: Keyboard and mouse

    private var heldKeys = Set<Int32>()
    private var heldMouse = Set<Int>()
    private var pressedNow = Set<String>()
    private var lastFeed = 0.0
    private var mouseCarryX = 0.0, mouseCarryY = 0.0

    private func setKey(_ vk: Int32, _ down: Bool) {
        if down { if heldKeys.insert(vk).inserted { winios_post_key(vk, 1) } }
        else if heldKeys.remove(vk) != nil { winios_post_key(vk, 0) }
    }
    private func setMouse(_ b: Int, _ down: Bool) {
        let (downFlag, upFlag): (UInt32, UInt32) = b == 0 ? (0x2, 0x4) : b == 1 ? (0x8, 0x10) : (0x20, 0x40)
        if down { if heldMouse.insert(b).inserted { winios_pointer(0, 0, downFlag, 0) } }
        else if heldMouse.remove(b) != nil { winios_pointer(0, 0, upFlag, 0) }
    }
    private func releaseAll() {
        for k in heldKeys { winios_post_key(k, 0) }; heldKeys.removeAll()
        for b in heldMouse { setMouse(b, false) }; heldMouse.removeAll()
        pressedNow.removeAll(); mouseCarryX = 0; mouseCarryY = 0
    }

    private func apply(_ action: PadAction, down: Bool, edge: Bool) {
        switch action {
        case .none: break
        case .key(let vk): setKey(vk, down)
        case .mouse(let b): setMouse(b, down)
        case .wheel(let delta): if down && edge { winios_pointer(0, 0, 0x800, UInt32(bitPattern: delta)) }
        case .lookToggle: break
        }
    }

    private func feed(_ s: winios_gamepad, binds: [String: String]) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastFeed == 0 ? 0.004 : min(0.05, now - lastFeed)
        lastFeed = now
        let digital: [(String, Bool)] = [
            ("A", s.buttons & 0x1000 != 0), ("B", s.buttons & 0x2000 != 0), ("X", s.buttons & 0x4000 != 0), ("Y", s.buttons & 0x8000 != 0),
            ("LB", s.buttons & 0x0100 != 0), ("RB", s.buttons & 0x0200 != 0), ("LT", s.left_trigger > 77), ("RT", s.right_trigger > 77),
            ("L3", s.buttons & 0x0040 != 0), ("R3", s.buttons & 0x0080 != 0), ("Menu", s.buttons & 0x0010 != 0), ("View", s.buttons & 0x0020 != 0),
            ("D\u{2191}", s.buttons & 0x0001 != 0), ("D\u{2193}", s.buttons & 0x0002 != 0), ("D\u{2190}", s.buttons & 0x0004 != 0), ("D\u{2192}", s.buttons & 0x0008 != 0),
        ]
        for (name, down) in digital {
            let edge = down && !pressedNow.contains(name)
            if down { pressedNow.insert(name) } else { pressedNow.remove(name) }
            apply(PadActions.action(binds[name]), down: down, edge: edge)
        }
        // Sticks: a key stick holds two keys (eight directions), the mouse stick moves the pointer.
        func stick(_ x: Int16, _ y: Int16, mode: String) {
            let fx = Double(x) / 32768, fy = Double(y) / 32768
            let keys: (up: Int32, down: Int32, left: Int32, right: Int32)? = mode == "wasd" ? (0x57, 0x53, 0x41, 0x44) : mode == "arrows" ? (0x26, 0x28, 0x25, 0x27) : nil
            if let k = keys {
                let dead = 0.35
                setKey(k.up, fy > dead); setKey(k.down, fy < -dead); setKey(k.left, fx < -dead); setKey(k.right, fx > dead)
            } else if mode == "mouse" {
                let mag = (fx * fx + fy * fy).squareRoot()
                guard mag > 0.12 else { return }
                let scaled = min(1, (mag - 0.12) / 0.88)
                let speed = 1100.0 * scaled * scaled / mag * dt          // counts per second at full push, eased
                mouseCarryX += fx * speed
                mouseCarryY += -fy * speed * mouseVertical
                let dx = Int(mouseCarryX), dy = Int(mouseCarryY)
                mouseCarryX -= Double(dx); mouseCarryY -= Double(dy)
                if dx != 0 || dy != 0 { PadPointer.shared.move(dx: dx, dy: dy) }
            }
        }
        stick(s.lx, s.ly, mode: binds["LS"] ?? "wasd")
        stick(s.rx, s.ry, mode: binds["RS"] ?? "mouse")
    }
}
