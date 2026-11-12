// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// What a controller input can do in keyboard-and-mouse mode (see PadInput.swift).

enum PadAction: Equatable {
    case none
    case key(Int32)            // a Windows virtual-key code
    case mouse(Int)            // 0 left, 1 right, 2 middle
    case wheel(Int32)          // +120 up, -120 down, one notch per press
    case lookToggle            // on-screen buttons only: switch dragging on the screen between looking and a normal mouse
}

/// The actions offered for a controller button, the controller inputs and the built-in template.
enum PadActions {
    static let buttons = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "L3", "R3", "Menu", "View", "D\u{2191}", "D\u{2193}", "D\u{2190}", "D\u{2192}"]
    static let stickModes: [(id: String, label: String)] = [("wasd", "W A S D keys"), ("arrows", "Arrow keys"), ("mouse", "Mouse"), ("none", "Nothing")]

    /// id -> (label, action). The ids are what is stored with the game.
    static let list: [(id: String, label: String, action: PadAction)] = {
        var l: [(String, String, PadAction)] = [("none", "Nothing", .none), ("lmb", "Left mouse button", .mouse(0)), ("rmb", "Right mouse button", .mouse(1)),
                                                ("mmb", "Middle mouse button", .mouse(2)), ("wheelup", "Mouse wheel up", .wheel(120)), ("wheeldown", "Mouse wheel down", .wheel(-120)),
                                                ("space", "Space", .key(0x20)), ("enter", "Enter", .key(0x0D)), ("esc", "Esc", .key(0x1B)), ("tab", "Tab", .key(0x09)),
                                                ("shift", "Shift", .key(0x10)), ("ctrl", "Ctrl", .key(0x11)), ("alt", "Alt", .key(0x12)), ("backspace", "Backspace", .key(0x08)),
                                                ("up", "Up arrow", .key(0x26)), ("down", "Down arrow", .key(0x28)), ("left", "Left arrow", .key(0x25)), ("right", "Right arrow", .key(0x27))]
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { l.append(("key-\(c)", String(c), .key(Int32(c.asciiValue!)))) }
        for d in 0...9 { l.append(("key-\(d)", String(d), .key(Int32(0x30 + d)))) }
        for f in 1...12 { l.append(("f\(f)", "F\(f)", .key(Int32(0x6F + f)))) }
        return l
    }()
    /// Actions only an on-screen button can have (a controller button has nothing to switch), so they are not in `list`.
    static let touchOnly: [(id: String, label: String, action: PadAction)] = [("lookmode", "Switch look / mouse mode", .lookToggle), ("keyboard", "Open the full keyboard", .none)]
    static func action(_ id: String?) -> PadAction { (list + touchOnly).first { $0.id == id }?.action ?? .none }
    static func label(_ id: String) -> String { TouchPadControl.entry(id)?.label ?? (list + touchOnly).first { $0.id == id }?.label ?? id }

    /// A short name for a control's face: the key, or what the button is.
    static func shortLabel(_ id: String) -> String {
        if let pad = TouchPadControl.entry(id) { return pad.face }
        if id.hasPrefix("key-") { return String(id.dropFirst(4)) }
        let named: [String: String] = ["space": "Space", "enter": "Enter", "esc": "Esc", "tab": "Tab", "shift": "Shift", "ctrl": "Ctrl", "alt": "Alt", "backspace": "Del",
                                       "up": "\u{2191}", "down": "\u{2193}", "left": "\u{2190}", "right": "\u{2192}", "lmb": "LMB", "rmb": "RMB", "mmb": "MMB",
                                       "wheelup": "Wh\u{2191}", "wheeldown": "Wh\u{2193}", "lookmode": "Look", "keyboard": "Keys"]
        if let n = named[id] { return n }
        if id.hasPrefix("f"), Int(id.dropFirst()) != nil { return id.uppercased() }
        return ""
    }

    /// The offered actions in groups, for menus.
    static var groups: [(title: String, ids: [String])] {
        let letters = list.map(\.id).filter { $0.hasPrefix("key-") && $0.count == 5 && $0.last!.isLetter }
        let numbers = list.map(\.id).filter { ($0.hasPrefix("key-") && $0.last!.isNumber) || ($0.hasPrefix("f") && Int($0.dropFirst()) != nil) }
        let special = ["space", "enter", "esc", "tab", "shift", "ctrl", "alt", "backspace", "up", "down", "left", "right"]
        return [("Letters", letters), ("Numbers and F keys", numbers), ("Special keys", special), ("Mouse", ["lmb", "rmb", "mmb", "wheelup", "wheeldown"]), ("Controller", TouchPadControl.entries.filter { !$0.control.isRound }.map(\.id)),
                ("Screen", ["lookmode", "keyboard"])]
    }

    /// The keyboard-and-mouse layout most PC games use: WASD on the left stick, the mouse on the right stick, the triggers as mouse buttons.
    static let template: [String: String] = [
        "A": "space", "B": "ctrl", "X": "key-E", "Y": "key-R", "LB": "key-Q", "RB": "key-F", "LT": "rmb", "RT": "lmb", "L3": "shift", "R3": "key-C",
        "Menu": "esc", "View": "tab", "D\u{2191}": "up", "D\u{2193}": "down", "D\u{2190}": "left", "D\u{2192}": "right",
    ]
    static func bindings(_ custom: [String: String]?) -> [String: String] { template.merging(custom ?? [:]) { _, new in new } }
}


/// How a game's vibration request becomes a haptic strength (kept apart from the haptics code so it can be tested).
enum RumbleMath {
    /// The strength from the setting: "" normal, "0" off, otherwise a percentage (0 to 200).
    static func scale(from option: String) -> Float {
        guard let percent = Int(option) else { return 1 }
        return Float(min(max(percent, 0), 200)) / 100
    }
    /// XInput motor speed (0 to 65535) at a strength, as a haptic intensity from 0 to 1.
    static func level(_ speed: UInt32, _ scale: Float) -> Float { min(1, max(0, Float(speed) / 65535 * scale)) }
}
