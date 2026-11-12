// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

// Mixed layouts: a custom touch layout (BindSets.swift) can hold controls that drive the on-screen Xbox pad as well as keys and mouse buttons, so one layout can be a gamepad, a keyboard
// or a mix of both (a stick and A B X Y for movement and combat, E and Tab for the keys a game still wants). Steam Link, Winlator and the touch layers of BCD and Playport all let a
// layout mix them; this is Porthole's own version. The controls are named by action ids in the same `action` field as keys ("pad-a", "stick-ls", "dpad-pad"), so an older build simply does not
// draw a control it does not know.

/// A control of a custom layout that is part of the on-screen Xbox pad.
enum TouchPadControl: Equatable {
    case button(VirtualPadButton)
    case trigger(left: Bool)
    case stick(left: Bool)
    case dpad

    struct Entry { let id: String; let label: String; let face: String; let control: TouchPadControl }

    /// Every pad control the editor offers: the action id stored in the layout, its name, and what its face says.
    static let entries: [Entry] = [
        Entry(id: "pad-a", label: "Controller A", face: "A", control: .button(.a)),
        Entry(id: "pad-b", label: "Controller B", face: "B", control: .button(.b)),
        Entry(id: "pad-x", label: "Controller X", face: "X", control: .button(.x)),
        Entry(id: "pad-y", label: "Controller Y", face: "Y", control: .button(.y)),
        Entry(id: "pad-lb", label: "Controller left bumper (LB)", face: "LB", control: .button(.leftBumper)),
        Entry(id: "pad-rb", label: "Controller right bumper (RB)", face: "RB", control: .button(.rightBumper)),
        Entry(id: "pad-lt", label: "Controller left trigger (LT)", face: "LT", control: .trigger(left: true)),
        Entry(id: "pad-rt", label: "Controller right trigger (RT)", face: "RT", control: .trigger(left: false)),
        Entry(id: "pad-start", label: "Controller Menu (Start)", face: "Menu", control: .button(.start)),
        Entry(id: "pad-back", label: "Controller View (Back)", face: "View", control: .button(.back)),
        Entry(id: "pad-l3", label: "Controller left stick click (L3)", face: "L3", control: .button(.leftStick)),
        Entry(id: "pad-r3", label: "Controller right stick click (R3)", face: "R3", control: .button(.rightStick)),
        Entry(id: "pad-up", label: "Controller D-pad up", face: "\u{2191}", control: .button(.up)),
        Entry(id: "pad-down", label: "Controller D-pad down", face: "\u{2193}", control: .button(.down)),
        Entry(id: "pad-left", label: "Controller D-pad left", face: "\u{2190}", control: .button(.left)),
        Entry(id: "pad-right", label: "Controller D-pad right", face: "\u{2192}", control: .button(.right)),
        Entry(id: "stick-ls", label: "Controller left stick", face: "", control: .stick(left: true)),
        Entry(id: "stick-rs", label: "Controller right stick", face: "", control: .stick(left: false)),
        Entry(id: "dpad-pad", label: "Controller D-pad (one control)", face: "", control: .dpad),
    ]

    static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    init?(action: String) {
        guard let e = Self.entry(action) else { return nil }
        self = e.control
    }

    /// A stick or a D-pad: drawn large, with no face and no label.
    var isRound: Bool { switch self { case .stick, .dpad: true; default: false } }
    /// A button or a trigger: pressed, held, or latched.
    var isButtonLike: Bool { !isRound }

    /// What a button or trigger adds to the pad's state while it is pressed (nothing when it is not).
    func sample(pressed: Bool) -> VirtualPadSample {
        var s = VirtualPadSample()
        guard pressed else { return s }
        switch self {
        case .button(let b): s.buttons = b.rawValue
        case .trigger(let left): if left { s.leftTrigger = VirtualPadMath.triggerOn } else { s.rightTrigger = VirtualPadMath.triggerOn }
        case .stick, .dpad: break
        }
        return s
    }

    /// A stick's state from where the thumb is relative to the stick's centre (the pad's own dead zone and edge handling).
    static func stickSample(left: Bool, offset: CGVector, radius: CGFloat) -> VirtualPadSample {
        let v = VirtualPadMath.stick(offset: offset, radius: radius)
        var s = VirtualPadSample()
        if left { s.lx = VirtualPadMath.axis(v.x); s.ly = VirtualPadMath.axis(v.y) } else { s.rx = VirtualPadMath.axis(v.x); s.ry = VirtualPadMath.axis(v.y) }
        return s
    }

    /// A D-pad's state from where the thumb is relative to its centre (eight directions, a dead middle).
    static func dpadSample(offset: CGVector, radius: CGFloat) -> VirtualPadSample {
        var s = VirtualPadSample()
        s.buttons = VirtualPadMath.dpad(offset: offset, radius: radius)
        return s
    }
}

/// The on-screen pad's state when several things drive it at once: the game controller view and the pad controls of a custom layout. Each source reports its own state and the pad the game
/// sees is all of them merged (buttons together, the larger trigger, the stronger stick), exactly as a real controller and the on-screen one already are.
struct TouchPadMixer: Equatable {
    private var parts: [String: VirtualPadSample] = [:]

    /// A source's state; a neutral one removes it.
    mutating func set(_ sample: VirtualPadSample, for source: String) {
        if sample.isNeutral { parts[source] = nil } else { parts[source] = sample }
    }
    mutating func clear() { parts.removeAll() }

    /// The pad as the game sees it. Sources are merged in a fixed order, so the result does not depend on which reported first.
    var merged: VirtualPadSample {
        parts.keys.sorted().reduce(VirtualPadSample()) { VirtualPadSample.merged($0, with: parts[$1]!) }
    }
}
