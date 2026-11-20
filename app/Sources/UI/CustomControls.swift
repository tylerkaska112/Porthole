// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// The on-screen controls of a bind set's touch layout, drawn over the game. Each control is a button or stick placed by its fractions of the screen.
/// Keys and mouse buttons go through the same paths as the built-in controls (`HUDKeys`, `winios_pointer`).
///
/// In the editing state (`editing`) the controls are edited where they are, with the game behind them: drag a control to move it (it snaps to the centre lines and to
/// the other controls, with guide lines), drag the dot on its corner or pinch to resize it, tap to select and tap empty space to let go. Every change goes to `onChange`.
/// Leave the editing state to use the controls as they are, which is how a layout is tried in the game.
final class CustomControlsView: UIView, UIGestureRecognizerDelegate {
    private struct Placed { var spec: TouchControlSpec; let view: UIView; let cx: NSLayoutConstraint; let cy: NSLayoutConstraint }
    private var placed: [Placed] = []
    private var releasables: [() -> Void] = []
    private(set) var layout: TouchLayout?
    /// Called after every edit with the layout as it now is (already checked); the owner saves it.
    var onChange: ((TouchLayout) -> Void)?
    /// Called when the selection changes, with the controls now selected (empty = nothing selected).
    var onSelection: (([TouchControlSpec]) -> Void)?
    /// Called when the Select mode (taps add to the selection) is switched on or off.
    var onSelectMode: (() -> Void)?
    /// Called after every edit, so a panel showing the selected control can refresh (its size changed by a pinch, say).
    var onEdited: (() -> Void)?
    /// The on-screen pad's state from the layout's pad controls (mixed layouts), whenever one changes. The HUD merges it with the game controller and hands it to PadInput.
    var onPad: ((VirtualPadSample) -> Void)?
    /// A layout's Keys button asks for the full keyboard (the HUD owns it).
    var onToggleKeyboard: (() -> Void)?
    private var padMixer = TouchPadMixer()
    /// Whether the layout has controls that drive the pad (the game then sees an Xbox controller).
    var usesPad: Bool { layout?.controls.contains { $0.pad != nil } == true }
    private func padChanged(_ id: UUID, _ sample: VirtualPadSample) {
        padMixer.set(sample, for: id.uuidString)
        onPad?(padMixer.merged)
    }
    /// Whether dragging on the screen currently looks around (for the look button's face), and what the look button does.
    var lookProvider: (() -> Bool)?
    var onToggleLook: (() -> Void)?
    func refreshLookButtons() { placed.forEach { ($0.view as? CustomLookButton)?.show(lookOn: lookProvider?() ?? false) } }
    /// The selected controls, in the order they were picked. Most of the editor works on one control (`selectedID`, which is nil while several are selected); the group tools use all of them.
    private(set) var selectedIDs: [UUID] = []
    var selectedID: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs[0] : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    var selectedSpec: TouchControlSpec? { selectedID.flatMap { id in layout?.controls.first { $0.id == id } } }
    var selectedSpecs: [TouchControlSpec] { layout?.controls.filter { selectedIDs.contains($0.id) } ?? [] }
    /// The selected controls' rectangle in this view's own points (nil = nothing selected), so a panel can keep out of its way.
    var selectedFrame: CGRect? { placed.filter { selectedIDs.contains($0.spec.id) }.map(\.view.frame).reduce(nil as CGRect?) { $0?.union($1) ?? $1 } }
    /// While on, a tap on a control adds it to the selection (or takes it out) instead of choosing it alone.
    var multiSelect = false { didSet { if multiSelect != oldValue { onSelectMode?() } } }
    private let outline = CAShapeLayer(), rings = CAShapeLayer(), guides = CAShapeLayer(), handle = CAShapeLayer(), marquee = CAShapeLayer()
    /// While editing: a red ring round controls that sit on top of another one, an orange dashed ring round ones too small to hit (LayoutCheck).
    private let warnRed = CAShapeLayer(), warnAmber = CAShapeLayer()
    /// Where the game's picture will be (the layout's placement, or what automatic does), drawn behind the controls so they can be planned around it. Only where `guestSize` is the picture's real
    /// or a stand-in shape (the sandbox); in a game the picture itself shows, and moves as the placement changes.
    private let pictureLayer = CAShapeLayer(), pictureText = CATextLayer()
    /// While editing: the part of the screen the right thumb rests and drags in (`TouchLayout.lookZone`), drawn so controls can be kept out of it.
    private let lookLayer = CAShapeLayer(), lookText = CATextLayer()
    var drawsPictureOutline = false { didSet { updatePictureOutline() } }
    var guestSize = CGSize(width: 1280, height: 720) { didSet { updatePictureOutline() } }
    /// Earlier states of the layout while editing, for Undo and Redo (cleared when editing stops).
    private var undoStack: [TouchLayout] = [], redoStack: [TouchLayout] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Called when Undo or Redo become possible or impossible.
    var onHistory: (() -> Void)?

    private func remember() {
        guard let l = layout else { return }
        if undoStack.last != l { undoStack.append(l); if undoStack.count > 60 { undoStack.removeFirst() } }
        redoStack.removeAll(); onHistory?()
    }

    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }
    private func step(from: inout [TouchLayout], to: inout [TouchLayout]) {
        guard let current = layout, let previous = from.popLast() else { return }
        to.append(current)
        layout = previous
        rebuildKeepingSelection(); commit(); onHistory?()
    }
    /// `move` carries the whole selection: where each control was when the finger went down, and which one the finger holds. `box` draws a rectangle across empty space and selects what it covers.
    private enum Drag { case move(primary: UUID, grab: CGSize, from: [TouchControlSpec]), resize(id: UUID), box(from: CGPoint, keep: [UUID]) }
    private var drag: Drag?
    private var pinchStart: (id: UUID, size: Double)?
    private var pinchGroup: [TouchControlSpec]?

    /// Every stick of the layout floats (FloatingStick), except while the layout is being edited.
    var floatingSticks = false { didSet { applyFloating() } }
    private func applyFloating() {
        placed.forEach {
            ($0.view as? CustomStick)?.floating = floatingSticks && !editing
            ($0.view as? CustomPadStick)?.floating = floatingSticks && !editing
        }
    }

    var editing = false {
        didSet {
            guard editing != oldValue else { return }
            applyFloating()
            release()
            if !editing { selectedIDs = []; multiSelect = false; onSelection?([]) }
            if editing { undoStack.removeAll(); redoStack.removeAll(); onHistory?() }
            [outline, rings, handle, guides, marquee, warnRed, warnAmber].forEach { $0.isHidden = !editing }
            marquee.path = nil
            lookLayer.isHidden = !editing; lookText.isHidden = !editing
            gestureRecognizers?.forEach { $0.isEnabled = editing }
            placed.forEach { $0.view.alpha = editing ? 1 : CGFloat(layout?.opacity ?? 1) }      // the editor shows every control fully
            placed.forEach { if $0.spec.isOverlay { $0.view.isHidden = !editing } }          // a spot for an overlay is drawn only in the editor
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Left-handed was switched (Settings, or the in-game menu): the controls go to the other side at once.
        NotificationCenter.default.addObserver(forName: TouchHandedness.changed, object: nil, queue: .main) { [weak self] _ in self?.setNeedsLayout() }
        rings.fillColor = UIColor.clear.cgColor; rings.strokeColor = UIColor(white: 1, alpha: 0.55).cgColor; rings.lineWidth = 1.5; rings.lineDashPattern = [4, 4]
        outline.fillColor = UIColor.clear.cgColor; outline.strokeColor = UIColor.systemYellow.cgColor; outline.lineWidth = 3
        handle.fillColor = UIColor.systemYellow.cgColor; handle.strokeColor = UIColor.black.withAlphaComponent(0.6).cgColor; handle.lineWidth = 1.5
        guides.fillColor = UIColor.clear.cgColor; guides.strokeColor = UIColor.systemCyan.cgColor; guides.lineWidth = 1; guides.lineDashPattern = [5, 4]
        marquee.fillColor = UIColor.systemYellow.withAlphaComponent(0.10).cgColor; marquee.strokeColor = UIColor.systemYellow.cgColor; marquee.lineWidth = 1.5; marquee.lineDashPattern = [6, 4]
        warnRed.fillColor = UIColor.clear.cgColor; warnRed.strokeColor = UIColor.systemRed.cgColor; warnRed.lineWidth = 3
        warnAmber.fillColor = UIColor.clear.cgColor; warnAmber.strokeColor = UIColor.systemOrange.cgColor; warnAmber.lineWidth = 2.5; warnAmber.lineDashPattern = [5, 4]
        [rings, warnAmber, warnRed, outline, handle, guides, marquee].forEach { $0.isHidden = true; layer.addSublayer($0) }
        pictureLayer.fillColor = UIColor(white: 1, alpha: 0.07).cgColor; pictureLayer.strokeColor = UIColor(white: 1, alpha: 0.4).cgColor; pictureLayer.lineWidth = 1.5; pictureLayer.lineDashPattern = [8, 6]
        pictureText.fontSize = 13; pictureText.foregroundColor = UIColor(white: 1, alpha: 0.5).cgColor; pictureText.alignmentMode = .center; pictureText.contentsScale = UIScreen.main.scale
        pictureText.string = "Game picture"; pictureLayer.isHidden = true; pictureText.isHidden = true
        layer.insertSublayer(pictureLayer, at: 0); layer.insertSublayer(pictureText, at: 1)
        lookLayer.fillColor = UIColor.systemTeal.withAlphaComponent(0.07).cgColor; lookLayer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.55).cgColor; lookLayer.lineWidth = 1.5; lookLayer.lineDashPattern = [3, 6]
        lookText.fontSize = 12; lookText.foregroundColor = UIColor.systemTeal.withAlphaComponent(0.9).cgColor; lookText.alignmentMode = .center; lookText.contentsScale = UIScreen.main.scale
        lookText.string = "Right thumb: drag here to look or move the mouse"; lookLayer.isHidden = true; lookText.isHidden = true
        layer.insertSublayer(lookLayer, at: 2); layer.insertSublayer(lookText, at: 3)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:))), pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        // Only while editing: a recogniser on this view also sees touches that land on the sticks and buttons inside it, and a pan that begins
        // there cancels the stick's touches (the stick then only worked as a tap).
        [pan, pinch, tap].forEach { $0.delegate = self; $0.isEnabled = false; addGestureRecognizer($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer }

    func apply(_ new: TouchLayout?) {
        guard new != layout else { return }
        release()
        layout = new
        build()
    }

    private func build() {
        placed.forEach { $0.view.removeFromSuperview() }
        placed = []; releasables = []
        padMixer.clear()
        defer { onPad?(padMixer.merged) }          // a rebuilt layout starts with nothing pressed
        guard let layout else { return }
        ControlHaptics.enabled = layout.haptics
        for spec in layout.controls {
            guard let v = makeView(spec) else { continue }
            v.translatesAutoresizingMaskIntoConstraints = false
            v.alpha = editing ? 1 : CGFloat(layout.opacity)
            if spec.isOverlay { v.isHidden = !editing; v.isUserInteractionEnabled = false }
            if let control = v as? UIControl { control.addAction(UIAction { [weak self] _ in if self?.editing == false { ControlHaptics.tap() } }, for: .touchDown) }
            addSubview(v)
            let cx = v.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 0), cy = v.centerYAnchor.constraint(equalTo: topAnchor, constant: 0)
            NSLayoutConstraint.activate([cx, cy])
            placed.append(Placed(spec: spec, view: v, cx: cx, cy: cy))
        }
        applyFloating()
        let still = selectedIDs.filter { id in placed.contains { $0.spec.id == id } }
        if still != selectedIDs { selectedIDs = still; onSelection?(selectedSpecs) }
        [rings, warnAmber, warnRed, outline, handle, guides, marquee].forEach { layer.addSublayer($0) }          // above the controls
        refreshLookButtons()
        setNeedsLayout()
    }

    /// The rectangle the fractions refer to: the screen without its safe-area insets.
    private var field: CGRect {
        let s = safeAreaInsets
        return CGRect(x: s.left, y: s.top, width: bounds.width - s.left - s.right, height: bounds.height - s.top - s.bottom)
    }

    /// How the layout's fractions land on this screen (a big screen keeps the controls phone-sized and close to their edges; see `ControlSpace`).
    private var space: ControlSpace { ControlSpace(field: field.size, mirrored: TouchHandedness.leftHanded) }

    /// The button size setting (TouchButtonSize): how much bigger or smaller than their stored size the controls are drawn. Read when the layout is built (a change in the editor
    /// rebuilds it), so the controls, their outlines and the editing maths all agree.
    private var sizeFactor: CGFloat { CGFloat(TouchButtonSize.factor(setting: UserDefaults.standard.string(forKey: TouchButtonSize.key), isPad: UIDevice.current.userInterfaceIdiom == .pad)) }
    /// How wide a control is drawn, in points (an overlay's spot is not a button: its size is as stored).
    private func drawn(_ spec: TouchControlSpec) -> CGFloat { spec.isOverlay ? CGFloat(spec.size) : CGFloat(spec.size) * sizeFactor }
    /// The stored size that makes a control look `width` points wide.
    private func stored(fromDrawn width: Double, for spec: TouchControlSpec) -> Double { spec.isOverlay ? width : width / Double(sizeFactor) }

    /// The setting was changed while this layout is on the screen (the editor's Options): draw the controls again at the new size.
    func buttonSizeChanged() { rebuildKeepingSelection() }

    private func point(of spec: TouchControlSpec) -> CGPoint {
        let f = field, p = space.point(x: spec.x, y: spec.y)
        return CGPoint(x: f.minX + p.x, y: f.minY + p.y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for p in placed {
            let c = point(of: p.spec)
            p.cx.constant = c.x; p.cy.constant = c.y
        }
        updateOutline()
        updatePictureOutline()
        updateLookZone()
    }

    private func updateLookZone() {
        guard editing, bounds.width > 0 else { return }
        let f = field, z = TouchLayout.lookZone, sp = space
        let a = sp.point(x: z.minX, y: z.minY), b = sp.point(x: z.maxX, y: z.maxY)
        let r = CGRect(x: f.minX + min(a.x, b.x), y: f.minY + min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lookLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 14).cgPath
        lookText.frame = CGRect(x: r.minX, y: r.maxY - 26, width: r.width, height: 16)
        CATransaction.commit()
    }

    private func updatePictureOutline() {
        pictureLayer.isHidden = !drawsPictureOutline; pictureText.isHidden = !drawsPictureOutline
        guard drawsPictureOutline, bounds.width > 0 else { return }
        let r = PictureBand.rect(screen: bounds.size, guest: guestSize, placement: layout?.picture, isPad: UIDevice.current.userInterfaceIdiom == .pad, controlsOn: true, enabled: PictureBand.enabled)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pictureLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 6).cgPath
        pictureText.frame = CGRect(x: r.minX, y: r.midY - 9, width: r.width, height: 18)
        CATransaction.commit()
    }

    private func updateOutline() {
        guard editing else { return }
        let ringPath = UIBezierPath()
        for p in placed where !p.spec.isOverlay {
            let c = point(of: p.spec), r = drawn(p.spec) / 2 + 4
            ringPath.append(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)))
        }
        rings.path = ringPath.cgPath
        updateWarnings()
        let chosen = placed.filter { selectedIDs.contains($0.spec.id) }
        guard !chosen.isEmpty else { outline.path = nil; handle.path = nil; return }
        let path = UIBezierPath()
        for p in chosen {
            let c = point(of: p.spec), side = drawn(p.spec)
            if p.spec.isOverlay {
                let w = side, h = max(34, side * 0.42)
                path.append(UIBezierPath(roundedRect: CGRect(x: c.x - w / 2 - 5, y: c.y - h / 2 - 5, width: w + 10, height: h + 10), cornerRadius: 16))
            } else {
                path.append(UIBezierPath(ovalIn: CGRect(x: c.x - side / 2 - 5, y: c.y - side / 2 - 5, width: side + 10, height: side + 10)))
            }
        }
        outline.path = path.cgPath
        if chosen.count == 1 {
            let p = chosen[0], c = point(of: p.spec), h = handleCentre(c, drawn(p.spec))
            handle.path = UIBezierPath(ovalIn: CGRect(x: h.x - 9, y: h.y - 9, width: 18, height: 18)).cgPath
        } else {
            handle.path = nil          // several: the size slider and the pinch scale them together
        }
    }

    /// Outlines the controls LayoutCheck finds fault with, drawn where the controls are drawn (size setting and left-handed included).
    private func updateWarnings() {
        guard let layout else { warnRed.path = nil; warnAmber.path = nil; return }
        let check = LayoutCheck.run(layout, field: field.size, scale: Double(sizeFactor), mirrored: TouchHandedness.leftHanded)
        let red = UIBezierPath(), amber = UIBezierPath()
        for p in placed where !p.spec.isOverlay {
            let c = point(of: p.spec), r = drawn(p.spec) / 2 + 8
            let ring = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if check.overlapping.contains(p.spec.id) { red.append(ring) } else if check.small.contains(p.spec.id) { amber.append(ring) }
        }
        warnRed.path = red.cgPath; warnAmber.path = amber.cgPath
    }

    /// Moving the selection by a few points with the Nudge arrows: `nudgeBegan` once for a press (one Undo step), `nudge` for each step, `nudgeEnded` to save. The step is in points on the
    /// screen: the layout follows however the screen's size and left-handed map it.
    func nudgeBegan() { if layout?.locked != true, !selectedIDs.isEmpty { remember() } }
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard layout?.locked != true, let first = selectedSpecs.first, var l = layout else { return }
        let f = field, p0 = point(of: first), sp = space
        let a = sp.fractions(of: CGPoint(x: p0.x - f.minX, y: p0.y - f.minY)), b = sp.fractions(of: CGPoint(x: p0.x - f.minX + dx, y: p0.y - f.minY + dy))
        l.controls = ControlArrange.moved(l.controls, ids: Set(selectedIDs), dx: b.x - a.x, dy: b.y - a.y)
        layout = l
        for i in placed.indices { if let spec = l.controls.first(where: { $0.id == placed[i].spec.id }) { placed[i].spec.x = spec.x; placed[i].spec.y = spec.y } }
        setNeedsLayout(); layoutIfNeeded(); onEdited?()
    }
    func nudgeEnded() { commit() }

    /// Sets the selected control's width to an exact number (Size's number, tapped): clamped to the allowed range.
    func setSelectedSize(_ size: Double) {
        guard layout?.locked != true, !selectedIDs.isEmpty else { return }
        remember()
        let clamped = min(max(size.rounded(), TouchLayout.sizeRange.lowerBound), TouchLayout.sizeRange.upperBound)
        guard var l = layout else { return }
        for i in l.controls.indices where selectedIDs.contains(l.controls[i].id) { l.controls[i].size = clamped }
        layout = l
        rebuildKeepingSelection(); commit()
    }

    /// The resize dot sits on the outline at the lower right (45 degrees), so dragging it to a distance d from the centre makes the control 2 x d wide.
    private func handleCentre(_ c: CGPoint, _ side: CGFloat) -> CGPoint {
        let r = side / 2 + 5, d = r / 2.0.squareRoot()
        return CGPoint(x: c.x + d, y: c.y + d)
    }

    /// Lets go of everything held (when the controls are hidden or the game ends).
    func release() { releasables.forEach { $0() } }

    /// Transparent to touches on empty parts. While editing the whole screen belongs to the editor (a touch on empty space lets go of the selection and never reaches the game).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if editing { return self.point(inside: point, with: event) ? self : nil }
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    private func control(at point: CGPoint) -> Placed? {
        // Of the controls under the finger, the one whose centre is nearest (neighbours' rings overlap).
        placed.filter { $0.view.frame.insetBy(dx: -8, dy: -8).contains(point) }
              .min { hypot($0.view.center.x - point.x, $0.view.center.y - point.y) < hypot($1.view.center.x - point.x, $1.view.center.y - point.y) }
    }

    // MARK: Editing

    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard editing else { return }
        let hit = control(at: g.location(in: self))?.spec.id
        if multiSelect {
            // Select mode: a tap takes a control in or out of the selection; a tap on empty space leaves it as it is.
            guard let hit else { return }
            if let i = selectedIDs.firstIndex(of: hit) { selectedIDs.remove(at: i) } else { selectedIDs.append(hit) }
            selectionChanged()
        } else {
            select(hit)
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard editing else { return }
        let point = g.location(in: self)
        switch g.state {
        case .began:
            // A pan begins after the finger has moved a few points: work from where it went down, or a neighbour gets grabbed.
            let start = CGPoint(x: point.x - g.translation(in: self).x, y: point.y - g.translation(in: self).y)
            if layout?.locked != true, let id = selectedID, let p = placed.first(where: { $0.spec.id == id }), hypot(start.x - handleCentre(self.point(of: p.spec), drawn(p.spec)).x,
                                                                                            start.y - handleCentre(self.point(of: p.spec), drawn(p.spec)).y) < 28 {
                remember(); drag = .resize(id: id); return
            }
            guard let p = control(at: start) else {
                // Empty space: draw a box and select what it covers (in Select mode, in addition to what is selected already).
                let keep = multiSelect ? selectedIDs : []
                if !multiSelect, !selectedIDs.isEmpty { selectedIDs = []; selectionChanged() }
                drag = .box(from: start, keep: keep); return
            }
            if !selectedIDs.contains(p.spec.id) {
                if multiSelect { selectedIDs.append(p.spec.id); selectionChanged() } else { select(p.spec.id) }
            }
            if layout?.locked == true { drag = nil; return }      // a locked layout is only selected, never moved
            remember()
            drag = .move(primary: p.spec.id, grab: CGSize(width: p.view.center.x - point.x, height: p.view.center.y - point.y), from: selectedSpecs)
        case .changed:
            guard let d = drag else { return }
            switch d {
            case .move(let primary, let grab, let from):
                guard let origin = from.first(where: { $0.id == primary }) else { return }
                let f = field
                var c = CGPoint(x: point.x + grab.width, y: point.y + grab.height)
                let s = snap(c, excluding: Set(from.map(\.id))); c = s.point; showGuides(vertical: s.vertical, horizontal: s.horizontal)
                // How far the held control has moved, as fractions of the screen; the rest of the selection moves the same.
                let at = space.fractions(of: CGPoint(x: c.x - f.minX, y: c.y - f.minY))
                let dx = at.x - origin.x, dy = at.y - origin.y
                guard var l = layout else { return }
                var base = l.controls
                for spec in from { if let k = base.firstIndex(where: { $0.id == spec.id }) { base[k].x = spec.x; base[k].y = spec.y } }
                let moved = ControlArrange.moved(base, ids: Set(from.map(\.id)), dx: dx, dy: dy)
                for (k, spec) in moved.enumerated() { l.controls[k].x = spec.x; l.controls[k].y = spec.y }
                layout = l
                for i in placed.indices { if let spec = l.controls.first(where: { $0.id == placed[i].spec.id }) { placed[i].spec.x = spec.x; placed[i].spec.y = spec.y } }
                setNeedsLayout(); layoutIfNeeded()
            case .resize(let id):
                guard let current = layout?.controls.first(where: { $0.id == id }) else { return }
                let d = hypot(point.x - self.point(of: current).x, point.y - self.point(of: current).y)
                resize(id, to: stored(fromDrawn: Double(2 * (d - 5)), for: current))          // the dot sits 5 points outside the control's edge
            case .box(let from, let keep):
                let rect = CGRect(x: min(from.x, point.x), y: min(from.y, point.y), width: abs(point.x - from.x), height: abs(point.y - from.y))
                marquee.path = UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath
                guard let l = layout else { return }
                let f = field
                // The box is drawn on the screen; the controls are compared in the layout's own space.
                let sp = space
                let inField = sp.designRect(CGRect(x: rect.minX - f.minX, y: rect.minY - f.minY, width: rect.width, height: rect.height))
                var ids = keep
                for id in ControlArrange.inside(inField, specs: l.controls, in: sp.design) where !ids.contains(id) { ids.append(id) }
                if ids != selectedIDs { selectedIDs = ids; selectionChanged() }
            }
        case .ended, .cancelled:
            if case .move = drag { commit() } else if case .resize = drag { commit() }
            drag = nil; showGuides(vertical: nil, horizontal: nil); marquee.path = nil
        default: break
        }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard editing, layout?.locked != true else { return }
        switch g.state {
        case .began:
            if selectedIDs.count > 1 {
                // Several selected: the pinch makes the whole group bigger or smaller, spacing and all.
                remember(); pinchGroup = layout?.controls
                return
            }
            guard let id = selectedID ?? control(at: g.location(in: self))?.spec.id, let spec = layout?.controls.first(where: { $0.id == id }) else { return }
            if selectedID != id { select(id) }
            remember(); pinchStart = (id, spec.size)
        case .changed:
            if let all = pinchGroup, var l = layout {
                l.controls = ControlArrange.scaled(all, ids: Set(selectedIDs), by: Double(g.scale), in: space.design)
                layout = l; rebuildKeepingSelection(); onEdited?()
            } else if let s = pinchStart { resize(s.id, to: s.size * Double(g.scale)) }
        case .ended, .cancelled:
            if pinchStart != nil || pinchGroup != nil { commit() }
            pinchStart = nil; pinchGroup = nil
        default: break
        }
    }

    /// Sets a control's width (within the allowed range) without saving; the gesture saves when it ends.
    private func resize(_ id: UUID, to size: Double) {
        guard var l = layout, let k = l.controls.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(size.rounded(), TouchLayout.sizeRange.lowerBound), TouchLayout.sizeRange.upperBound)
        guard clamped != l.controls[k].size else { return }
        l.controls[k].size = clamped; layout = l
        rebuildKeepingSelection(); onEdited?()
    }

    /// Snaps a dragged centre to the middle of the screen and to the rows and columns of the other controls (within 8 points), and says which guide lines to show.
    private func snap(_ c: CGPoint, excluding ids: Set<UUID>) -> (point: CGPoint, vertical: CGFloat?, horizontal: CGFloat?) {
        let f = field, near: CGFloat = 8
        var xs: [CGFloat] = [f.midX], ys: [CGFloat] = [f.midY]
        for p in placed where !ids.contains(p.spec.id) { let o = point(of: p.spec); xs.append(o.x); ys.append(o.y) }
        var out = c, v: CGFloat?, h: CGFloat?
        if let x = xs.min(by: { abs($0 - c.x) < abs($1 - c.x) }), abs(x - c.x) <= near { out.x = x; v = x }
        if let y = ys.min(by: { abs($0 - c.y) < abs($1 - c.y) }), abs(y - c.y) <= near { out.y = y; h = y }
        return (out, v, h)
    }

    private func showGuides(vertical: CGFloat?, horizontal: CGFloat?) {
        let path = UIBezierPath()
        if let x = vertical { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: bounds.height)) }
        if let y = horizontal { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y)) }
        guides.path = path.cgPath
    }

    func select(_ id: UUID?) {
        selectedIDs = id.map { [$0] } ?? []
        selectionChanged()
    }

    private func selectionChanged() {
        updateOutline()
        onSelection?(selectedSpecs)
    }

    func selectIDs(_ ids: [UUID]) {
        selectedIDs = ids
        selectionChanged()
    }

    func selectAll() {
        selectedIDs = layout?.controls.map(\.id) ?? []
        selectionChanged()
    }

    /// Changes the selected control (its label, action, mode or size) and saves; with several selected, each of them.
    func changeSelected(_ edit: (inout TouchControlSpec) -> Void) {
        guard var l = layout, !selectedIDs.isEmpty else { return }
        remember()
        for i in l.controls.indices where selectedIDs.contains(l.controls[i].id) { edit(&l.controls[i]) }
        layout = l; rebuildKeepingSelection(); commit()
    }

    func addControl(_ spec: TouchControlSpec) {
        var l = layout ?? TouchLayout()
        guard l.controls.count < TouchLayout.maxControls else { return }
        remember()
        l.controls.append(spec)
        layout = l; selectedID = spec.id; rebuildKeepingSelection(); commit(); selectionChanged()
    }

    /// Adds a control for an action ("key-E", "lmb", "stick-wasd" ...) with the label and size a new control should have, at a point in this view (nil = in a free spot).
    @discardableResult
    func addControl(action: String, at point: CGPoint? = nil) -> TouchControlSpec? {
        let pad = TouchPadControl(action: action)
        // An overlay has one spot: asking for it again selects the one there is.
        if TouchControlSpec.overlayActions.contains(action), let existing = layout?.controls.first(where: { $0.action == action }) { select(existing.id); return existing }
        let stick = action == "stick-wasd" || action == "stick-arrows" || pad?.isRound == true
        let f = field
        var x = 0.5, y = 0.5
        if let point { (x, y) = space.fractions(of: CGPoint(x: point.x - f.minX, y: point.y - f.minY)) }
        else if let free = freeSpot() { (x, y) = free }
        let label = stick ? "" : PadActions.shortLabel(action)
        let size = TouchControlSpec.overlayActions.contains(action) ? TouchControlSpec.overlayBase : (pad == .dpad ? 110.0 : (stick ? 120.0 : 54.0))
        let spec = TouchControlSpec(label: label, action: action, mode: "tap",
                                    x: min(max(x, 0.04), 0.96), y: min(max(y, 0.06), 0.94), size: size)
        guard (layout?.controls.count ?? 0) < TouchLayout.maxControls else { return nil }
        addControl(spec)
        return spec
    }

    /// A place near the middle of the screen that no control covers (spiralling out), as fractions.
    private func freeSpot() -> (Double, Double)? {
        let f = field
        guard f.width > 0 else { return nil }
        let step: CGFloat = 70
        for ring in 0..<8 {
            for k in 0..<max(1, ring * 8) {
                let angle = Double(k) / Double(max(1, ring * 8)) * 2 * Double.pi
                let c = CGPoint(x: f.midX + CGFloat(cos(angle)) * CGFloat(ring) * step, y: f.midY + CGFloat(sin(angle)) * CGFloat(ring) * step * 0.7)
                guard f.insetBy(dx: 40, dy: 40).contains(c) else { continue }
                if !placed.contains(where: { hypot(point(of: $0.spec).x - c.x, point(of: $0.spec).y - c.y) < drawn($0.spec) / 2 + 40 }) {
                    let at = space.fractions(of: CGPoint(x: c.x - f.minX, y: c.y - f.minY))
                    return (at.x, at.y)
                }
            }
        }
        return nil
    }

    /// The editor's size slider: `began` remembers the state for Undo, `changed` resizes live, `ended` saves.
    func adjustSelectedSize(_ size: Double, phase: UIGestureRecognizer.State) {
        guard !selectedIDs.isEmpty, layout?.locked != true else { return }
        func apply(_ size: Double) {
            guard var l = layout else { return }
            if let id = selectedID { resize(id, to: size); return }
            l.controls = ControlArrange.sized(l.controls, ids: Set(selectedIDs), to: size)
            if l != layout { layout = l; rebuildKeepingSelection(); onEdited?() }
        }
        switch phase {
        case .began: remember()
        case .changed: apply(size)
        case .ended, .cancelled: apply(size); commit()
        default: break
        }
    }

    /// Copies of the selected controls, a little down and to the right of the originals; the copies are then the selection.
    func duplicateSelected() {
        guard var l = layout, !selectedIDs.isEmpty else { return }
        let room = TouchLayout.maxControls - l.controls.count
        let copies = Array(ControlArrange.copies(of: l.controls, ids: Set(selectedIDs)).filter { c in !(c.isOverlay && l.controls.contains { $0.action == c.action }) }.prefix(max(room, 0)))
        guard !copies.isEmpty else { return }
        remember()
        l.controls.append(contentsOf: copies)
        layout = l; selectedIDs = copies.map(\.id); rebuildKeepingSelection(); commit(); selectionChanged()
    }

    func removeSelected() {
        guard var l = layout, l.locked != true, !selectedIDs.isEmpty else { return }
        remember()
        l.controls.removeAll { selectedIDs.contains($0.id) }
        layout = l; selectedIDs = []; rebuildKeepingSelection(); commit(); selectionChanged()
    }

    // MARK: Several at once

    /// Lines the selected controls up on an edge or a centre line of the group.
    func align(_ edge: ControlArrange.Edge) {
        // Flipped for the left hand, "left" is what the person sees: the layout's own right edge.
        let own = TouchHandedness.storedEdge(edge, left: .left, right: .right, flipped: TouchHandedness.leftHanded)
        arrange { ControlArrange.align($0, ids: Set(selectedIDs), edge: own, in: space.design, scale: Double(sizeFactor)) }
    }
    /// Spaces three or more selected controls evenly, across or down.
    func distribute(_ axis: ControlArrange.Axis) { arrange { ControlArrange.distribute($0, ids: Set(selectedIDs), axis: axis, in: space.design, scale: Double(sizeFactor)) } }
    /// Flips the selected controls left to right in place; with `wholeLayout` every control of the layout, about the middle of the screen (a left-handed layout).
    func mirror(wholeLayout: Bool) {
        let ids = wholeLayout ? Set(layout?.controls.map(\.id) ?? []) : Set(selectedIDs)
        arrange { ControlArrange.mirror($0, ids: ids, wholeScreen: wholeLayout, in: space.design) }
    }
    private func arrange(_ change: ([TouchControlSpec]) -> [TouchControlSpec]) {
        guard var l = layout, l.locked != true else { return }
        let new = change(l.controls)
        guard new != l.controls else { return }
        remember()
        l.controls = new
        layout = l; rebuildKeepingSelection(); commit()
    }

    /// Puts the selected controls on the clipboard, to paste into this layout or another one.
    func copySelectionToClipboard() { ControlClipboard.copy(selectedSpecs) }
    /// Adds what is on the clipboard (moved a little if its controls are already where it was copied from), and selects it.
    func pasteClipboard() {
        guard var l = layout, l.locked != true, ControlClipboard.count > 0 else { return }
        var fresh = ControlClipboard.paste(into: l.controls, room: TouchLayout.maxControls - l.controls.count)
        guard !fresh.isEmpty else { return }
        let overlap = fresh.contains { f in l.controls.contains { abs($0.x - f.x) < 0.01 && abs($0.y - f.y) < 0.01 && $0.action == f.action } }
        if overlap { fresh = ControlArrange.moved(fresh, ids: Set(fresh.map(\.id)), dx: 0.05, dy: 0.08) }
        remember()
        l.controls.append(contentsOf: fresh)
        layout = l; selectedIDs = fresh.map(\.id); rebuildKeepingSelection(); commit(); selectionChanged()
    }

    /// Replaces every control with a starting layout (the editor's Presets); Undo brings the old ones back.
    func replaceLayout(_ new: TouchLayout) {
        guard layout?.locked != true else { return }      // a locked layout is not swapped out (the editor's Presets button is greyed while it is locked)
        remember()
        layout = new; selectedIDs = []; build(); layoutIfNeeded(); commit(); selectionChanged()
    }

    /// Layout options (the editor's Options menu): how solid the controls are drawn when playing, and the tap on a press.
    func setOpacity(_ value: Double) {
        guard var l = layout else { return }
        remember()
        l.opacity = value; layout = l; rebuildKeepingSelection(); commit()
    }

    func setHaptics(_ on: Bool) {
        guard var l = layout else { return }
        remember()
        l.haptics = on; layout = l; ControlHaptics.enabled = on; commit()
    }

    /// Locks the layout: controls cannot be moved, resized or deleted until it is unlocked.
    func setLocked(_ on: Bool) {
        guard var l = layout else { return }
        remember()
        l.locked = on; layout = l; commit()
    }

    /// Where this layout wants the game's picture (nil: automatic).
    func setPicture(_ placement: PicturePlacement?) {
        guard var l = layout else { return }
        remember()
        l.picture = placement; layout = l; updatePictureOutline(); commit()
    }

    /// The shape and colour of the selected key or mouse button (nil: the usual).
    func setShape(_ shape: String?) { changeSelected { if $0.canTakeShape { $0.shape = shape } } }
    func setColour(_ colour: String?) { changeSelected { if $0.canTakeShape { $0.colour = colour } } }

    /// Which control is drawn over which is the order in the layout: the last is on top.
    func bringSelectedToFront() { moveSelected(toFront: true) }
    func sendSelectedToBack() { moveSelected(toFront: false) }
    /// The chosen controls go to the front or the back together, keeping the order they had among themselves.
    private func moveSelected(toFront: Bool) {
        guard var l = layout, !selectedIDs.isEmpty else { return }
        remember()
        let chosen = l.controls.filter { selectedIDs.contains($0.id) }
        l.controls.removeAll { selectedIDs.contains($0.id) }
        l.controls = toFront ? l.controls + chosen : chosen + l.controls
        layout = l; rebuildKeepingSelection(); commit()
    }

    /// Adds or takes away one of Shift, Ctrl or Alt held together with the selected key control.
    func toggleComboModifier(_ id: String) {
        changeSelected { spec in
            if let i = spec.with.firstIndex(of: id) { spec.with.remove(at: i) } else { spec.with.append(id) }
        }
    }

    func setLook(_ on: Bool) {
        guard var l = layout else { return }
        remember()
        l.look = on; layout = l; commit()
    }

    private func rebuildKeepingSelection() {
        let keep = selectedIDs
        build()
        selectedIDs = keep.filter { id in placed.contains { $0.spec.id == id } }
        layoutIfNeeded(); updateOutline()
    }

    private func commit() {
        guard let l = layout else { return }
        let clean = l.sanitized()
        if clean != l { layout = clean; rebuildKeepingSelection() }
        onChange?(clean)
        onEdited?()
    }

    /// A layout's colour name as the fill of a key or mouse button.
    private static func colour(_ name: String?) -> UIColor? {
        switch name {
        case "red": return UIColor.systemRed.withAlphaComponent(0.75)
        case "orange": return UIColor.systemOrange.withAlphaComponent(0.75)
        case "yellow": return UIColor.systemYellow.withAlphaComponent(0.75)
        case "green": return UIColor.systemGreen.withAlphaComponent(0.75)
        case "blue": return UIColor.systemBlue.withAlphaComponent(0.75)
        case "purple": return UIColor.systemPurple.withAlphaComponent(0.75)
        case "white": return UIColor(white: 1, alpha: 0.55)
        default: return nil
        }
    }

    private static func shape(_ name: String?, on layer: CALayer, side: CGFloat) {
        switch name {
        case "rounded": layer.cornerRadius = min(14, side / 3)
        case "square": layer.cornerRadius = 4
        default: layer.cornerRadius = side / 2
        }
    }

    private func makeView(_ spec: TouchControlSpec) -> UIView? {
        let side = drawn(spec)
        if spec.isOverlay { return OverlayChip(spec: spec) }
        if spec.action == "keyboard" { return CustomScreenButton(title: spec.label, symbol: "keyboard", side: side) { [weak self] in self?.onToggleKeyboard?() } }
        if let pad = spec.pad {
            let report: (VirtualPadSample) -> Void = { [weak self, id = spec.id] s in self?.padChanged(id, s) }
            switch pad {
            case .button, .trigger:
                let b = CustomPadButton(title: spec.label, control: pad, latch: spec.mode == "latch", side: side, report: report)
                releasables.append { b.release() }
                return b
            case .stick(let left):
                let s = CustomPadStick(side: side, left: left, report: report)
                releasables.append { s.release() }
                return s
            case .dpad:
                let d = CustomPadDpad(side: side, report: report)
                releasables.append { d.release() }
                return d
            }
        }
        if spec.isStick {
            let stick = CustomStick(side: side, arrows: spec.action == "stick-arrows")
            releasables.append { stick.release() }
            return stick
        }
        switch PadActions.action(spec.action) {
        case .key(let vk):
            let behavior: KeyButton.Behavior = spec.mode == "latch" ? .latch(vk) : .press(vk)          // tap and hold are one behaviour: only latch is a choice
            let extra: [Int32] = spec.with.compactMap { if case .key(let vk) = PadActions.action($0) { return vk }; return nil }          // a combo: Shift, Ctrl and Alt held with the key
            let b = KeyButton(spec.label, behavior, side: side, extra: extra)
            b.baseColour = Self.colour(spec.colour); Self.shape(spec.shape, on: b.layer, side: side)
            b.titleLabel?.adjustsFontSizeToFitWidth = true; b.titleLabel?.minimumScaleFactor = 0.45
            releasables.append { b.release() }
            return b
        case .mouse(let which):
            let b = CustomMouseButton(spec.label, button: which, side: side)
            b.baseColour = Self.colour(spec.colour); Self.shape(spec.shape, on: b.layer, side: side)
            releasables.append { b.release() }
            return b
        case .wheel(let delta):
            let b = KeyButton(spec.label, .tap(0), side: side)
            b.titleLabel?.adjustsFontSizeToFitWidth = true; b.titleLabel?.minimumScaleFactor = 0.45
            b.addAction(UIAction { _ in ControlOutput.pointer(0, 0, 0x800, UInt32(bitPattern: delta)) }, for: .touchUpInside)
            return b
        case .lookToggle:
            let b = CustomLookButton(spec.label, side: side)
            b.addAction(UIAction { [weak self, weak b] _ in self?.onToggleLook?(); b?.show(lookOn: self?.lookProvider?() ?? false) }, for: .touchUpInside)
            return b
        case .none:
            return nil
        }
    }
}

/// Switches dragging on the screen between looking around and a normal mouse (menus, clicking). With the default label it shows the mode it is in.
final class CustomLookButton: UIButton {
    private let custom: String?
    init(_ title: String, side: CGFloat) {
        custom = (title.isEmpty || title == "Look") ? nil : title
        super.init(frame: .zero)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 15, weight: .heavy); titleLabel?.adjustsFontSizeToFitWidth = true; titleLabel?.minimumScaleFactor = 0.45
        layer.cornerRadius = side / 2; layer.borderWidth = 2; layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        show(lookOn: true)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(lookOn: Bool) {
        setTitle(custom ?? (lookOn ? "Look" : "Mouse"), for: .normal)
        backgroundColor = lookOn ? UIColor(white: 0, alpha: 0.55) : UIColor.systemBlue.withAlphaComponent(0.85)
    }
}

extension TouchControlSpec {
    /// Whether a shape and a colour mean anything for this control: keys and mouse buttons have them, sticks, pad controls, the keyboard button and overlay spots do not.
    var canTakeShape: Bool { !isStick && pad == nil && action != "keyboard" && !isOverlay }
}

extension PadAction {
    var isKey: Bool { if case .key = self { return true }; return false }
}

/// A round button that holds a mouse button (left, right or middle) while touched, as relative events so the pointer does not jump.
final class CustomMouseButton: UIButton {
    private let down: UInt32, up: UInt32
    private var isPressed = false
    var baseColour: UIColor? { didSet { if !isPressed { backgroundColor = baseColour ?? UIColor(white: 0, alpha: 0.55) } } }
    init(_ title: String, button: Int, side: CGFloat) {
        (down, up) = button == 0 ? (0x2, 0x4) : button == 1 ? (0x8, 0x10) : (0x20, 0x40)
        super.init(frame: .zero)
        setTitle(title, for: .normal); setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 15, weight: .heavy); titleLabel?.adjustsFontSizeToFitWidth = true; titleLabel?.minimumScaleFactor = 0.45
        backgroundColor = UIColor(white: 0, alpha: 0.55); layer.cornerRadius = side / 2
        layer.borderWidth = 2; layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        addAction(UIAction { [weak self] _ in self?.press() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.release() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        accessibilityLabel = (button == 0 ? "Left" : button == 1 ? "Right" : "Middle") + " mouse button" + (title.isEmpty ? "" : ", \(title)")
    }
    required init?(coder: NSCoder) { fatalError() }
    private func press() { isPressed = true; backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8); ControlOutput.pointer(0, 0, down, 0) }
    func release() { guard isPressed else { return }; isPressed = false; backgroundColor = baseColour ?? UIColor(white: 0, alpha: 0.55); ControlOutput.pointer(0, 0, up, 0) }
}

/// A stick that holds W A S D or the arrow keys (eight directions).
final class CustomStick: UIView {
    private let base = CAShapeLayer(), knob = CAShapeLayer()
    private var held: Set<Int32> = []
    private var tracking: UITouch?
    private let side: CGFloat
    private let keys: (up: Int32, down: Int32, left: Int32, right: Int32)
    /// Floating (FloatingStick): the stick takes a touch near its place and its base is drawn under the thumb where it lands. `centre` is that place, in this view's own points.
    var floating = false { didSet { if !floating, tracking == nil { centre = nil; drawBase() } } }
    private var centre: CGPoint?
    private var origin: CGPoint { centre ?? CGPoint(x: bounds.midX, y: bounds.midY) }

    init(side: CGFloat, arrows: Bool) {
        self.side = side
        keys = arrows ? (0x26, 0x28, 0x25, 0x27) : (VK.w, VK.s, VK.a, VK.d)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        base.fillColor = UIColor(white: 0, alpha: 0.35).cgColor; base.strokeColor = UIColor(white: 1, alpha: 0.5).cgColor; base.lineWidth = 2
        knob.fillColor = UIColor(white: 1, alpha: 0.55).cgColor
        layer.addSublayer(base); layer.addSublayer(knob)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = arrows ? "Movement stick, arrow keys" : "Movement stick, W A S D"
        accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        drawBase()
    }
    private func drawBase() {
        let c = origin
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.path = UIBezierPath(ovalIn: CGRect(x: c.x - side / 2 + 2, y: c.y - side / 2 + 2, width: side - 4, height: side - 4)).cgPath
        moveKnob(to: c)
        CATransaction.commit()
    }
    /// The part of the screen a floating base may be drawn in (the safe area), in this view's points.
    private func field() -> CGRect? {
        guard let w = window else { return nil }
        return convert(w.bounds.inset(by: w.safeAreaInsets), from: w)
    }
    /// A floating stick also takes a touch in its zone, unless another control is there.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard floating, tracking == nil, let parent = superview else { return false }
        let near = parent.subviews.filter { $0 !== self && !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled && $0.bounds.width <= side * 2.5 && $0.bounds.height <= side * 2.5 }
            .map { convert($0.frame, from: parent) }
        return FloatingStick.takes(point, frame: bounds, neighbours: near)
    }
    private func moveKnob(to p: CGPoint) {
        let r = side * 0.19
        knob.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).cgPath
    }
    private func update(with p: CGPoint) {
        let c = origin
        var dx = p.x - c.x, dy = p.y - c.y
        let radius = side / 2, length = hypot(dx, dy)
        if length > radius { dx *= radius / length; dy *= radius / length }
        moveKnob(to: CGPoint(x: c.x + dx, y: c.y + dy))
        let dead = radius * 0.3
        var now: Set<Int32> = []
        if dy < -dead { now.insert(keys.up) }
        if dy > dead { now.insert(keys.down) }
        if dx < -dead { now.insert(keys.left) }
        if dx > dead { now.insert(keys.right) }
        for k in held.subtracting(now) { HUDKeys.up(k) }
        for k in now.subtracting(held) { HUDKeys.down(k) }
        held = now
    }
    private func end() {
        for k in held { HUDKeys.up(k) }
        held = []; tracking = nil
        centre = nil
        drawBase()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking == nil, let t = touches.first else { return }
        tracking = t
        let p = t.location(in: self)
        if floating { centre = FloatingStick.centre(touch: p, diameter: side, field: field()); drawBase() }
        update(with: p)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { update(with: t.location(in: self)) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { end() } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { end() } }
    func release() { end() }
}


/// A spot for an overlay in the editor: the performance numbers or the people in a Discord call. It is drawn only while editing (the overlay itself draws while playing, centred here, as wide as
/// this chip compared with its usual size) and never takes touches.
final class OverlayChip: UIView {
    init(spec: TouchControlSpec) {
        super.init(frame: .zero)
        let w = CGFloat(spec.size), h = max(34, w * 0.42)
        let perf = spec.action == "overlay-perf"
        backgroundColor = UIColor.systemTeal.withAlphaComponent(0.30)
        layer.cornerRadius = 12; layer.borderWidth = 2; layer.borderColor = UIColor.systemTeal.cgColor
        let icon = UIImageView(image: UIImage(systemName: perf ? "speedometer" : "person.wave.2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: max(12, h * 0.36), weight: .bold)))
        icon.tintColor = .white
        let text = UILabel(); text.text = perf ? "Performance" : "Discord call"; text.textColor = .white; text.font = .systemFont(ofSize: max(10, h * 0.30), weight: .bold)
        text.adjustsFontSizeToFitWidth = true; text.minimumScaleFactor = 0.5
        let row = UIStackView(arrangedSubviews: [icon, text]); row.axis = .horizontal; row.spacing = 6; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: centerXAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor), row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: w).isActive = true; heightAnchor.constraint(equalToConstant: h).isActive = true
        isUserInteractionEnabled = false
        accessibilityLabel = perf ? "Performance overlay spot" : "Discord call overlay spot"
    }
    required init?(coder: NSCoder) { fatalError() }
}
