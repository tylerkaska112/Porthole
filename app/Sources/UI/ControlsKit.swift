// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// Virtual-key codes and the helpers that send keys to the game. The runtime turns these into Windows key messages (`winios_post_key`).
enum VK {
    static let backspace: Int32 = 0x08, tab: Int32 = 0x09, enter: Int32 = 0x0D, shift: Int32 = 0x10, ctrl: Int32 = 0x11, alt: Int32 = 0x12
    static let esc: Int32 = 0x1B, space: Int32 = 0x20
    static let w: Int32 = 0x57, a: Int32 = 0x41, s: Int32 = 0x53, d: Int32 = 0x44
    static func letter(_ c: Character) -> Int32 { Int32(c.asciiValue ?? 0x41) }   // 'E' -> 0x45
}

/// Where the on-screen controls send what is pressed: to the running game, or, in the controls sandbox (Settings > Controls > Try it), only to a readout, so nothing
/// reaches a game. `sandbox` is set only while that screen is open.
enum ControlOutput {
    /// Called with what was pressed or released ("W", "Left button", "Wheel up") and whether it went down.
    nonisolated(unsafe) static var sandbox: ((String, Bool) -> Void)?

    /// The mouse, as the controls send it: a button down or up, or the wheel.
    static func pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) {
        guard let report = sandbox else { winios_pointer(x, y, flags, data); return }
        switch flags {
        case 0x2: report("Left button", true)
        case 0x4: report("Left button", false)
        case 0x8: report("Right button", true)
        case 0x10: report("Right button", false)
        case 0x20: report("Middle button", true)
        case 0x40: report("Middle button", false)
        case 0x800: report(Int32(bitPattern: data) > 0 ? "Wheel up" : "Wheel down", true); report(Int32(bitPattern: data) > 0 ? "Wheel up" : "Wheel down", false)
        default: break
        }
    }
}

enum HUDKeys {
    /// What the readout shows, so a press that never reaches the game can be told apart from one the game ignores.
    private(set) static var sent = 0
    private(set) static var last = "-"

    static func name(_ vk: Int32) -> String {
        switch vk {
        case VK.tab: "Tab"; case VK.esc: "Esc"; case VK.enter: "Enter"; case VK.space: "Space"; case VK.backspace: "Del"
        case VK.shift: "Shift"; case VK.ctrl: "Ctrl"; case VK.alt: "Alt"
        default: Character(UnicodeScalar(UInt8(truncatingIfNeeded: vk))).description
        }
    }

    static func down(_ vk: Int32) {
        if let report = ControlOutput.sandbox { report(name(vk), true); return }
        sent += 1; last = name(vk)
        if sent <= 30 { LogStore.shared.log("[f4-key] \(last) down (#\(sent))") }
        winios_post_key(vk, 1)
    }
    static func up(_ vk: Int32) {
        if let report = ControlOutput.sandbox { report(name(vk), false); return }
        winios_post_key(vk, 0)
    }

    /// A press with a realistic duration. Sending down and up in the same instant can be missed by games that read the keyboard once per frame.
    static func tap(_ vk: Int32, hold: TimeInterval = 0.07) {
        down(vk)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { up(vk) }
    }

    /// Types text from the iOS keyboard (US layout), one character every 70 ms so none are merged or dropped.
    static func type(_ text: String) {
        var delay: TimeInterval = 0
        for ch in text {
            guard let (vk, shifted) = key(for: ch) else { continue }
            let t = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { if shifted { down(VK.shift) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.01) { tap(vk, hold: 0.04) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.06) { if shifted { up(VK.shift) } }
            delay += 0.07
        }
    }

    private static let shiftedDigits: [Character: Int32] = [")": 0x30, "!": 0x31, "@": 0x32, "#": 0x33, "$": 0x34, "%": 0x35, "^": 0x36, "&": 0x37, "*": 0x38, "(": 0x39]
    private static let punctuation: [Character: (Int32, Bool)] = [
        "-": (0xBD, false), "_": (0xBD, true), "=": (0xBB, false), "+": (0xBB, true), "[": (0xDB, false), "{": (0xDB, true),
        "]": (0xDD, false), "}": (0xDD, true), "\\": (0xDC, false), "|": (0xDC, true), ";": (0xBA, false), ":": (0xBA, true),
        "'": (0xDE, false), "\"": (0xDE, true), ",": (0xBC, false), "<": (0xBC, true), ".": (0xBE, false), ">": (0xBE, true),
        "/": (0xBF, false), "?": (0xBF, true), "`": (0xC0, false), "~": (0xC0, true),
    ]

    static func key(for ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (VK.enter, false) }
        if ch == "\t" { return (VK.tab, false) }
        if ch == " " { return (VK.space, false) }
        if let ascii = ch.asciiValue {
            if ch.isLetter { return (Int32(Character(ch.uppercased()).asciiValue ?? ascii), ch.isUppercase) }
            if ch.isNumber { return (Int32(ascii), false) }
        }
        if let vk = shiftedDigits[ch] { return (vk, true) }
        return punctuation[ch]
    }
}

/// A small translucent button that sends a key. `.hold` keeps the key down while the finger is down, `.tap` sends a press and release,
/// `.latch` toggles the key down/up on each tap (for Shift, Ctrl, Alt).
/// The light tap of a pressed on-screen control (a layout can switch it off).
enum ControlHaptics {
    static var enabled = true
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    static func tap() { if enabled { generator.impactOccurred(intensity: 0.6) } }
}

final class KeyButton: UIButton {
    /// `.press`: the key goes down when the finger does and up when it lifts, but never sooner than a tap's length, so a quick tap is a tap and holding it is a hold.
    enum Behavior { case hold(Int32), tap(Int32), latch(Int32), press(Int32) }
    private var pressedAt: CFAbsoluteTime = 0
    private let behavior: Behavior
    /// Keys held down together with this one (a combo: Shift+Space), pressed first and let go last.
    private let extra: [Int32]
    private var latched = false { didSet { refresh() } }
    /// A layout's colour for this key (nil: the usual dark one).
    var baseColour: UIColor? { didSet { refresh() } }

    init(_ title: String, _ behavior: Behavior, side: CGFloat? = nil, extra: [Int32] = []) {
        self.behavior = behavior
        self.extra = extra
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        layer.cornerRadius = 8
        configuration = nil
        contentEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        translatesAutoresizingMaskIntoConstraints = false
        if let side {
            // Always-visible quick key: a fixed round button.
            heightAnchor.constraint(equalToConstant: side).isActive = true
            widthAnchor.constraint(equalToConstant: side).isActive = true
            layer.cornerRadius = side / 2
            titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        } else {
            heightAnchor.constraint(equalToConstant: 38).isActive = true
            widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        }
        refresh()
        switch behavior {
        case .hold, .press:
            // The key goes down with the finger and up when it lifts (a .press never sooner than a tap's length). Sliding a finger from one such button to another hands the key over (see touchesMoved).
            addAction(UIAction { [weak self] _ in self?.pressKey() }, for: .touchDown)
            addAction(UIAction { [weak self] _ in self?.releaseKey() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        case .tap(let vk):
            // The modifiers stay down until after the key is up again (HUDKeys.tap holds it 0.07 s): a game that polls once a frame must see both together.
            addAction(UIAction { [extra] _ in extra.forEach { HUDKeys.down($0) }; HUDKeys.tap(vk); if !extra.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { extra.reversed().forEach { HUDKeys.up($0) } } } }, for: .touchUpInside)
        case .latch(let vk):
            addAction(UIAction { [weak self, extra] _ in
                guard let self else { return }
                self.latched.toggle()
                if self.latched { extra.forEach { HUDKeys.down($0) }; HUDKeys.down(vk) } else { HUDKeys.up(vk); extra.reversed().forEach { HUDKeys.up($0) } }
            }, for: .touchUpInside)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Hold and press, and sliding between them

    /// The key a button that is held down while touched sends (nil for a tap or a latch).
    private var heldKey: Int32? {
        switch behavior { case .hold(let vk), .press(let vk): vk; default: nil }
    }
    private var minimumHold: Double { if case .press = behavior { 0.07 } else { 0 } }
    private var isDown = false
    /// Another button this finger slid onto: it holds that one's key now, and lifting lets it go.
    private weak var slidTo: KeyButton?

    private func pressKey() {
        guard let vk = heldKey, !isDown else { return }
        isDown = true; pressedAt = CFAbsoluteTimeGetCurrent()
        extra.forEach { HUDKeys.down($0) }; HUDKeys.down(vk)
    }
    private func releaseKey() {
        guard let vk = heldKey, isDown else { return }
        isDown = false
        let extra = extra
        let up = { HUDKeys.up(vk); extra.reversed().forEach { HUDKeys.up($0) } }
        let wait = max(0, minimumHold - (CFAbsoluteTimeGetCurrent() - pressedAt))
        if wait == 0 { up() } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { up() } }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard SlideAcross.enabled, heldKey != nil, let touch = touches.first, let parent = superview else { return }
        let p = touch.location(in: parent)
        let current = slidTo ?? self
        // A neighbour of the same kind that the finger is well inside (a few points in, so a finger resting on the gap between two buttons does not flicker).
        guard let target = parent.subviews.compactMap({ $0 as? KeyButton }).first(where: {
            $0 !== current && $0.heldKey != nil && !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled && $0.frame.insetBy(dx: 4, dy: 4).contains(p)
        }) else { return }
        current.releaseKey(); current.isHighlighted = false
        target.pressKey(); target.isHighlighted = true
        ControlHaptics.tap()
        slidTo = target === self ? nil : target
    }
    private func finishSlide() {
        guard let target = slidTo else { return }
        slidTo = nil
        target.releaseKey(); target.isHighlighted = false
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finishSlide(); super.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finishSlide(); super.touchesCancelled(touches, with: event) }

    private func refresh() { backgroundColor = latched ? UIColor.systemGreen.withAlphaComponent(0.8) : (baseColour ?? UIColor(white: 0, alpha: 0.55)) }

    /// Releases a latched key (when the game ends).
    func release() { if latched, case .latch(let vk) = behavior { HUDKeys.up(vk); extra.reversed().forEach { HUDKeys.up($0) }; latched = false } }
}
