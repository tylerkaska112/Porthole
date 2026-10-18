// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var session: SessionController
    @State private var reporting: Game?
    @State private var editingBinds = false
    @EnvironmentObject var model: AppModel

    /// Installers have nothing to report on, so they get no menu entry.
    private var reportAction: (() -> Void)? {
        guard let game = session.game, game.installer != true else { return nil }
        return { reporting = game }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GameSurface(state: session.state, dockStatus: session.padNotice ?? session.dockStatus, layout: session.activeLayout, customLayout: session.activeTouchLayout, lookSensitivity: session.lookSensitivity, onAdjustLook: { session.adjustLook(by: $0) }, onSwitchLayout: { session.switchLayout(to: $0) },
                        onClose: { session.requestClose() },
                        onBack: { session.dismiss() },
                        onReport: reportAction, onEditBinds: { editingBinds = true },
                        onCreateLayout: { session.createLiveLayout(from: $0) }, onLayoutChanged: { session.saveLiveTouchLayout($0) }, gameName: session.game?.name, steamAppID: session.game.flatMap { $0.steamAppID ?? $0.dockAppID })
                .ignoresSafeArea()
        }
        .statusBarHidden(true)
        // A bind set changed in the game (the editor or the set picker): the controls and the controller binds follow at once.
        .onChange(of: model.games) { _, _ in session.bindSetsChanged() }
        .sheet(isPresented: $editingBinds) {
            if let g = session.game { InGameBindsSheet(gameID: g.id).environmentObject(model).environmentObject(session).preferredColorScheme(Theme.scheme) }
        }
        // The game keeps running behind the form. The numbers are the session so far, read when the form opens.
        .sheet(item: $reporting) { game in
            ReportSheet(game: game, liveStats: Telemetry.shared.sessionStats()).preferredColorScheme(Theme.scheme)
        }
    }
}

/// The surface the runtime draws into. DXMT renders into a CAMetalLayer owned by `MetalHostView`, which must sit ABOVE the SwiftUI hierarchy
/// (window level, as the runtime expects) or the black SwiftUI background hides it. This view positions it and turns touches into mouse events;
/// the on-screen buttons live in `GameHUDView`, another window-level view above the Metal view.
struct GameSurface: UIViewRepresentable {
    let state: SessionController.State
    var dockStatus: String? = nil
    var layout: ControlLayout = .standard
    var customLayout: TouchLayout? = nil
    var lookSensitivity: Double = 2.4
    var onAdjustLook: (Double) -> Void = { _ in }
    var onSwitchLayout: (ControlLayout) -> Void = { _ in }
    let onClose: () -> Void
    let onBack: () -> Void
    var onReport: (() -> Void)? = nil
    var onEditBinds: (() -> Void)? = nil
    var onCreateLayout: ((TouchLayout) -> Void)? = nil
    var onLayoutChanged: ((TouchLayout) -> Void)? = nil
    /// Shown in the in-game menu's header.
    var gameName: String? = nil
    var steamAppID: Int? = nil

    func makeUIView(context: Context) -> GameSurfaceView {
        let v = GameSurfaceView()
        v.hud.onClose = onClose
        v.hud.onBack = onBack
        v.hud.onReport = onReport
        v.hud.onSwitchLayout = onSwitchLayout
        v.hud.onKeyboard = { [weak v] in v?.toggleKeyboard() }
        v.hud.padPointer.viewPoint = { [weak v] x, y in v?.hudPoint(forDesktop: x, y) }
        v.hud.padPointer.desktopSize = { [weak v] in v?.desktopSize() ?? (1280, 720) }
        v.hud.onEditBinds = onEditBinds; v.hud.onCreateLayout = onCreateLayout; v.hud.onLayoutChanged = onLayoutChanged
        return v
    }
    func updateUIView(_ view: GameSurfaceView, context: Context) {
        view.hud.onClose = onClose
        view.hud.onBack = onBack
        view.hud.onReport = onReport
        view.hud.onSwitchLayout = onSwitchLayout
        view.hud.onEditBinds = onEditBinds; view.hud.onCreateLayout = onCreateLayout; view.hud.onLayoutChanged = onLayoutChanged
        view.hud.update(state: state)
        view.hud.setLayout(layout)
        view.hud.setCustomLayout(customLayout)
        view.hud.lookSensitivity = CGFloat(lookSensitivity)
        view.hud.onAdjustLook = onAdjustLook
        view.hud.setStatus(dockStatus)
        view.hud.gameName = gameName
        view.hud.steamAppID = steamAppID
    }
    static func dismantleUIView(_ view: GameSurfaceView, coordinator: ()) { view.detach() }
}

final class MetalHostView: UIView {
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Private, same as Madeira: lets presents run free of display-sync scheduling.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) { metalLayer.perform(syncSel, with: NSNumber(value: false)) }
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) { metalLayer.perform(fpsSel, with: UIScreen.main.maximumFramesPerSecond as NSNumber) }
        metalLayer.drawableSize = CGSize(width: 800, height: 600)   // DXMT sets the real size later
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class GameSurfaceView: UIView, UIKeyInput, PointerSink {
    let hud = GameHUDView.shared
    private static var layerRegistered = false
    // MOUSEEVENTF_*; the runtime only applies a position when MOVE comes with ABSOLUTE (0x8000), otherwise (x, y) is a relative delta.
    private let flagMove: UInt32 = 0x1 | 0x8000, ldown: UInt32 = 0x2 | 0x8000, lup: UInt32 = 0x4 | 0x8000, rdown: UInt32 = 0x8 | 0x8000, rup: UInt32 = 0x10 | 0x8000
    private let flagWheel: UInt32 = 0x800
    private var gestureLogs = 0
    private(set) static var touchCount = 0
    private let engine = TouchGestureEngine()
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1
    private var tickTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true       // two-finger tap and pinch
        backgroundColor = .clear
        engine.sink = self
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The guest display's size right now (a game's mode change really resizes it); falls back to the desktop we asked for.
    private func guestSize() -> (w: CGFloat, h: CGFloat) {
        var w: Int32 = 0, h: Int32 = 0
        winios_screen_size(&w, &h)
        guard w > 0, h > 0 else { return (CGFloat(SessionController.desktopWidth), CGFloat(SessionController.desktopHeight)) }
        return (CGFloat(w), CGFloat(h))
    }

    /// The Wine desktop is aspect-fitted into our bounds.
    private func fitRect() -> CGRect {
        let (dw, dh) = guestSize()
        let s = min(bounds.width / dw, bounds.height / dh)
        let size = CGSize(width: dw * s, height: dh * s)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: iOS keyboard (typed text goes to the game as key presses)
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { HUDKeys.type(text) }
    func deleteBackward() { HUDKeys.tap(VK.backspace) }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    func toggleKeyboard() {
        if isFirstResponder { _ = resignFirstResponder() } else { _ = becomeFirstResponder() }
    }

    func detach() {
        raiseTimer?.invalidate(); raiseTimer = nil
        MetalHostView.shared.removeFromSuperview()
        hud.removeFromSuperview()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); attach(reason: "attach"); observeDisplay(); keepHUDOnTop() }

    private var raiseTimer: Timer?
    private var raises = 0

    /// In a Steam (desktop) session the runtime adds the game's own picture to the window the first time the desktop renders, which is AFTER our overlay
    /// was put on top. Nothing re-orders the window then, so the overlay stayed buried until a rotation made the screen lay out again. Checking twice a
    /// second costs nothing and puts the overlay back on top as soon as something is added above it.
    private func keepHUDOnTop() {
        guard raiseTimer == nil else { return }
        raiseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let window = self.window, window.subviews.last !== self.hud else { return }
            window.bringSubviewToFront(self.hud)
            self.raises += 1
            if self.raises <= 5 { LogStore.shared.log("[f4-hud] raised above a view added after it") }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        attach(reason: "layout")
        settleSoon("layout")
    }

    private static var observing = false
    private static var lastApplied = ""
    private var settleItem: DispatchWorkItem?

    /// A guest display-mode change (a game picking its resolution) and a rotation both re-lay-out the surface. UIKit can report pre-rotation bounds
    /// while the rotation animates, so every trigger also re-applies once more ~0.3 s later (the last one wins).
    private func observeDisplay() {
        guard !Self.observing else { return }
        Self.observing = true
        NotificationCenter.default.addObserver(forName: Notification.Name("MadeiraDisplayModeChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.attach(reason: "mode-changed"); self?.settleSoon("mode-changed")
        }
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.attach(reason: "orientation"); self?.settleSoon("orientation")
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    private func settleSoon(_ reason: String) {
        settleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.attach(reason: "settle:\(reason)") }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func attach(reason: String = "attach") {
        guard let window else { return }
        let host = MetalHostView.shared
        // Window level, on top of SwiftUI (see GameSurface); the HUD goes above the Metal view. Only touch the order when it is actually wrong:
        // re-ordering on every layout pass made the HUD flicker.
        if host.superview !== window { host.removeFromSuperview(); window.addSubview(host); GameHUDView.attaches += 1 }
        if hud.superview !== window { hud.removeFromSuperview(); hud.frame = window.bounds; window.addSubview(hud); GameHUDView.attaches += 1 }
        // A DESKTOP session (Steam games through Dock, MADEIRA_DESKTOP=1): Wine's compositor view holds the game's own Metal layer, so OUR black
        // Metal host must stay out of the way. Pulling it in front of the compositor on every layout pass buried the game on rotation.
        // Only the HUD is kept on top there.
        let desktopSession = getenv("MADEIRA_DESKTOP").map { String(cString: $0) == "1" } ?? false
        host.isHidden = desktopSession
        let order = window.subviews
        if desktopSession {
            if order.last !== hud { window.bringSubviewToFront(hud) }
        } else if order.last !== hud || (order.count > 1 && order[order.count - 2] !== host) {
            window.bringSubviewToFront(host); window.bringSubviewToFront(hud)
        }
        let fit = fitRect()
        host.frame = convert(fit, to: window)
        let full = convert(bounds, to: window)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        // A desktop session (Steam games through Dock): tell the compositor where the desktop goes, in the compositor view's own points.
        winios_set_desktop_rect(fit.minX - bounds.minX, fit.minY - bounds.minY, fit.width, fit.height, 1)
        let (gw, gh) = guestSize()
        let line = String(format: "guest=%.0fx%.0f bounds=%.0fx%.0f -> rect=(%.0f,%.0f %.0fx%.0f)", gw, gh, bounds.width, bounds.height, fit.minX, fit.minY, fit.width, fit.height)
        if line != Self.lastApplied { Self.lastApplied = line; LogStore.shared.log("[display] apply reason=\(reason) \(line)") }
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)   // must precede the first D3D11 swapchain
        }
    }

    /// View point -> Wine desktop pixels (the desktop is aspect-fitted into the view).
    private func desktopPoint(_ p: CGPoint) -> (Int32, Int32) {
        let r = fitRect()
        let (gw, gh) = guestSize()
        let x = (p.x - r.minX) / r.width * gw
        let y = (p.y - r.minY) / r.height * gh
        return (Int32(max(0, min(gw - 1, x))), Int32(max(0, min(gh - 1, y))))
    }

    /// A Wine desktop pixel -> a point in the HUD (the inverse of `desktopPoint`), for the controller's pointer arrow.
    func hudPoint(forDesktop x: Double, _ y: Double) -> CGPoint? {
        let r = fitRect()
        let (gw, gh) = guestSize()
        guard gw > 0, gh > 0, r.width > 0 else { return nil }
        return convert(CGPoint(x: r.minX + CGFloat(x) / gw * r.width, y: r.minY + CGFloat(y) / gh * r.height), to: hud)
    }
    func desktopSize() -> (Double, Double) { let (w, h) = guestSize(); return (Double(w), Double(h)) }

    // MARK: Touches -> TouchGestureEngine -> PointerSink

    private func id(for t: UITouch) -> Int {
        let key = ObjectIdentifier(t)
        if let existing = touchIDs[key] { return existing }
        defer { nextTouchID += 1 }
        touchIDs[key] = nextTouchID
        return nextTouchID
    }

    // First-person look: a drag anywhere not on a button turns into relative mouse movement.
    private var lookTouch: UITouch?
    private var lookLast = CGPoint.zero
    private var lookRemainder = CGPoint.zero

    // The menu opens with a swipe in from the right edge (or a tap on the handle there). Touches that start in that strip never reach the game.
    private var menuSwipeTouch: UITouch?
    private var menuSwipeStart = CGPoint.zero
    private var menuSwipeFired = false
    private static let menuEdge: CGFloat = 28

    /// Starts following a touch that began in the right-edge strip and returns the touches left for the game.
    private func takeMenuSwipe(_ touches: Set<UITouch>) -> Set<UITouch> {
        guard menuSwipeTouch == nil, hud.menuAvailable else { return touches }
        for t in touches {
            let p = t.location(in: self)
            if p.x >= bounds.maxX - Self.menuEdge {
                menuSwipeTouch = t; menuSwipeStart = p; menuSwipeFired = false
                return touches.subtracting([t])
            }
        }
        return touches
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        hud.noteTouch()
        let touches = takeMenuSwipe(touches)
        if touches.isEmpty { return }
        if hud.lookActive {
            if lookTouch == nil, let t = touches.first { lookTouch = t; lookLast = t.location(in: self); lookRemainder = .zero }
            return
        }
        engine.primary = hud.rightMode ? .right : .left
        for t in touches { Self.touchCount += 1; engine.began(id(for: t), at: t.location(in: self), time: t.timestamp) }
        if tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.engine.tick(time: ProcessInfo.processInfo.systemUptime)
                if !self.engine.isTouching { self.tickTimer?.invalidate(); self.tickTimer = nil }
            }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let st = menuSwipeTouch, touches.contains(st) {
            if !menuSwipeFired, menuSwipeStart.x - st.location(in: self).x > 18 { menuSwipeFired = true; hud.openMenu() }
        }
        let touches = touches.filter { $0 !== menuSwipeTouch }
        if touches.isEmpty { return }
        if let lt = lookTouch {
            if touches.contains(lt) {
                let p = lt.location(in: self)
                let fx = (p.x - lookLast.x) * hud.lookSensitivity + lookRemainder.x, fy = (p.y - lookLast.y) * hud.lookSensitivity + lookRemainder.y
                let dx = fx.rounded(.towardZero), dy = fy.rounded(.towardZero)
                lookRemainder = CGPoint(x: fx - dx, y: fy - dy); lookLast = p
                if dx != 0 || dy != 0 { winios_pointer(Int32(dx), Int32(dy), 0x1, 0) }   // MOVE without ABSOLUTE = relative
            }
            return
        }
        for t in touches { if let i = touchIDs[ObjectIdentifier(t)] { engine.moved(i, to: t.location(in: self), time: t.timestamp) } }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let edge = menuSwipeTouch
        if let st = edge, touches.contains(st) {
            let p = st.location(in: self)
            // A tap on the handle (no swipe) opens the menu as well.
            if !menuSwipeFired, abs(p.x - menuSwipeStart.x) < 10, abs(p.y - menuSwipeStart.y) < 10, hud.handleBand(contains: st.location(in: hud)) { hud.openMenu() }
            menuSwipeTouch = nil
        }
        let touches = touches.filter { $0 !== edge }
        if touches.isEmpty { return }
        if let lt = lookTouch, touches.contains(lt) { lookTouch = nil; return }
        if lookTouch != nil || hud.lookActive { return }
        for t in touches {
            if let i = touchIDs.removeValue(forKey: ObjectIdentifier(t)) { engine.ended(i, at: t.location(in: self), time: t.timestamp) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let st = menuSwipeTouch, touches.contains(st) { menuSwipeTouch = nil }
        if let lt = lookTouch, touches.contains(lt) { lookTouch = nil; return }
        for t in touches { if let i = touchIDs.removeValue(forKey: ObjectIdentifier(t)) { engine.cancelled(i) } }
    }

    // MARK: PointerSink

    private func post(_ p: CGPoint, _ flags: UInt32, data: UInt32 = 0) {
        let (x, y) = desktopPoint(p)
        hud.cursor = (x, y)
        PadPointer.shared.set(x: x, y: y)
        winios_pointer(x, y, flags, data)
    }
    private func logGesture(_ text: String) {
        if gestureLogs < 40 { gestureLogs += 1; LogStore.shared.log("[f4-touch] \(text)") }
    }

    func pointerMove(_ p: CGPoint) { post(p, flagMove) }
    func pointerPress(_ b: MouseButton, at p: CGPoint) {
        logGesture("press \(b) at \(desktopPoint(p))")
        post(p, flagMove); post(p, b == .left ? ldown : rdown)
    }
    func pointerRelease(_ b: MouseButton, at p: CGPoint) {
        logGesture("release \(b)")
        post(p, b == .left ? lup : rup)
    }
    func pointerClick(_ b: MouseButton, at p: CGPoint) {
        logGesture("click \(b) at \(desktopPoint(p))")
        post(p, flagMove); post(p, b == .left ? ldown : rdown)
        // hold the button for 50 ms so a game that samples the mouse once per frame sees it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.post(p, b == .left ? self!.lup : self!.rup) }
    }
    func pointerWheel(_ delta: Int32, at p: CGPoint) {
        logGesture("wheel \(delta)")
        post(p, flagWheel, data: UInt32(bitPattern: delta))
    }
}
