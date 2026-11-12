// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// The on-screen controller (VirtualPadView): what a thumb on the glass means as an Xbox pad, and where each control sits. Pure maths, no UIKit, so app/Tests/VirtualPad runs it.
///
/// The game sees what PadInput publishes for a real controller (`winios_gamepad`: the XInput button mask, two triggers, two sticks), so a game needs nothing of its own for this.
struct VirtualPadSample: Equatable {
    var buttons: UInt16 = 0
    var leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

    var isNeutral: Bool { self == VirtualPadSample() }

    /// This sample merged into a real controller's: buttons together, the larger trigger, and for each stick whichever is pushed further (a thumb on the glass and one on a real stick
    /// do not fight: the stronger one wins).
    static func merged(_ real: VirtualPadSample, with virtual: VirtualPadSample) -> VirtualPadSample {
        var out = real
        out.buttons |= virtual.buttons
        out.leftTrigger = max(real.leftTrigger, virtual.leftTrigger)
        out.rightTrigger = max(real.rightTrigger, virtual.rightTrigger)
        func stronger(_ ax: Int16, _ ay: Int16, _ bx: Int16, _ by: Int16) -> (Int16, Int16) {
            let a = Int(ax) * Int(ax) + Int(ay) * Int(ay), b = Int(bx) * Int(bx) + Int(by) * Int(by)
            return b > a ? (bx, by) : (ax, ay)
        }
        (out.lx, out.ly) = stronger(real.lx, real.ly, virtual.lx, virtual.ly)
        (out.rx, out.ry) = stronger(real.rx, real.ry, virtual.rx, virtual.ry)
        return out
    }
}

/// The buttons of an Xbox pad as XInput numbers them (the same masks PadInput uses for a real controller).
enum VirtualPadButton: UInt16, CaseIterable {
    case up = 0x0001, down = 0x0002, left = 0x0004, right = 0x0008
    case start = 0x0010, back = 0x0020, leftStick = 0x0040, rightStick = 0x0080
    case leftBumper = 0x0100, rightBumper = 0x0200
    case a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000
}

enum VirtualPadMath {
    /// A thumb that has not left this fraction of the stick's radius is at rest.
    static let deadzone: CGFloat = 0.14

    /// A stick's position, -1...1 on both axes with up positive, from where the thumb is relative to the stick's centre. The thumb can leave the base: the stick stays at its edge
    /// in the same direction. The deadzone is taken off, so the stick starts from zero just outside it and not from a jump.
    static func stick(offset: CGVector, radius: CGFloat) -> (x: Double, y: Double) {
        guard radius > 0 else { return (0, 0) }
        let dx = offset.dx / radius, dy = -offset.dy / radius       // screen y goes down, a pad's up is positive
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > deadzone, length.isFinite else { return (0, 0) }
        let scaled = min(1, (length - deadzone) / (1 - deadzone))
        return (Double(dx / length * scaled), Double(dy / length * scaled))
    }

    /// A stick axis as the 16-bit number XInput reports.
    static func axis(_ v: Double) -> Int16 { Int16((max(-1, min(1, v.isFinite ? v : 0)) * 32767).rounded()) }

    /// A trigger as XInput's 0...255 (the on-screen ones are on or off).
    static let triggerOn: UInt8 = 255

    /// The direction pad: the buttons a touch at this offset from its centre means. The middle fifth is dead; the rest is cut in eight 45 degree sectors, so a diagonal is both
    /// directions and a slide round the pad goes through all of them.
    static func dpad(offset: CGVector, radius: CGFloat) -> UInt16 {
        guard radius > 0 else { return 0 }
        let dx = offset.dx, dy = -offset.dy
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > radius * 0.2, length.isFinite else { return 0 }
        // 0 degrees is right, counter-clockwise, in 0...360.
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let sector = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)     // 0 right, 1 up-right, 2 up, 3 up-left, 4 left, 5 down-left, 6 down, 7 down-right
        let r = VirtualPadButton.right.rawValue, u = VirtualPadButton.up.rawValue, l = VirtualPadButton.left.rawValue, d = VirtualPadButton.down.rawValue
        return [r, r | u, u, u | l, l, l | d, d, d | r][sector]
    }

    /// The face buttons: a touch presses the one it is nearest to, if it is within `reach` times the distance of a button from the cluster's centre. Four buttons on the points of
    /// a diamond (Y up, A down, X left, B right); the gap in the middle presses nothing.
    static func face(offset: CGVector, spacing: CGFloat, reach: CGFloat = 0.85) -> VirtualPadButton? {
        guard spacing > 0 else { return nil }
        let spots: [(VirtualPadButton, CGVector)] = [(.y, CGVector(dx: 0, dy: -spacing)), (.a, CGVector(dx: 0, dy: spacing)),
                                                     (.x, CGVector(dx: -spacing, dy: 0)), (.b, CGVector(dx: spacing, dy: 0))]
        var best: (VirtualPadButton, CGFloat)?
        for (button, spot) in spots {
            let d = ((offset.dx - spot.dx) * (offset.dx - spot.dx) + (offset.dy - spot.dy) * (offset.dy - spot.dy)).squareRoot()
            if d <= spacing * reach, best == nil || d < best!.1 { best = (button, d) }
        }
        return best?.0
    }
}

/// Where each control of the on-screen controller sits, for a screen of this size.
enum VirtualPadLayout {
    enum Item: Hashable, CaseIterable { case leftStick, rightStick, dpad, face, leftBumper, rightBumper, leftTrigger, rightTrigger, back, start }

    struct Insets: Equatable {
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
    }

    /// The width kept clear on the right edge: the in-game menu opens with a swipe from it, and a control there would take that touch.
    static let menuEdge: CGFloat = 44

    /// The smallest size the controls shrink to when the screen is too small for the size asked.
    static let smallest: CGFloat = 0.5

    /// The control sizes belong to a screen up to this size: on an iPad they are those of a big phone, not twice the size.
    static let sizeBasis: CGFloat = 470

    /// The arrangements to choose from. A layout leaves out the controls it does not need, so the ones it has can be bigger.
    enum Preset: String, CaseIterable, Identifiable {
        case standard, xbox, playstation, switchPad, retro, mirrored, racing, minimal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Standard"
            case .xbox: "Xbox"
            case .playstation: "PlayStation"
            case .switchPad: "Nintendo Switch"
            case .mirrored: "Mirrored"
            case .retro: "Retro"
            case .racing: "Racing"
            case .minimal: "Minimal"
            }
        }
        var detail: String {
            switch self {
            case .standard: "Both sticks, the direction pad, A B X Y, bumpers, triggers, View and Menu, as on an Xbox controller"
            case .xbox: "The left stick high with the direction pad beside it, A B X Y high with the right stick beside them: an Xbox controller"
            case .playstation: "The direction pad on the left, both sticks side by side in the middle, A B X Y on the right, as on a PlayStation controller"
            case .switchPad: "A stick over the direction pad on the left, A B X Y over a stick on the right: the Switch held as a handheld"
            case .mirrored: "The standard layout the other way round, for a left-handed grip"
            case .retro: "A big direction pad and big A B X Y, bumpers, View and Menu: for 2D games, and the look of a Super Nintendo pad"
            case .racing: "The left stick to steer, big pedals for the triggers, face buttons, bumpers to change gear"
            case .minimal: "A left stick, big A B X Y, bumpers, View and Menu: for simple games, with the most room to see"
            }
        }
        /// The controls this layout has.
        var items: Set<Item> {
            switch self {
            case .standard, .xbox, .playstation, .switchPad, .mirrored: Set(Item.allCases)
            case .retro: [.dpad, .face, .leftBumper, .rightBumper, .back, .start]
            case .racing: [.leftStick, .face, .leftTrigger, .rightTrigger, .leftBumper, .rightBumper, .back, .start]
            case .minimal: [.leftStick, .face, .leftBumper, .rightBumper, .back, .start]
            }
        }
    }

    /// The arrangement chosen last, for a game that has none of its own.
    static let lastKey = "f4.vpad.preset"
    /// The arrangement a game uses: its own, else the one chosen last, else the standard.
    static func preset(game: String?, last: String?) -> Preset { game.flatMap(Preset.init(rawValue:)) ?? last.flatMap(Preset.init(rawValue:)) ?? .standard }

    /// The frames, with the size scaled down (never up) until all of them fit the screen without touching each other.
    static func frames(in size: CGSize, insets: Insets, scale: CGFloat, preset: Preset = .standard) -> [Item: CGRect] {
        var s = max(smallest, min(1.5, scale.isFinite ? scale : 1))
        while true {
            let f = place(size: size, insets: insets, scale: s, preset: preset)
            if s <= smallest || fits(f, in: size, insets: insets) { return f }
            s = max(smallest, s * 0.95)
        }
    }

    static func fits(_ f: [Item: CGRect], in size: CGSize, insets: Insets) -> Bool {
        let area = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let items = Array(f)
        for (_, r) in items where !area.insetBy(dx: -0.5, dy: -0.5).contains(r) { return false }
        for i in 0..<items.count {
            for j in (i + 1)..<items.count where items[i].1.intersects(items[j].1) { return false }
        }
        return true
    }

    private static func place(size: CGSize, insets: Insets, scale: CGFloat, preset: Preset) -> [Item: CGRect] {
        let u = min(min(size.width, size.height), sizeBasis) * scale
        let m = 0.035 * u + 8                                     // margin from the edges and between controls
        let left = max(insets.left, 0) + m
        let right = size.width - max(insets.right, menuEdge) - m * 0.6
        let bottom = size.height - max(insets.bottom, 8) - m
        let top = max(insets.top, 0) + m * 0.8
        let bw = 0.20 * u, bh = 0.08 * u                          // a bumper or a trigger
        let sw = 0.14 * u, sh = 0.075 * u, mid = size.width / 2     // View and Menu
        var out: [Item: CGRect] = [:]

        func bumpers() {
            out[.leftBumper] = CGRect(x: left, y: top + (out[.leftTrigger] != nil ? bh + m * 0.4 : 0), width: bw, height: bh)
            out[.rightBumper] = CGRect(x: right - bw, y: top + (out[.rightTrigger] != nil ? bh + m * 0.4 : 0), width: bw, height: bh)
        }
        func centre() {
            out[.back] = CGRect(x: mid - sw - m * 0.4, y: top, width: sw, height: sh)
            out[.start] = CGRect(x: mid + m * 0.4, y: top, width: sw, height: sh)
        }

        switch preset {
        case .standard, .mirrored:
            let stick = 0.22 * u                                  // a stick's base (diameter)
            let face = 0.33 * u                                   // the diamond of face buttons (overall diameter)
            let dpad = 0.22 * u
            // Bottom row: left stick in the corner, the direction pad beside it; the diamond in the corner on the right, the right stick beside that.
            out[.leftStick] = CGRect(x: left, y: bottom - stick, width: stick, height: stick)
            out[.dpad] = CGRect(x: left + stick + m, y: bottom - dpad, width: dpad, height: dpad)
            out[.face] = CGRect(x: right - face, y: bottom - face, width: face, height: face)
            out[.rightStick] = CGRect(x: right - face - m - stick, y: bottom - stick, width: stick, height: stick)
            // Shoulders: the trigger above the bumper in each top corner.
            out[.leftTrigger] = CGRect(x: left, y: top, width: bw, height: bh)
            out[.rightTrigger] = CGRect(x: right - bw, y: top, width: bw, height: bh)
            bumpers(); centre()
            if preset == .mirrored {
                // The same, the other way round, across the middle of the room the layout uses (so the menu's strip stays clear).
                let flip = left + right
                for (item, r) in out { out[item] = CGRect(x: flip - r.maxX, y: r.minY, width: r.width, height: r.height) }
            }
        case .playstation:
            let stick = 0.22 * u, face = 0.33 * u, dpad = 0.22 * u
            out[.dpad] = CGRect(x: left, y: bottom - dpad, width: dpad, height: dpad)
            out[.face] = CGRect(x: right - face, y: bottom - face, width: face, height: face)
            // The sticks side by side in the middle of the room between the pad and the diamond.
            let room = (right - face - m) - (left + dpad + m)
            let start = left + dpad + m + max(0, (room - (2 * stick + m)) / 2)
            out[.leftStick] = CGRect(x: start, y: bottom - stick, width: stick, height: stick)
            out[.rightStick] = CGRect(x: start + stick + m, y: bottom - stick, width: stick, height: stick)
            out[.leftTrigger] = CGRect(x: left, y: top, width: bw, height: bh)
            out[.rightTrigger] = CGRect(x: right - bw, y: top, width: bw, height: bh)
            bumpers(); centre()
        case .xbox:
            // Offset, as on the controller: the left stick and the diamond sit higher, the direction pad and the right stick lower and towards the middle.
            let stick = 0.22 * u, face = 0.33 * u, dpad = 0.22 * u, stagger = 0.16 * u
            out[.leftStick] = CGRect(x: left, y: bottom - stick - stagger, width: stick, height: stick)
            out[.dpad] = CGRect(x: left + stick + m, y: bottom - dpad, width: dpad, height: dpad)
            out[.rightStick] = CGRect(x: right - face - m - stick, y: bottom - stick, width: stick, height: stick)
            out[.face] = CGRect(x: right - face, y: bottom - face - stagger, width: face, height: face)
            out[.leftTrigger] = CGRect(x: left, y: top, width: bw, height: bh)
            out[.rightTrigger] = CGRect(x: right - bw, y: top, width: bw, height: bh)
            bumpers(); centre()
        case .switchPad:
            // Two columns, as on the Switch held as a handheld: a stick over the direction pad on the left, the diamond over a stick on the right.
            let stick = 0.22 * u, face = 0.33 * u, dpad = 0.22 * u
            out[.dpad] = CGRect(x: left, y: bottom - dpad, width: dpad, height: dpad)
            out[.leftStick] = CGRect(x: left, y: bottom - dpad - m - stick, width: stick, height: stick)
            out[.rightStick] = CGRect(x: right - face / 2 - stick / 2, y: bottom - stick, width: stick, height: stick)
            out[.face] = CGRect(x: right - face, y: bottom - stick - m - face, width: face, height: face)
            out[.leftTrigger] = CGRect(x: left, y: top, width: bw, height: bh)
            out[.rightTrigger] = CGRect(x: right - bw, y: top, width: bw, height: bh)
            bumpers(); centre()
        case .retro:
            let dpad = 0.30 * u, face = 0.40 * u
            out[.dpad] = CGRect(x: left, y: bottom - dpad, width: dpad, height: dpad)
            out[.face] = CGRect(x: right - face, y: bottom - face, width: face, height: face)
            bumpers(); centre()
        case .racing:
            let stick = 0.27 * u, face = 0.30 * u
            let pw = 0.115 * u, ph = 0.32 * u                      // the pedals: the right trigger (gas) at the edge, the left (brake) beside it
            out[.leftStick] = CGRect(x: left, y: bottom - stick, width: stick, height: stick)
            out[.rightTrigger] = CGRect(x: right - pw, y: bottom - ph, width: pw, height: ph)
            out[.leftTrigger] = CGRect(x: right - 2 * pw - m * 0.6, y: bottom - ph, width: pw, height: ph)
            out[.face] = CGRect(x: right - 2 * pw - m * 0.6 - m - face, y: bottom - face, width: face, height: face)
            bumpers(); centre()
        case .minimal:
            let stick = 0.26 * u, face = 0.38 * u
            out[.leftStick] = CGRect(x: left, y: bottom - stick, width: stick, height: stick)
            out[.face] = CGRect(x: right - face, y: bottom - face, width: face, height: face)
            bumpers(); centre()
        }
        return out
    }
}

/// How the on-screen controller looks: which controller it imitates. It is only a look: the names on the buttons, their colours and their shapes. The game always sees an Xbox pad, so
/// the button in a position does the same thing in every style (the bottom face button is A to the game, and a PlayStation's ✕ or a Nintendo pad's B on the screen).
enum VirtualPadStyle: String, CaseIterable, Identifiable {
    case xbox, playstation, nintendo, classic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .xbox: "Xbox"
        case .playstation: "PlayStation"
        case .nintendo: "Nintendo Switch"
        case .classic: "Super Nintendo"
        }
    }
    var detail: String {
        switch self {
        case .xbox: "The Xbox controller: offset sticks, A B X Y in green, red, blue and yellow; LB RB LT RT, View and Menu"
        case .playstation: "The PlayStation controller: sticks side by side, ✕ ○ □ △ in blue, red, pink and green; L1 R1 L2 R2, Create and Options"
        case .nintendo: "The Switch held as a handheld: a stick over the pad, plain buttons with the letters where Nintendo prints them (B at the bottom, A on the right); L R ZL ZR, − and +"
        case .classic: "The Super Nintendo's pad: no sticks, a big direction pad, red, yellow, blue and green buttons, Select and Start"
        }
    }

    /// The controller whose names the buttons carry (the app names real controllers' buttons the same way).
    var kind: ControllerKind {
        switch self {
        case .xbox: .xbox
        case .playstation: .dualSense
        case .nintendo, .classic: .switchPro
        }
    }

    /// What is printed on a button, by the Xbox name the rest of the app uses ("A", "LB", "Menu", ...).
    func label(_ xboxName: String) -> String {
        if self == .classic {
            switch xboxName {
            case "View": return "Select"
            case "Menu": return "Start"
            default: break
            }
        }
        return kind.glyph(xboxName)
    }

    /// The arrangement of the controller this style imitates: choosing a style brings its own shape, not just its labels and colours. The Super Nintendo's pad has no sticks.
    var nativePreset: VirtualPadLayout.Preset {
        switch self {
        case .xbox: .xbox
        case .playstation: .playstation
        case .nintendo: .switchPad
        case .classic: .retro
        }
    }

    /// A face button's mark: letters, or one of the PlayStation's four shapes (drawn, not typed, so they are the same on every device).
    enum Face: Equatable { case text(String), cross, circle, square, triangle }

    private static func xboxName(_ b: VirtualPadButton) -> String? { [VirtualPadButton.a: "A", .b: "B", .x: "X", .y: "Y"][b] }

    func face(_ b: VirtualPadButton) -> Face {
        guard let name = Self.xboxName(b) else { return .text("") }
        if self == .playstation { return [VirtualPadButton.a: Face.cross, .b: .circle, .x: .square, .y: .triangle][b] ?? .text("") }
        return .text(label(name))
    }

    struct Color: Equatable { var red: Double, green: Double, blue: Double }

    /// A face button's colour, or nil for the plain look.
    func faceColor(_ b: VirtualPadButton) -> Color? {
        switch self {
        case .xbox:
            return [VirtualPadButton.a: Color(red: 0.43, green: 0.76, blue: 0.29), .b: Color(red: 0.88, green: 0.27, blue: 0.24),
                    .x: Color(red: 0.24, green: 0.48, blue: 0.92), .y: Color(red: 0.95, green: 0.76, blue: 0.19)][b]
        case .playstation:
            // ✕ blue, ○ red, □ pink, △ green.
            return [VirtualPadButton.a: Color(red: 0.36, green: 0.52, blue: 0.86), .b: Color(red: 0.91, green: 0.33, blue: 0.36),
                    .x: Color(red: 0.89, green: 0.53, blue: 0.72), .y: Color(red: 0.27, green: 0.78, blue: 0.62)][b]
        case .nintendo:
            return nil
        case .classic:
            // The Super Nintendo's: the right button (A) red, the bottom one (B) yellow, the top one (X) blue, the left one (Y) green.
            return [VirtualPadButton.b: Color(red: 0.84, green: 0.20, blue: 0.22), .a: Color(red: 0.95, green: 0.78, blue: 0.20),
                    .y: Color(red: 0.24, green: 0.45, blue: 0.85), .x: Color(red: 0.30, green: 0.68, blue: 0.36)][b]
        }
    }

    /// The style chosen last, for a game that has none of its own.
    static let lastKey = "f4.vpad.style"
    static func style(game: String?, last: String?) -> VirtualPadStyle { game.flatMap(VirtualPadStyle.init(rawValue:)) ?? last.flatMap(VirtualPadStyle.init(rawValue:)) ?? .xbox }
}
