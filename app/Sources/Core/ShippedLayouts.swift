// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// The layouts Porthole ships: starting points for the kinds of games people run, each one an ordinary `TouchLayout` the editor can change. Positions are fractions of the (landscape) screen,
/// sizes are points; thumbs rest at the bottom corners, so the main controls sit there and the small ones along the top.
struct ShippedLayout: Identifiable {
    let id: String
    let title: String
    let detail: String
    let layout: TouchLayout
}

enum ShippedLayouts {
    static var all: [ShippedLayout] { [universal, gamepad, action, pointAndClick, platformer] }
    static func layout(id: String) -> ShippedLayout? { all.first { $0.id == id } }

    private static func key(_ label: String, _ action: String, _ x: Double, _ y: Double, _ size: Double = 46, mode: String = "tap", with: [String] = []) -> TouchControlSpec {
        TouchControlSpec(label: label, action: action, mode: mode, x: x, y: y, size: size, with: with)
    }
    private static func pad(_ id: String, _ x: Double, _ y: Double, _ size: Double) -> TouchControlSpec {
        TouchControlSpec(label: TouchPadControl.entry(id)?.face ?? "", action: id, x: x, y: y, size: size)
    }

    /// The layout most games can be played with: everything a keyboard-and-mouse game asks for in reach of two thumbs. The left thumb walks (W A S D) and has Shift, Space, Ctrl, F and Q around the stick. The
    /// right thumb's buttons are one compact arc in the bottom right corner (the mouse buttons, E and R), about a fifth of the screen wide, so everything else on the right is free to drag in (`TouchLayout.lookZone`
    /// is the least that stays clear): dragging the screen moves the mouse (so menus, strategy and point-and-click games just work) and the Look button switches the drag to looking around for first and third
    /// person games. Escape, Tab, the wheel and the full keyboard are along the top. This is how Playport's and BCD's keyboard-and-mouse layouts do it too: a compact corner cluster and a look area under everything.
    static var universal: ShippedLayout {
        ShippedLayout(id: "universal", title: "Universal", detail: "Most games: a W A S D stick with Shift, Space, Ctrl, F and Q for the left thumb, the mouse buttons, E and R in one tight arc in the bottom right corner, and the rest of the right side free to drag and look in; a Look / Mouse switch, Esc, Tab and the keyboard.", layout: TouchLayout(controls: [
            TouchControlSpec(label: "", action: "stick-wasd", x: 0.12, y: 0.72, size: 112),
            key("Shift", "shift", 0.10, 0.38, 52, mode: "hold"), key("F", "key-F", 0.23, 0.40, 44), key("Space", "space", 0.27, 0.62, 58, mode: "hold"),
            key("Ctrl", "ctrl", 0.27, 0.86, 50, mode: "hold"), key("Q", "key-Q", 0.36, 0.84, 42),
            TouchControlSpec(label: "LMB", action: "lmb", x: 0.925, y: 0.80, size: 68), TouchControlSpec(label: "RMB", action: "rmb", x: 0.82, y: 0.88, size: 52),
            key("E", "key-E", 0.93, 0.57, 44), key("R", "key-R", 0.84, 0.66, 42),
            key("Esc", "esc", 0.16, 0.10, 40), key("Tab", "tab", 0.24, 0.10, 40),
            key("Wh\u{2191}", "wheelup", 0.58, 0.10, 38), key("Wh\u{2193}", "wheeldown", 0.66, 0.10, 38),
            TouchControlSpec(label: "Look", action: "lookmode", x: 0.76, y: 0.10, size: 54), key("Keys", "keyboard", 0.85, 0.10, 40),
        ], look: false))
    }

    /// Games that want a controller: both sticks, the D-pad, A B X Y, bumpers, triggers, Menu and View, placed like an Xbox controller.
    static var gamepad: ShippedLayout {
        ShippedLayout(id: "gamepad", title: "Gamepad", detail: "An Xbox-style controller: two sticks, D-pad, A B X Y, bumpers and triggers. For any game that supports a controller.", layout: .gamepad)
    }

    /// First and third person games: drag to look, a stick to walk, fire and aim under the right thumb, the rest around them.
    static var action: ShippedLayout {
        ShippedLayout(id: "action", title: "Action", detail: "First and third person games: drag to look, a stick to walk, fire and aim under the right thumb, then jump, reload, use, run and crouch.", layout: TouchLayout(controls: [
            TouchControlSpec(label: "", action: "stick-wasd", x: 0.13, y: 0.72, size: 120),
            TouchControlSpec(label: "FIRE", action: "lmb", x: 0.91, y: 0.73, size: 82),
            TouchControlSpec(label: "AIM", action: "rmb", x: 0.79, y: 0.79, size: 66),
            key("Jump", "space", 0.92, 0.46, 58, mode: "hold"), key("R", "key-R", 0.79, 0.53, 50), key("E", "key-E", 0.67, 0.66, 48), key("V", "key-V", 0.67, 0.87, 44),
            key("Run", "shift", 0.28, 0.51, 54, mode: "hold"), key("Duck", "ctrl", 0.29, 0.86, 54, mode: "latch"),
            key("Tab", "tab", 0.15, 0.10, 40), key("Esc", "esc", 0.86, 0.10, 40), key("Wh\u{2191}", "wheelup", 0.62, 0.10, 40), key("Wh\u{2193}", "wheeldown", 0.72, 0.10, 40),
        ], look: true))
    }

    /// Point-and-click, strategy and building games: the mouse is the screen (drag, tap), a pad for the camera, the modifiers kept under the thumb and a row of hotkeys.
    static var pointAndClick: ShippedLayout {
        ShippedLayout(id: "point", title: "Point and click", detail: "Strategy, building and adventure games: drag for the mouse, a stick for the camera, Shift Ctrl Alt that stay down, a hotkey row, a right click and zoom.", layout: TouchLayout(controls: [
            TouchControlSpec(label: "", action: "stick-arrows", x: 0.12, y: 0.75, size: 104),
            key("Shift", "shift", 0.06, 0.25, 46, mode: "latch"), key("Ctrl", "ctrl", 0.06, 0.39, 46, mode: "latch"), key("Alt", "alt", 0.06, 0.53, 46, mode: "latch"),
            key("1", "key-1", 0.30, 0.89, 40), key("2", "key-2", 0.38, 0.89, 40), key("3", "key-3", 0.46, 0.89, 40), key("4", "key-4", 0.54, 0.89, 40), key("5", "key-5", 0.62, 0.89, 40), key("6", "key-6", 0.70, 0.89, 40),
            TouchControlSpec(label: "RMB", action: "rmb", x: 0.80, y: 0.80, size: 62),
            key("Zoom+", "wheelup", 0.93, 0.52, 46), key("Zoom-", "wheeldown", 0.93, 0.68, 46),
            key("Space", "space", 0.76, 0.10, 46), key("Tab", "tab", 0.66, 0.10, 40), key("Keys", "keyboard", 0.56, 0.10, 40), key("Esc", "esc", 0.86, 0.10, 40),
        ], look: false))
    }

    /// Platformers and other side-on games: a D-pad on the left, jump and the action buttons on the right, as the controller they are made for.
    static var platformer: ShippedLayout {
        ShippedLayout(id: "platformer", title: "Platformer", detail: "Side-on games: a D-pad on the left, jump big under the right thumb with the action buttons around it, and the shoulder buttons along the top.", layout: TouchLayout(controls: [
            pad("dpad-pad", 0.14, 0.72, 120),
            pad("pad-a", 0.89, 0.75, 72), pad("pad-x", 0.77, 0.79, 58), pad("pad-b", 0.92, 0.49, 56), pad("pad-y", 0.80, 0.52, 54),
            pad("pad-lb", 0.16, 0.11, 46), pad("pad-lt", 0.26, 0.11, 46), pad("pad-rb", 0.84, 0.11, 46), pad("pad-rt", 0.74, 0.11, 46),
            pad("pad-back", 0.44, 0.10, 40), pad("pad-start", 0.56, 0.10, 40),
        ], look: false))
    }
}
