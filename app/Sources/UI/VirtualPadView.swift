// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// The on-screen game controller: two sticks, a direction pad, A B X Y, both bumpers and triggers, View and Menu, for games that want a pad on a device that has none.
///
/// It is one view that takes all of its own touches (many at once: a thumb on each stick and a finger on a trigger), turns them into an Xbox pad's state with VirtualPadMath and tells
/// `onChange`; PadInput hands that to the game exactly as it does a real controller's. The maths and the layout are in Core/VirtualPadModel.swift (and tested); this file is the
/// touches and the drawing. Only the controls take touches: everywhere else falls through to the game.
final class VirtualPadView: UIView {
    /// The pad's state whenever it changes.
    var onChange: ((VirtualPadSample) -> Void)?
    /// 0.5...1.5 of the normal size; the layout shrinks it further if the screen is too small.
    var scale: CGFloat = 1 { didSet { if scale != oldValue { setNeedsLayout() } } }
    /// How opaque the controls are while not touched.
    var restingAlpha: CGFloat = 0.55 { didSet { if restingAlpha != oldValue { restyleAll() } } }
    var haptics = true
    /// Floating sticks (FloatingStick): a thumb that lands near a stick, off its circle, takes it, and the base is drawn under the thumb.
    var floating = false { didSet { if floating != oldValue { releaseAll() } } }
    /// Which controller it imitates: the names on the buttons, their colours and shapes (the game sees an Xbox pad whichever it is).
    var style: VirtualPadStyle = .xbox { didSet { if style != oldValue { setNeedsLayout() } } }
    /// The arrangement of the controls.
    var preset: VirtualPadLayout.Preset = .standard { didSet { if preset != oldValue { releaseAll(); setNeedsLayout() } } }

    private typealias Item = VirtualPadLayout.Item
    private var frames: [Item: CGRect] = [:]
    /// `centre`: where a floating stick's base was put when its thumb landed (nil = the stick's own centre).
    private struct Owned { var item: Item; var start: CGPoint; var point: CGPoint; var began: TimeInterval; var travelled: CGFloat; var centre: CGPoint? = nil }
    private var owned: [ObjectIdentifier: Owned] = [:]
    private var last = VirtualPadSample()
    /// A tap on a stick is a click of it (L3 / R3), held for a moment.
    private var clicks: UInt16 = 0
    private var clickTimers: [VirtualPadButton: DispatchWorkItem] = [:]
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    // What is drawn: one layer for each control (the sticks have a thumb on top, the face buttons four layers).
    private var buttons: [Item: GlassLayer] = [:]          // bumpers, triggers, View, Menu
    private var stickBases: [Item: GlassLayer] = [:]
    private var thumbs: [Item: GlassLayer] = [:]
    private var faces: [VirtualPadButton: GlassLayer] = [:]
    private let dpadLayer = DPadLayer()
    private var allGlass: [GlassLayer] { Array(buttons.values) + Array(stickBases.values) + Array(faces.values) }

    override init(frame: CGRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        layer.addSublayer(dpadLayer)
        for item in [Item.leftBumper, .rightBumper, .leftTrigger, .rightTrigger, .back, .start] { let g = GlassLayer(); buttons[item] = g; layer.addSublayer(g) }
        for item in [Item.leftStick, .rightStick] {
            let base = GlassLayer(); base.showsInnerRing = true; stickBases[item] = base; layer.addSublayer(base)
            let thumb = GlassLayer(); thumbs[item] = thumb; layer.addSublayer(thumb)
        }
        for b in [VirtualPadButton.a, .b, .x, .y] { let g = GlassLayer(); faces[b] = g; layer.addSublayer(g) }
        restyleAll()
    }

    // MARK: Layout and drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = safeAreaInsets
        frames = VirtualPadLayout.frames(in: bounds.size, insets: .init(left: s.left, right: s.right, top: s.top, bottom: s.bottom), scale: scale, preset: preset)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
    }

    private func restyleAll() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for g in allGlass { g.resting = restingAlpha }
        for t in thumbs.values { t.resting = min(1, restingAlpha + 0.2) }
        dpadLayer.resting = restingAlpha
        CATransaction.commit()
    }

    private func place(_ layer: CALayer, _ r: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: r.size)
        layer.position = CGPoint(x: r.midX, y: r.midY)
    }

    /// A face button's colour in this style (nil for the plain look).
    private func tint(_ b: VirtualPadButton) -> UIColor? {
        style.faceColor(b).map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
    }

    /// Places every layer for the current frames; a layout leaves out the controls it does not use (they are hidden, and what is not drawn takes no touch).
    private func draw() {
        for (item, g) in buttons { g.isHidden = frames[item] == nil }
        for (item, g) in stickBases { g.isHidden = frames[item] == nil; thumbs[item]?.isHidden = frames[item] == nil }
        for g in faces.values { g.isHidden = frames[.face] == nil }
        dpadLayer.isHidden = frames[.dpad] == nil

        for (item, g) in buttons {
            guard let f = frames[item] else { continue }
            let key: String = [Item.leftBumper: "LB", .rightBumper: "RB", .leftTrigger: "LT", .rightTrigger: "RT", .back: "View", .start: "Menu"][item] ?? ""
            place(g, f)
            g.set(size: f.size, shape: .pill, text: style.label(key), face: nil, fontSize: min(f.height * 0.46, 15))
        }
        for (item, base) in stickBases {
            guard let f = frames[item], let thumb = thumbs[item] else { continue }
            place(base, f); base.set(size: f.size, shape: .circle, text: nil, face: nil, fontSize: 0)
            let d = f.width * 0.46
            thumb.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            thumb.set(size: CGSize(width: d, height: d), shape: .circle, text: nil, face: nil, fontSize: 0)
        }
        if let f = frames[.face] {
            let d = f.width * 0.36, sp = f.width * 0.32
            for (b, v) in [(VirtualPadButton.y, CGVector(dx: 0, dy: -sp)), (.a, CGVector(dx: 0, dy: sp)), (.x, CGVector(dx: -sp, dy: 0)), (.b, CGVector(dx: sp, dy: 0))] {
                guard let g = faces[b] else { continue }
                place(g, CGRect(x: f.midX + v.dx - d / 2, y: f.midY + v.dy - d / 2, width: d, height: d))
                g.tint = tint(b)
                g.set(size: CGSize(width: d, height: d), shape: .circle, text: nil, face: style.face(b), fontSize: d * 0.5)
            }
        }
        if let f = frames[.dpad] { place(dpadLayer, f); dpadLayer.set(size: f.size) }
        update(notify: false)
    }

    // MARK: Touches

    private static let slop: CGFloat = 12

    /// Which control a point belongs to (the nearest, within a little more than its shape).
    private func item(at p: CGPoint) -> Item? {
        var best: (Item, CGFloat)?
        for (item, f) in frames {
            let reach: CGFloat = (item == .leftStick || item == .rightStick) ? f.width * 0.15 + Self.slop : Self.slop
            guard f.insetBy(dx: -reach, dy: -reach).contains(p) else { continue }
            let d = hypot(p.x - f.midX, p.y - f.midY) / max(f.width, 1)
            if best == nil || d < best!.1 { best = (item, d) }
        }
        if best == nil, floating {
            // A floating stick also takes a touch in its zone, unless another control is there: the nearer stick wins.
            for stick in [Item.leftStick, .rightStick] {
                guard let f = frames[stick] else { continue }
                let others = frames.filter { $0.key != stick }.map { $0.value }
                guard FloatingStick.takes(p, frame: f, neighbours: others) else { continue }
                let d = hypot(p.x - f.midX, p.y - f.midY) / max(f.width, 1)
                if best == nil || d < best!.1 { best = (stick, d) }
            }
        }
        return best?.0
    }

    /// The part of the screen a floating base may be drawn in (the safe area).
    private var field: CGRect { bounds.inset(by: safeAreaInsets) }

    /// Only the controls take touches; the rest of the screen belongs to the game underneath.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { item(at: point) != nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        feedback.prepare()
        for t in touches {
            let p = t.location(in: self)
            if let item = item(at: p) {
                var o = Owned(item: item, start: p, point: p, began: t.timestamp, travelled: 0)
                if floating, item == .leftStick || item == .rightStick, let f = frames[item] { o.centre = FloatingStick.centre(touch: p, diameter: f.width, field: field) }
                owned[ObjectIdentifier(t)] = o
            }
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard var o = owned[id] else { continue }
            let p = t.location(in: self)
            o.point = p; o.travelled = max(o.travelled, hypot(p.x - o.start.x, p.y - o.start.y))
            owned[id] = o
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let o = owned.removeValue(forKey: id) else { continue }
            // A quick tap on a stick that hardly moved is a click of the stick.
            if !cancelled, o.item == .leftStick || o.item == .rightStick, t.timestamp - o.began < 0.25, o.travelled < 10 {
                click(o.item == .leftStick ? .leftStick : .rightStick)
            }
        }
        update()
    }

    private func click(_ b: VirtualPadButton) {
        clicks |= b.rawValue
        clickTimers[b]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clicks &= ~b.rawValue; self?.update() }
        clickTimers[b] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Lets go of everything (the controls were hidden, or the menu opened).
    func releaseAll() {
        owned.removeAll()
        clickTimers.values.forEach { $0.cancel() }; clickTimers.removeAll(); clicks = 0
        update()
    }

    // MARK: From touches to a pad

    private func sample() -> VirtualPadSample {
        var s = VirtualPadSample()
        s.buttons = clicks
        for o in owned.values {
            guard let f = frames[o.item] else { continue }
            let c = o.centre ?? CGPoint(x: f.midX, y: f.midY)
            let off = CGVector(dx: o.point.x - c.x, dy: o.point.y - c.y)
            switch o.item {
            case .leftStick:
                let v = VirtualPadMath.stick(offset: off, radius: f.width / 2); s.lx = VirtualPadMath.axis(v.x); s.ly = VirtualPadMath.axis(v.y)
            case .rightStick:
                let v = VirtualPadMath.stick(offset: off, radius: f.width / 2); s.rx = VirtualPadMath.axis(v.x); s.ry = VirtualPadMath.axis(v.y)
            case .dpad: s.buttons |= VirtualPadMath.dpad(offset: off, radius: f.width / 2)
            case .face: if let b = VirtualPadMath.face(offset: off, spacing: f.width * 0.32) { s.buttons |= b.rawValue }
            case .leftBumper: s.buttons |= VirtualPadButton.leftBumper.rawValue
            case .rightBumper: s.buttons |= VirtualPadButton.rightBumper.rawValue
            case .leftTrigger: s.leftTrigger = VirtualPadMath.triggerOn
            case .rightTrigger: s.rightTrigger = VirtualPadMath.triggerOn
            case .back: s.buttons |= VirtualPadButton.back.rawValue
            case .start: s.buttons |= VirtualPadButton.start.rawValue
            }
        }
        return s
    }

    private func update(notify: Bool = true) {
        let s = sample()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paint(s)
        CATransaction.commit()
        guard notify, s != last else { return }
        let gained = s.buttons & ~last.buttons != 0 || (s.leftTrigger > 0 && last.leftTrigger == 0) || (s.rightTrigger > 0 && last.rightTrigger == 0)
        last = s
        if gained, haptics { feedback.impactOccurred(intensity: 0.7) }
        onChange?(s)
    }

    /// Shows what is pressed: a pressed control brightens and shrinks a little, the sticks' thumbs follow the fingers.
    private func paint(_ s: VirtualPadSample) {
        func down(_ b: VirtualPadButton) -> Bool { s.buttons & b.rawValue != 0 }
        buttons[.leftBumper]?.pressed = down(.leftBumper); buttons[.rightBumper]?.pressed = down(.rightBumper)
        buttons[.leftTrigger]?.pressed = s.leftTrigger > 0; buttons[.rightTrigger]?.pressed = s.rightTrigger > 0
        buttons[.back]?.pressed = down(.back); buttons[.start]?.pressed = down(.start)
        dpadLayer.setPressed(s.buttons & 0x000F)
        for (b, g) in faces { g.pressed = down(b) }
        for item in [Item.leftStick, .rightStick] {
            guard let f = frames[item], let thumb = thumbs[item] else { continue }
            let (x, y) = item == .leftStick ? (Double(s.lx), Double(s.ly)) : (Double(s.rx), Double(s.ry))
            let reach = f.width * 0.27
            // A floating stick's base and thumb are drawn around where the thumb landed, and go back to the stick's place when it lifts.
            let c = owned.values.first { $0.item == item && $0.centre != nil }?.centre ?? CGPoint(x: f.midX, y: f.midY)
            stickBases[item]?.position = c
            thumb.position = CGPoint(x: c.x + CGFloat(x / 32767) * reach, y: c.y - CGFloat(y / 32767) * reach)
            thumb.pressed = x != 0 || y != 0 || (item == .leftStick ? down(.leftStick) : down(.rightStick))
        }
    }
}

// MARK: - What is drawn

private func roundedFont(_ size: CGFloat) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: .heavy)
    return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
}

/// One round or pill-shaped control in glass: a see-through gradient, a ring, a dark rim so it shows on a bright picture, and a word or one of the PlayStation's shapes on it.
private final class GlassLayer: CALayer {
    enum Shape { case circle, pill }
    private let edge = CAShapeLayer(), fill = CAGradientLayer(), shade = CAShapeLayer(), ring = CAShapeLayer(), inner = CAShapeLayer(), mark = CAShapeLayer(), text = CATextLayer()
    /// nil = clear glass (white); a face button's colour otherwise.
    var tint: UIColor? { didSet { restyle() } }
    /// How opaque it is at rest.
    var resting: CGFloat = 0.55 { didSet { restyle() } }
    var pressed = false { didSet { if pressed != oldValue { restyle() } } }
    /// A second ring inside, on a stick's base.
    var showsInnerRing = false { didSet { inner.isHidden = !showsInnerRing } }

    override init() { super.init(); build() }
    override init(layer: Any) { super.init(layer: layer); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        for l in [edge, ring, inner, mark] { l.fillColor = nil }
        edge.lineWidth = 3; ring.lineWidth = 1.5; inner.lineWidth = 1; mark.lineCap = .round; mark.lineJoin = .round
        inner.isHidden = true
        fill.startPoint = CGPoint(x: 0.5, y: 0); fill.endPoint = CGPoint(x: 0.5, y: 1)
        fill.mask = shade
        text.alignmentMode = .center; text.contentsScale = UIScreen.main.scale; text.truncationMode = .none
        for l in [edge, fill, ring, inner, mark, text] as [CALayer] { addSublayer(l) }
        restyle()
    }

    /// Sizes and shapes it (its own bounds are the owner's: `size` is only what to draw).
    func set(size: CGSize, shape: Shape, text label: String?, face: VirtualPadStyle.Face?, fontSize: CGFloat) {
        let r = CGRect(origin: .zero, size: size)
        let outline: CGPath = shape == .circle ? UIBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).cgPath
                                               : UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: min(size.width, size.height) / 2).cgPath
        edge.path = outline; ring.path = outline; shade.path = outline
        fill.frame = r; shade.frame = r
        inner.path = UIBezierPath(ovalIn: r.insetBy(dx: size.width * 0.17, dy: size.height * 0.17)).cgPath
        // The word, or the shape.
        mark.frame = r
        if case .some(.text(let t)) = face { setText(t, in: r, size: fontSize); mark.path = nil }
        else if let face, let path = Self.symbol(face, in: r) { setText(nil, in: r, size: fontSize); mark.path = path; mark.lineWidth = size.width * 0.085 }
        else { setText(label, in: r, size: fontSize); mark.path = nil }
        restyle()
    }

    private func setText(_ string: String?, in r: CGRect, size: CGFloat) {
        guard let string, !string.isEmpty else { text.string = nil; return }
        let font = roundedFont(size)
        text.font = CTFontCreateWithName(font.fontName as CFString, size, nil)
        text.fontSize = size
        text.string = string
        let h = size * 1.3
        text.frame = CGRect(x: 0, y: (r.height - h) / 2, width: r.width, height: h)
    }

    private static func symbol(_ face: VirtualPadStyle.Face, in r: CGRect) -> CGPath? {
        let c = CGPoint(x: r.midX, y: r.midY), k = r.width * 0.26
        let p = UIBezierPath()
        switch face {
        case .text: return nil
        case .cross:
            p.move(to: CGPoint(x: c.x - k, y: c.y - k)); p.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
            p.move(to: CGPoint(x: c.x + k, y: c.y - k)); p.addLine(to: CGPoint(x: c.x - k, y: c.y + k))
        case .circle: p.append(UIBezierPath(ovalIn: CGRect(x: c.x - k, y: c.y - k, width: 2 * k, height: 2 * k)))
        case .square: p.append(UIBezierPath(roundedRect: CGRect(x: c.x - k * 0.9, y: c.y - k * 0.9, width: k * 1.8, height: k * 1.8), cornerRadius: k * 0.18))
        case .triangle:
            p.move(to: CGPoint(x: c.x, y: c.y - k * 1.05)); p.addLine(to: CGPoint(x: c.x + k * 1.05, y: c.y + k * 0.85))
            p.addLine(to: CGPoint(x: c.x - k * 1.05, y: c.y + k * 0.85)); p.close()
        }
        return p.cgPath
    }

    private func restyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let base = tint ?? .white
        let a = resting
        let top: CGFloat, bottom: CGFloat
        if pressed { (top, bottom) = tint == nil ? (0.60, 0.38) : (0.92, 0.62) }
        else { (top, bottom) = tint == nil ? (a * 0.50, a * 0.16) : (min(1, a * 0.80), a * 0.32) }
        fill.colors = [base.withAlphaComponent(top).cgColor, base.withAlphaComponent(bottom).cgColor]
        ring.strokeColor = base.withAlphaComponent(pressed ? 1 : min(1, a + 0.28)).cgColor
        edge.strokeColor = UIColor.black.withAlphaComponent(pressed ? 0.20 : 0.34).cgColor
        inner.strokeColor = UIColor.white.withAlphaComponent(0.18 * min(1, a / 0.55)).cgColor
        let ink: UIColor = pressed ? .white : (tint == nil ? UIColor.white.withAlphaComponent(min(1, a + 0.40)) : base.withAlphaComponent(min(1, a + 0.45)))
        text.foregroundColor = ink.cgColor
        mark.strokeColor = ink.cgColor
        transform = pressed ? CATransform3DMakeScale(0.94, 0.94, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}

/// The direction pad: one cross with rounded corners, an arrow on each arm, and the pressed arm lighting up.
private final class DPadLayer: CALayer {
    private let edge = CAShapeLayer(), fill = CAGradientLayer(), shade = CAShapeLayer(), ring = CAShapeLayer()
    private var arms: [VirtualPadButton: CAShapeLayer] = [:], arrows: [VirtualPadButton: CAShapeLayer] = [:]
    var resting: CGFloat = 0.55 { didSet { restyle() } }
    private var pressedMask: UInt16 = 0

    override init() { super.init(); build() }
    override init(layer: Any) { super.init(layer: layer); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        for l in [edge, ring] { l.fillColor = nil }
        edge.lineWidth = 3; ring.lineWidth = 1.5
        fill.startPoint = CGPoint(x: 0.5, y: 0); fill.endPoint = CGPoint(x: 0.5, y: 1); fill.mask = shade
        for l in [edge, fill, ring] as [CALayer] { addSublayer(l) }
        for b in [VirtualPadButton.up, .down, .left, .right] {
            let arm = CAShapeLayer(); addSublayer(arm); arms[b] = arm
            let arrow = CAShapeLayer(); addSublayer(arrow); arrows[b] = arrow
        }
        restyle()
    }

    /// A polygon with its corners rounded (the cross has twelve).
    private static func rounded(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        path.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
        for i in 0..<n { path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius) }
        path.closeSubpath()
        return path
    }

    func set(size: CGSize) {
        let w = size.width, t = w / 3
        let c = CGPoint(x: w / 2, y: size.height / 2), h = t / 2, big = w / 2 - 1
        let cross = Self.rounded([CGPoint(x: c.x - h, y: c.y - big), CGPoint(x: c.x + h, y: c.y - big), CGPoint(x: c.x + h, y: c.y - h), CGPoint(x: c.x + big, y: c.y - h),
                                  CGPoint(x: c.x + big, y: c.y + h), CGPoint(x: c.x + h, y: c.y + h), CGPoint(x: c.x + h, y: c.y + big), CGPoint(x: c.x - h, y: c.y + big),
                                  CGPoint(x: c.x - h, y: c.y + h), CGPoint(x: c.x - big, y: c.y + h), CGPoint(x: c.x - big, y: c.y - h), CGPoint(x: c.x - h, y: c.y - h)], radius: t * 0.22)
        let r = CGRect(origin: .zero, size: size)
        edge.path = cross; ring.path = cross; shade.path = cross
        fill.frame = r; shade.frame = r
        // The arms (what lights up) and the arrows on them.
        let a = t * 0.2
        func arm(_ b: VirtualPadButton, _ rect: CGRect, _ tip: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            arms[b]?.path = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: t * 0.2).cgPath
            let p = UIBezierPath()
            p.move(to: CGPoint(x: tip.x + dx * a, y: tip.y + dy * a))
            p.addLine(to: CGPoint(x: tip.x - dy * a - dx * a * 0.7, y: tip.y + dx * a - dy * a * 0.7))
            p.addLine(to: CGPoint(x: tip.x + dy * a - dx * a * 0.7, y: tip.y - dx * a - dy * a * 0.7))
            p.close(); arrows[b]?.path = p.cgPath
        }
        arm(.up, CGRect(x: c.x - h, y: c.y - big, width: t, height: big - h + t * 0.3), CGPoint(x: c.x, y: c.y - big + t * 0.45), 0, -1)
        arm(.down, CGRect(x: c.x - h, y: c.y + h - t * 0.3, width: t, height: big - h + t * 0.3), CGPoint(x: c.x, y: c.y + big - t * 0.45), 0, 1)
        arm(.left, CGRect(x: c.x - big, y: c.y - h, width: big - h + t * 0.3, height: t), CGPoint(x: c.x - big + t * 0.45, y: c.y), -1, 0)
        arm(.right, CGRect(x: c.x + h - t * 0.3, y: c.y - h, width: big - h + t * 0.3, height: t), CGPoint(x: c.x + big - t * 0.45, y: c.y), 1, 0)
        restyle()
    }

    func setPressed(_ m: UInt16) {
        guard m != pressedMask else { return }
        pressedMask = m
        restyle()
    }

    private func restyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let a = resting
        fill.colors = [UIColor.white.withAlphaComponent(a * 0.50).cgColor, UIColor.white.withAlphaComponent(a * 0.16).cgColor]
        ring.strokeColor = UIColor.white.withAlphaComponent(min(1, a + 0.28)).cgColor
        edge.strokeColor = UIColor.black.withAlphaComponent(0.34).cgColor
        for (b, arm) in arms {
            let on = pressedMask & b.rawValue != 0
            arm.fillColor = UIColor.white.withAlphaComponent(on ? 0.55 : 0).cgColor
            arrows[b]?.fillColor = UIColor.white.withAlphaComponent(on ? 1 : min(1, a + 0.30)).cgColor
        }
        CATransaction.commit()
    }
}
