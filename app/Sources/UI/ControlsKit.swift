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
        sent += 1; last = name(vk)
        if sent <= 30 { LogStore.shared.log("[f4-key] \(last) down (#\(sent))") }
        winios_post_key(vk, 1)
    }
    static func up(_ vk: Int32) { winios_post_key(vk, 0) }

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
        case .hold(let vk):
            addAction(UIAction { [extra] _ in extra.forEach { HUDKeys.down($0) }; HUDKeys.down(vk) }, for: .touchDown)
            addAction(UIAction { [extra] _ in HUDKeys.up(vk); extra.reversed().forEach { HUDKeys.up($0) } }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        case .press(let vk):
            addAction(UIAction { [weak self, extra] _ in self?.pressedAt = CFAbsoluteTimeGetCurrent(); extra.forEach { HUDKeys.down($0) }; HUDKeys.down(vk) }, for: .touchDown)
            addAction(UIAction { [weak self, extra] _ in
                let wait = max(0, 0.07 - (CFAbsoluteTimeGetCurrent() - (self?.pressedAt ?? 0)))
                let up = { HUDKeys.up(vk); extra.reversed().forEach { HUDKeys.up($0) } }
                if wait == 0 { up() } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { up() } }
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
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

    private func refresh() { backgroundColor = latched ? UIColor.systemGreen.withAlphaComponent(0.8) : (baseColour ?? UIColor(white: 0, alpha: 0.55)) }

    /// Releases a latched key (when the game ends).
    func release() { if latched, case .latch(let vk) = behavior { HUDKeys.up(vk); extra.reversed().forEach { HUDKeys.up($0) }; latched = false } }
}
