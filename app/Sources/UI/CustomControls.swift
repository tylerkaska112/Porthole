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
    /// Called when the selection changes (nil = nothing selected).
    var onSelect: ((TouchControlSpec?) -> Void)?
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
    private(set) var selectedID: UUID?
    var selectedSpec: TouchControlSpec? { selectedID.flatMap { id in layout?.controls.first { $0.id == id } } }
    /// The selected control's centre in this view's own points (nil = nothing selected), so a panel can keep out of its way.
    var selectedFrame: CGRect? { selectedID.flatMap { id in placed.first { $0.spec.id == id }?.view.frame } }
    private let outline = CAShapeLayer(), rings = CAShapeLayer(), guides = CAShapeLayer(), handle = CAShapeLayer()
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
    private enum Drag { case move(id: UUID, grab: CGSize), resize(id: UUID) }
    private var drag: Drag?
    private var pinchStart: (id: UUID, size: Double)?

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
            if !editing { selectedID = nil; onSelect?(nil) }
            if editing { undoStack.removeAll(); redoStack.removeAll(); onHistory?() }
            [outline, rings, handle, guides].forEach { $0.isHidden = !editing }
            gestureRecognizers?.forEach { $0.isEnabled = editing }
            placed.forEach { $0.view.alpha = editing ? 1 : CGFloat(layout?.opacity ?? 1) }      // the editor shows every control fully
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        rings.fillColor = UIColor.clear.cgColor; rings.strokeColor = UIColor(white: 1, alpha: 0.55).cgColor; rings.lineWidth = 1.5; rings.lineDashPattern = [4, 4]
        outline.fillColor = UIColor.clear.cgColor; outline.strokeColor = UIColor.systemYellow.cgColor; outline.lineWidth = 3
        handle.fillColor = UIColor.systemYellow.cgColor; handle.strokeColor = UIColor.black.withAlphaComponent(0.6).cgColor; handle.lineWidth = 1.5
        guides.fillColor = UIColor.clear.cgColor; guides.strokeColor = UIColor.systemCyan.cgColor; guides.lineWidth = 1; guides.lineDashPattern = [5, 4]
        [rings, outline, handle, guides].forEach { $0.isHidden = true; layer.addSublayer($0) }
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
            if let control = v as? UIControl { control.addAction(UIAction { [weak self] _ in if self?.editing == false { ControlHaptics.tap() } }, for: .touchDown) }
            addSubview(v)
            let cx = v.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 0), cy = v.centerYAnchor.constraint(equalTo: topAnchor, constant: 0)
            NSLayoutConstraint.activate([cx, cy])
            placed.append(Placed(spec: spec, view: v, cx: cx, cy: cy))
        }
        applyFloating()
        if let id = selectedID, !placed.contains(where: { $0.spec.id == id }) { selectedID = nil; onSelect?(nil) }
        [rings, outline, handle, guides].forEach { layer.addSublayer($0) }          // above the controls
        refreshLookButtons()
        setNeedsLayout()
    }

    /// The rectangle the fractions refer to: the screen without its safe-area insets.
    private var field: CGRect {
        let s = safeAreaInsets
        return CGRect(x: s.left, y: s.top, width: bounds.width - s.left - s.right, height: bounds.height - s.top - s.bottom)
    }

    private func point(of spec: TouchControlSpec) -> CGPoint {
        let f = field
        return CGPoint(x: f.minX + CGFloat(spec.x) * f.width, y: f.minY + CGFloat(spec.y) * f.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let f = field
        for p in placed {
            p.cx.constant = f.minX + CGFloat(p.spec.x) * f.width
            p.cy.constant = f.minY + CGFloat(p.spec.y) * f.height
        }
        updateOutline()
    }

    private func updateOutline() {
        guard editing else { return }
        let ringPath = UIBezierPath()
        for p in placed {
            let c = point(of: p.spec), r = CGFloat(p.spec.size) / 2 + 4
            ringPath.append(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)))
        }
        rings.path = ringPath.cgPath
        guard let id = selectedID, let p = placed.first(where: { $0.spec.id == id }) else { outline.path = nil; handle.path = nil; return }
        let c = point(of: p.spec), side = CGFloat(p.spec.size)
        outline.path = UIBezierPath(ovalIn: CGRect(x: c.x - side / 2 - 5, y: c.y - side / 2 - 5, width: side + 10, height: side + 10)).cgPath
        let h = handleCentre(c, side)
        handle.path = UIBezierPath(ovalIn: CGRect(x: h.x - 9, y: h.y - 9, width: 18, height: 18)).cgPath
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
        select(control(at: g.location(in: self))?.spec.id)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard editing else { return }
        let point = g.location(in: self)
        switch g.state {
        case .began:
            // A pan begins after the finger has moved a few points: work from where it went down, or a neighbour gets grabbed.
            let start = CGPoint(x: point.x - g.translation(in: self).x, y: point.y - g.translation(in: self).y)
            if layout?.locked != true, let id = selectedID, let p = placed.first(where: { $0.spec.id == id }), hypot(start.x - handleCentre(self.point(of: p.spec), CGFloat(p.spec.size)).x,
                                                                                            start.y - handleCentre(self.point(of: p.spec), CGFloat(p.spec.size)).y) < 28 {
                remember(); drag = .resize(id: id); return
            }
            guard let p = control(at: start) else { drag = nil; return }
            select(p.spec.id)
            if layout?.locked == true { drag = nil; return }      // a locked layout is only selected, never moved
            remember()
            drag = .move(id: p.spec.id, grab: CGSize(width: p.view.center.x - point.x, height: p.view.center.y - point.y))
        case .changed:
            guard let d = drag else { return }
            switch d {
            case .move(let id, let grab):
                guard let i = placed.firstIndex(where: { $0.spec.id == id }) else { return }
                let f = field
                var c = CGPoint(x: point.x + grab.width, y: point.y + grab.height)
                let s = snap(c, excluding: id); c = s.point; showGuides(vertical: s.vertical, horizontal: s.horizontal)
                let x = Double((c.x - f.minX) / max(f.width, 1)), y = Double((c.y - f.minY) / max(f.height, 1))
                placed[i].spec.x = min(max(x, 0.02), 0.98); placed[i].spec.y = min(max(y, 0.04), 0.96)
                if var l = layout, let k = l.controls.firstIndex(where: { $0.id == id }) {
                    l.controls[k].x = placed[i].spec.x; l.controls[k].y = placed[i].spec.y
                    layout = l
                }
                setNeedsLayout(); layoutIfNeeded()
            case .resize(let id):
                guard let current = layout?.controls.first(where: { $0.id == id }) else { return }
                let d = hypot(point.x - self.point(of: current).x, point.y - self.point(of: current).y)
                resize(id, to: Double(2 * (d - 5)))          // the dot sits 5 points outside the control's edge
            }
        case .ended, .cancelled:
            if drag != nil { commit() }
            drag = nil; showGuides(vertical: nil, horizontal: nil)
        default: break
        }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard editing, layout?.locked != true else { return }
        switch g.state {
        case .began:
            guard let id = selectedID ?? control(at: g.location(in: self))?.spec.id, let spec = layout?.controls.first(where: { $0.id == id }) else { return }
            if selectedID != id { select(id) }
            remember(); pinchStart = (id, spec.size)
        case .changed:
            if let s = pinchStart { resize(s.id, to: s.size * Double(g.scale)) }
        case .ended, .cancelled:
            if pinchStart != nil { commit() }
            pinchStart = nil
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
    private func snap(_ c: CGPoint, excluding id: UUID) -> (point: CGPoint, vertical: CGFloat?, horizontal: CGFloat?) {
        let f = field, near: CGFloat = 8
        var xs: [CGFloat] = [f.midX], ys: [CGFloat] = [f.midY]
        for p in placed where p.spec.id != id { let o = point(of: p.spec); xs.append(o.x); ys.append(o.y) }
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
        selectedID = id
        updateOutline()
        onSelect?(id.flatMap { id in layout?.controls.first { $0.id == id } })
    }

    /// Changes the selected control (its label, action, mode or size) and saves.
    func changeSelected(_ edit: (inout TouchControlSpec) -> Void) {
        guard var l = layout, let id = selectedID, let i = l.controls.firstIndex(where: { $0.id == id }) else { return }
        remember()
        edit(&l.controls[i])
        layout = l; rebuildKeepingSelection(); commit()
    }

    func addControl(_ spec: TouchControlSpec) {
        var l = layout ?? TouchLayout()
        guard l.controls.count < TouchLayout.maxControls else { return }
        remember()
        l.controls.append(spec)
        layout = l; selectedID = spec.id; rebuildKeepingSelection(); commit(); onSelect?(spec)
    }

    /// Adds a control for an action ("key-E", "lmb", "stick-wasd" ...) with the label and size a new control should have, at a point in this view (nil = in a free spot).
    @discardableResult
    func addControl(action: String, at point: CGPoint? = nil) -> TouchControlSpec? {
        let pad = TouchPadControl(action: action)
        let stick = action == "stick-wasd" || action == "stick-arrows" || pad?.isRound == true
        let f = field
        var x = 0.5, y = 0.5
        if let point { x = Double((point.x - f.minX) / max(f.width, 1)); y = Double((point.y - f.minY) / max(f.height, 1)) }
        else if let free = freeSpot() { (x, y) = free }
        let label = stick ? "" : PadActions.shortLabel(action)
        let size = pad == .dpad ? 110.0 : (stick ? 120.0 : 54.0)
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
                if !placed.contains(where: { hypot(point(of: $0.spec).x - c.x, point(of: $0.spec).y - c.y) < CGFloat($0.spec.size) / 2 + 40 }) {
                    return (Double((c.x - f.minX) / f.width), Double((c.y - f.minY) / f.height))
                }
            }
        }
        return nil
    }

    /// The editor's size slider: `began` remembers the state for Undo, `changed` resizes live, `ended` saves.
    func adjustSelectedSize(_ size: Double, phase: UIGestureRecognizer.State) {
        guard let id = selectedID, layout?.locked != true else { return }
        switch phase {
        case .began: remember()
        case .changed: resize(id, to: size)
        case .ended, .cancelled: resize(id, to: size); commit()
        default: break
        }
    }

    func duplicateSelected() {
        guard let spec = selectedSpec, (layout?.controls.count ?? 0) < TouchLayout.maxControls else { return }
        var copy = spec; copy.id = UUID(); copy.x = min(spec.x + 0.07, 0.96); copy.y = min(spec.y + 0.1, 0.94)
        addControl(copy)
    }

    func removeSelected() {
        guard var l = layout, l.locked != true, let id = selectedID else { return }
        remember()
        l.controls.removeAll { $0.id == id }
        layout = l; selectedID = nil; rebuildKeepingSelection(); commit(); onSelect?(nil)
    }

    /// Replaces every control with a starting layout (the editor's Presets); Undo brings the old ones back.
    func replaceLayout(_ new: TouchLayout) {
        guard layout?.locked != true else { return }      // a locked layout is not swapped out (the editor's Presets button is greyed while it is locked)
        remember()
        layout = new; selectedID = nil; build(); layoutIfNeeded(); commit(); onSelect?(nil)
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

    /// The shape and colour of the selected key or mouse button (nil: the usual).
    func setShape(_ shape: String?) { changeSelected { $0.shape = shape } }
    func setColour(_ colour: String?) { changeSelected { $0.colour = colour } }

    /// Which control is drawn over which is the order in the layout: the last is on top.
    func bringSelectedToFront() { moveSelected { $0.append($1) } }
    func sendSelectedToBack() { moveSelected { $0.insert($1, at: 0) } }
    private func moveSelected(_ put: (inout [TouchControlSpec], TouchControlSpec) -> Void) {
        guard var l = layout, let id = selectedID, let i = l.controls.firstIndex(where: { $0.id == id }) else { return }
        remember()
        let spec = l.controls.remove(at: i)
        put(&l.controls, spec)
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
        let keep = selectedID
        build()
        selectedID = keep
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
        let side = CGFloat(spec.size)
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
            b.addAction(UIAction { _ in winios_pointer(0, 0, 0x800, UInt32(bitPattern: delta)) }, for: .touchUpInside)
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
    private func press() { isPressed = true; backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8); winios_pointer(0, 0, down, 0) }
    func release() { guard isPressed else { return }; isPressed = false; backgroundColor = baseColour ?? UIColor(white: 0, alpha: 0.55); winios_pointer(0, 0, up, 0) }
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
