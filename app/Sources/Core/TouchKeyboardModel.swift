// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// A full PC keyboard on the touch screen, for the keys a layout does not have: function keys for a game's hotkeys, arrows, Ctrl and Alt combinations, Tab and Escape in a launcher, typing in a
// console. Playport's touch keyboard (F keys, arrows, sticky Shift, Ctrl and Alt) and the iOS keyboard's text entry both exist for the same reason; this is Porthole's own key table and
// sticky-modifier logic, kept apart from the view so it can be tested.

/// One key of the on-screen keyboard: the Windows virtual-key code it sends, what its cap says, and how wide it is (in units of an ordinary key).
struct KeyboardKey: Equatable {
    let vk: Int32
    let legend: String
    var shifted: String? = nil
    var weight: Double = 1
    var isModifier: Bool { TouchKeyboard.modifiers.contains(vk) }
}

enum TouchKeyboard {
    static let shift: Int32 = 0x10, ctrl: Int32 = 0x11, alt: Int32 = 0x12
    static let modifiers: Set<Int32> = [shift, ctrl, alt]

    private static func k(_ vk: Int32, _ legend: String, shifted: String? = nil, _ weight: Double = 1) -> KeyboardKey { KeyboardKey(vk: vk, legend: legend, shifted: shifted, weight: weight) }
    private static func letters(_ s: String) -> [KeyboardKey] { s.map { k(Int32($0.asciiValue!), String($0)) } }

    /// The US layout, six rows each 15 units wide: function keys, numbers, QWERTY, home row, bottom row and the space bar with the arrows.
    static let rows: [[KeyboardKey]] = [
        [k(0x1B, "Esc")] + (1...12).map { k(Int32(0x6F + $0), "F\($0)") } + [k(0x2E, "Del", 2)],
        [k(0xC0, "`", shifted: "~"), k(0x31, "1", shifted: "!"), k(0x32, "2", shifted: "@"), k(0x33, "3", shifted: "#"), k(0x34, "4", shifted: "$"), k(0x35, "5", shifted: "%"),
         k(0x36, "6", shifted: "^"), k(0x37, "7", shifted: "&"), k(0x38, "8", shifted: "*"), k(0x39, "9", shifted: "("), k(0x30, "0", shifted: ")"), k(0xBD, "-", shifted: "_"),
         k(0xBB, "=", shifted: "+"), k(0x08, "Back", 2)],
        [k(0x09, "Tab", 1.5)] + letters("QWERTYUIOP") + [k(0xDB, "[", shifted: "{"), k(0xDD, "]", shifted: "}"), k(0xDC, "\\", shifted: "|", 1.5)],
        [k(0x14, "Caps", 1.75)] + letters("ASDFGHJKL") + [k(0xBA, ";", shifted: ":"), k(0xDE, "'", shifted: "\""), k(0x0D, "Enter", 2.25)],
        [k(shift, "Shift", 2.25)] + letters("ZXCVBNM") + [k(0xBC, ",", shifted: "<"), k(0xBE, ".", shifted: ">"), k(0xBF, "/", shifted: "?"), k(shift, "Shift", 2.75)],
        [k(ctrl, "Ctrl", 1.5), k(alt, "Alt", 1.5), k(0x20, "Space", 8), k(0x25, "\u{2190}"), k(0x28, "\u{2193}"), k(0x26, "\u{2191}"), k(0x27, "\u{2192}")],
    ]

    /// Without the function-key row: more room for the picture.
    static var compactRows: [[KeyboardKey]] { Array(rows.dropFirst()) }

    static func rows(compact: Bool) -> [[KeyboardKey]] { compact ? compactRows : rows }
    static let rowUnits = 15.0
}

/// Shift, Ctrl and Alt on a touch keyboard: a tap holds the modifier for the next key only; a second quick tap holds it until it is tapped again (locked); a tap on a locked one lets go.
/// The view presses and releases the real keys to match `held`.
struct StickyModifiers: Equatable {
    enum State: Equatable { case off, once, locked }
    private(set) var states: [Int32: State] = [:]
    private var lastTap: [Int32: TimeInterval] = [:]
    /// How quickly a second tap must follow the first to lock.
    static let lockWindow: TimeInterval = 0.45

    func state(_ vk: Int32) -> State { states[vk] ?? .off }

    /// The modifier keys that are down right now.
    var held: Set<Int32> { Set(states.filter { $0.value != .off }.keys) }

    mutating func tap(_ vk: Int32, now: TimeInterval) {
        guard TouchKeyboard.modifiers.contains(vk) else { return }
        switch state(vk) {
        case .off: states[vk] = .once
        case .once: states[vk] = now - (lastTap[vk] ?? -.infinity) <= Self.lockWindow ? .locked : .off
        case .locked: states[vk] = .off
        }
        lastTap[vk] = now
    }

    /// An ordinary key was pressed: the modifiers that were "for the next key" let go, the locked ones stay.
    mutating func keyPressed() {
        for (vk, s) in states where s == .once { states[vk] = .off }
    }

    /// Everything off (the keyboard closed, the game ended).
    mutating func reset() { states = [:]; lastTap = [:] }
}
