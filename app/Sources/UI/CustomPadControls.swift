// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

// The pad controls of a custom layout (Core/TouchPadControls.swift): buttons, triggers, analog sticks and a D-pad that drive the on-screen Xbox pad. Each reports its own part of the
// pad's state through `report`; CustomControlsView merges them and the HUD hands the result to PadInput.

/// A round button of a layout that does something on the screen rather than in the game: the Keys button opens the full keyboard.
final class CustomScreenButton: UIButton {
    init(title: String, symbol: String, side: CGFloat, action: @escaping () -> Void) {
        super.init(frame: .zero)
        configuration = nil
        backgroundColor = UIColor(white: 0, alpha: 0.55)
        layer.cornerRadius = side / 2; layer.borderWidth = 2; layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        if title.isEmpty || title == "Keys" {
            setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.36, weight: .bold)), for: .normal)
            tintColor = .white
        } else {
            setTitle(title, for: .normal); setTitleColor(.white, for: .normal)
            titleLabel?.font = .systemFont(ofSize: 15, weight: .heavy); titleLabel?.adjustsFontSizeToFitWidth = true; titleLabel?.minimumScaleFactor = 0.45
        }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        accessibilityLabel = "Open the full keyboard"
    }
    required init?(coder: NSCoder) { fatalError() }
}

private let padFill = UIColor(white: 0, alpha: 0.55)
private let padRim = UIColor(white: 1, alpha: 0.35)

/// A button or trigger of the pad: down while the finger is, never for less than a tap's length so a game polling at 60 Hz sees it; with `latch` each tap switches it on or off.
final class CustomPadButton: UIView, TakesHUDTouches {
    private let control: TouchPadControl
    private let report: (VirtualPadSample) -> Void
    private let latching: Bool
    private var latched = false { didSet { restyle(); push() } }
    private var down = false { didSet { restyle(); push() } }
    private var tracking: UITouch?
    private var pressedAt: CFAbsoluteTime = 0
    private let label = UILabel()
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    init(title: String, control: TouchPadControl, latch: Bool, side: CGFloat, report: @escaping (VirtualPadSample) -> Void) {
        self.control = control; self.latching = latch; self.report = report
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        layer.cornerRadius = side / 2; layer.borderWidth = 2
        isMultipleTouchEnabled = false
        label.text = title
        label.textColor = .white; label.textAlignment = .center
        label.font = .systemFont(ofSize: side > 60 ? 18 : 15, weight: .heavy)
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.4
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     label.widthAnchor.constraint(equalTo: widthAnchor, constant: -10)])
        isAccessibilityElement = true
        accessibilityLabel = TouchPadControl.entries.first { $0.control == control }?.label ?? title
        accessibilityTraits = .button
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let on = down || latched
        backgroundColor = latched ? UIColor.systemGreen.withAlphaComponent(0.8) : (down ? UIColor(white: 1, alpha: 0.4) : padFill)
        layer.borderColor = (on ? UIColor(white: 1, alpha: 0.8) : padRim).cgColor
        transform = down ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
    }

    private func push() { report(control.sample(pressed: down || latched)) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking == nil, let t = touches.first else { return }
        tracking = t
        if ControlHaptics.enabled { feedback.impactOccurred(intensity: 0.7) }
        if latching { latched.toggle() } else { pressedAt = CFAbsoluteTimeGetCurrent(); down = true }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        guard let t = tracking, touches.contains(t) else { return }
        tracking = nil
        guard !latching, down else { return }
        let wait = max(0, 0.07 - (CFAbsoluteTimeGetCurrent() - pressedAt))
        if wait == 0 { down = false } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in if self?.tracking == nil { self?.down = false } } }
    }

    /// Lets go of everything (the controls were hidden, or the game ended).
    func release() {
        tracking = nil
        let was = down || latched
        down = false; latched = false
        if was { push() }
    }
}

/// An analog stick of the pad: the left or the right one. With `floating` (FloatingStick) the base is drawn under the thumb where it lands.
final class CustomPadStick: UIView, TakesHUDTouches {
    private let left: Bool
    private let side: CGFloat
    private let report: (VirtualPadSample) -> Void
    private let base = CAShapeLayer(), knob = CAShapeLayer()
    private var tracking: UITouch?
    var floating = false { didSet { if !floating, tracking == nil { centre = nil; drawBase() } } }
    private var centre: CGPoint?
    private var origin: CGPoint { centre ?? CGPoint(x: bounds.midX, y: bounds.midY) }

    init(side: CGFloat, left: Bool, report: @escaping (VirtualPadSample) -> Void) {
        self.side = side; self.left = left; self.report = report
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        base.fillColor = UIColor(white: 0, alpha: 0.35).cgColor; base.strokeColor = padRim.cgColor; base.lineWidth = 2
        knob.fillColor = UIColor(white: 1, alpha: 0.55).cgColor
        layer.addSublayer(base); layer.addSublayer(knob)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = left ? "Left stick" : "Right stick"
        accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() { super.layoutSubviews(); drawBase() }

    private func drawBase() {
        let c = origin
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.path = UIBezierPath(ovalIn: CGRect(x: c.x - side / 2 + 2, y: c.y - side / 2 + 2, width: side - 4, height: side - 4)).cgPath
        moveKnob(to: c)
        CATransaction.commit()
    }
    private func moveKnob(to p: CGPoint) {
        let r = side * 0.19
        knob.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).cgPath
    }
    private func field() -> CGRect? {
        guard let w = window else { return nil }
        return convert(w.bounds.inset(by: w.safeAreaInsets), from: w)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard floating, tracking == nil, let parent = superview else { return false }
        let near = parent.subviews.filter { $0 !== self && !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled && $0.bounds.width <= side * 2.5 && $0.bounds.height <= side * 2.5 }
            .map { convert($0.frame, from: parent) }
        return FloatingStick.takes(point, frame: bounds, neighbours: near)
    }

    private func update(with p: CGPoint) {
        let c = origin
        var dx = p.x - c.x, dy = p.y - c.y
        let radius = side / 2, length = hypot(dx, dy)
        if length > radius { dx *= radius / length; dy *= radius / length }
        moveKnob(to: CGPoint(x: c.x + dx, y: c.y + dy))
        report(TouchPadControl.stickSample(left: left, offset: CGVector(dx: p.x - c.x, dy: p.y - c.y), radius: radius))
    }
    private func end() {
        tracking = nil; centre = nil
        drawBase()
        report(VirtualPadSample())
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
    func release() { if tracking != nil { end() } }
}

/// The pad's direction pad as one control: a cross, eight directions, a dead middle; sliding the thumb round it passes through every direction.
final class CustomPadDpad: UIView, TakesHUDTouches {
    private let side: CGFloat
    private let report: (VirtualPadSample) -> Void
    private let cross = CAShapeLayer()
    private var arms: [VirtualPadButton: CAShapeLayer] = [:]
    private var tracking: UITouch?
    private var held: UInt16 = 0
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    init(side: CGFloat, report: @escaping (VirtualPadSample) -> Void) {
        self.side = side; self.report = report
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true; heightAnchor.constraint(equalToConstant: side).isActive = true
        cross.fillColor = UIColor(white: 0, alpha: 0.4).cgColor; cross.strokeColor = padRim.cgColor; cross.lineWidth = 2
        layer.addSublayer(cross)
        for b in [VirtualPadButton.up, .down, .left, .right] {
            let arm = CAShapeLayer(); arm.fillColor = UIColor(white: 1, alpha: 0.4).cgColor; arm.isHidden = true
            layer.addSublayer(arm); arms[b] = arm
        }
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Direction pad"
        accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = side / 3
        let vertical = CGRect(x: bounds.midX - w / 2, y: 2, width: w, height: side - 4), horizontal = CGRect(x: 2, y: bounds.midY - w / 2, width: side - 4, height: w)
        let path = UIBezierPath(roundedRect: vertical, cornerRadius: 8); path.append(UIBezierPath(roundedRect: horizontal, cornerRadius: 8))
        cross.path = path.cgPath
        arms[.up]?.path = UIBezierPath(roundedRect: CGRect(x: bounds.midX - w / 2, y: 2, width: w, height: w + 2), cornerRadius: 8).cgPath
        arms[.down]?.path = UIBezierPath(roundedRect: CGRect(x: bounds.midX - w / 2, y: side - w - 4, width: w, height: w + 2), cornerRadius: 8).cgPath
        arms[.left]?.path = UIBezierPath(roundedRect: CGRect(x: 2, y: bounds.midY - w / 2, width: w + 2, height: w), cornerRadius: 8).cgPath
        arms[.right]?.path = UIBezierPath(roundedRect: CGRect(x: side - w - 4, y: bounds.midY - w / 2, width: w + 2, height: w), cornerRadius: 8).cgPath
    }

    private func update(with p: CGPoint) {
        let s = TouchPadControl.dpadSample(offset: CGVector(dx: p.x - bounds.midX, dy: p.y - bounds.midY), radius: side / 2)
        if ControlHaptics.enabled, s.buttons & ~held != 0 { feedback.impactOccurred(intensity: 0.6) }
        held = s.buttons
        for (b, arm) in arms { arm.isHidden = held & b.rawValue == 0 }
        report(s)
    }
    private func end() {
        tracking = nil; held = 0
        arms.values.forEach { $0.isHidden = true }
        report(VirtualPadSample())
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { guard tracking == nil, let t = touches.first else { return }; tracking = t; update(with: t.location(in: self)) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { update(with: t.location(in: self)) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { end() } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = tracking, touches.contains(t) { end() } }
    func release() { if tracking != nil { end() } }
}
