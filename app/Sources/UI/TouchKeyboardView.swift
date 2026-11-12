// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// A full PC keyboard drawn over the game (Core/TouchKeyboardModel.swift): function keys, numbers, letters, punctuation, arrows, Tab, Esc, Enter, Space, and Shift, Ctrl and Alt that hold for the
/// next key (a quick second tap locks them). Keys reach the game as real key presses (HUDKeys), so a hotkey, a console command or a Ctrl+Shift combination works as on a PC.
final class TouchKeyboardView: UIView, TakesHUDTouches {
    static let compactKey = "f4.keyboardCompact"
    private var compact = UserDefaults.standard.bool(forKey: TouchKeyboardView.compactKey) { didSet { UserDefaults.standard.set(compact, forKey: Self.compactKey); rebuild() } }

    private var caps: [[KeyCap]] = []
    private var modifiers = StickyModifiers()
    private var downModifiers: Set<Int32> = []
    private var pressed: [ObjectIdentifier: (vk: Int32, at: CFAbsoluteTime)] = [:]
    private let bar = UIView(), title = UILabel(), compactButton = UIButton(type: .system), closeButton = UIButton(type: .system)
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private static let barHeight: CGFloat = 32, gap: CGFloat = 3, margin: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(white: 0.04, alpha: 0.78)
        layer.cornerRadius = 14; layer.cornerCurve = .continuous
        layer.borderWidth = 1; layer.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
        isMultipleTouchEnabled = true
        isHidden = true
        title.text = "Keyboard"; title.textColor = UIColor(white: 1, alpha: 0.7); title.font = .systemFont(ofSize: 12, weight: .bold)
        compactButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        compactButton.addAction(UIAction { [weak self] _ in self?.compact.toggle() }, for: .touchUpInside)
        closeButton.setTitle("\u{2715}", for: .normal); closeButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.addAction(UIAction { [weak self] _ in self?.hide() }, for: .touchUpInside)
        closeButton.accessibilityLabel = "Close the keyboard"
        for v in [title, compactButton, closeButton] { bar.addSubview(v) }
        addSubview(bar)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    func toggle() { isHidden ? show() : hide() }

    func show() {
        guard isHidden else { return }
        isHidden = false; alpha = 0
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    func hide() {
        releaseAll()
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.12, animations: { self.alpha = 0 }, completion: { _ in self.isHidden = true })
    }

    /// Lets go of every key and modifier (the keyboard closed, the game ended).
    func releaseAll() {
        for (_, p) in pressed { HUDKeys.up(p.vk) }
        pressed.removeAll()
        modifiers.reset()
        sync()
        caps.flatMap { $0 }.forEach { $0.setPressed(false) }
    }

    // MARK: Building

    private var rows: [[KeyboardKey]] { TouchKeyboard.rows(compact: compact) }

    private func rebuild() {
        releaseAll()
        caps.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        caps = rows.map { row in
            row.map { key in
                let cap = KeyCap(key: key)
                cap.onDown = { [weak self, weak cap] key in if let cap { self?.keyDown(key, cap: cap) } }
                cap.onUp = { [weak self, weak cap] key in if let cap { self?.keyUp(key, cap: cap) } }
                addSubview(cap)
                return cap
            }
        }
        compactButton.setTitle(compact ? "All keys" : "Fewer keys", for: .normal)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// A row is about as tall as a thumb; on a short screen the keyboard takes at most this share of it.
    private func rowHeight() -> CGFloat {
        let screen = window?.bounds.height ?? 390
        let count = CGFloat(rows.count)
        let room = screen * 0.64 - Self.barHeight - Self.gap * (count + 1)
        return min(38, max(24, room / count))
    }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(rows.count)
        return CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight + count * rowHeight() + (count + 1) * Self.gap)
    }

    override func didMoveToWindow() { super.didMoveToWindow(); invalidateIntrinsicContentSize() }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        title.sizeToFit(); title.frame.origin = CGPoint(x: 14, y: (Self.barHeight - title.bounds.height) / 2)
        closeButton.frame = CGRect(x: bounds.width - 44, y: 0, width: 40, height: Self.barHeight)
        compactButton.sizeToFit(); compactButton.frame = CGRect(x: closeButton.frame.minX - compactButton.bounds.width - 10, y: 0, width: compactButton.bounds.width, height: Self.barHeight)
        let rowH = rowHeight()
        let unit = (bounds.width - 2 * Self.margin - Self.gap * 14) / CGFloat(TouchKeyboard.rowUnits)       // an ordinary key, with the gaps of a 15-key row taken out
        var y = Self.barHeight + Self.gap
        for (r, row) in rows.enumerated() {
            var x = Self.margin
            for (c, key) in row.enumerated() {
                let w = unit * CGFloat(key.weight) + Self.gap * CGFloat(key.weight - 1)
                caps[r][c].frame = CGRect(x: x, y: y, width: w, height: rowH)
                x += w + Self.gap
            }
            // A row that has fewer keys than 15 units fills the width: the last key takes what is left.
            if let last = caps[r].last, last.frame.maxX < bounds.width - Self.margin - 0.5 { last.frame.size.width = bounds.width - Self.margin - last.frame.minX }
            y += rowH + Self.gap
        }
    }

    // MARK: Keys

    private func keyDown(_ key: KeyboardKey, cap: KeyCap) {
        feedback.impactOccurred(intensity: 0.5)
        if key.isModifier {
            modifiers.tap(key.vk, now: CFAbsoluteTimeGetCurrent())
            sync()
            return
        }
        HUDKeys.down(key.vk)
        pressed[ObjectIdentifier(cap)] = (key.vk, CFAbsoluteTimeGetCurrent())
        cap.setPressed(true)
    }

    private func keyUp(_ key: KeyboardKey, cap: KeyCap) {
        guard !key.isModifier, let p = pressed.removeValue(forKey: ObjectIdentifier(cap)) else { return }
        cap.setPressed(false)
        // Never shorter than a tap, so a game that reads the keyboard once a frame sees it.
        let wait = max(0, 0.06 - (CFAbsoluteTimeGetCurrent() - p.at))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            HUDKeys.up(p.vk)
            // The modifiers that were for the next key only let go after it.
            guard let self, self.modifiers.states.values.contains(.once) else { return }
            self.modifiers.keyPressed()
            self.sync()
        }
    }

    /// Presses and releases the real Shift, Ctrl and Alt to match the sticky state, and redraws the modifier caps and the shifted legends.
    private func sync() {
        let want = modifiers.held
        for vk in want.subtracting(downModifiers) { HUDKeys.down(vk) }
        for vk in downModifiers.subtracting(want) { HUDKeys.up(vk) }
        downModifiers = want
        let shifted = want.contains(TouchKeyboard.shift)
        for cap in caps.flatMap({ $0 }) {
            cap.showsShifted = shifted
            if cap.key.isModifier { cap.stickyState = modifiers.state(cap.key.vk) }
        }
    }
}

/// One key of the keyboard.
private final class KeyCap: UIView, TakesHUDTouches {
    let key: KeyboardKey
    var onDown: ((KeyboardKey) -> Void)?
    var onUp: ((KeyboardKey) -> Void)?
    private let label = UILabel()
    private var down = false
    var showsShifted = false { didSet { if showsShifted != oldValue { label.text = showsShifted ? (key.shifted ?? key.legend) : key.legend } } }
    var stickyState = StickyModifiers.State.off { didSet { restyle() } }

    init(key: KeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        layer.cornerRadius = 7; layer.cornerCurve = .continuous
        label.text = key.legend
        label.textColor = .white; label.textAlignment = .center
        label.font = .systemFont(ofSize: key.legend.count > 2 ? 11 : 15, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = key.legend
        accessibilityTraits = .keyboardKey
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() { super.layoutSubviews(); label.frame = bounds.insetBy(dx: 2, dy: 0) }

    func setPressed(_ on: Bool) { guard down != on else { return }; down = on; restyle() }

    private func restyle() {
        switch stickyState {
        case .locked: backgroundColor = UIColor.systemGreen.withAlphaComponent(0.85)
        case .once: backgroundColor = UIColor.systemYellow.withAlphaComponent(0.85)
        case .off: backgroundColor = down ? UIColor(white: 1, alpha: 0.45) : UIColor(white: 1, alpha: 0.16)
        }
        label.textColor = stickyState == .off ? .white : .black
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { setPressedVisual(true); onDown?(key) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { setPressedVisual(false); onUp?(key) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { setPressedVisual(false); onUp?(key) }
    /// The key looks pressed while the finger is on it; the keyboard sets `down` itself for keys that really are down.
    private func setPressedVisual(_ on: Bool) { guard !key.isModifier else { return }; down = on; restyle() }
}
