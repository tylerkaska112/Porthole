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
/// Where the on-screen controller's size and opacity are kept (the in-game menu and Settings > Controls both use them).
enum VirtualPadDefaults {
    static let scaleKey = "f4.vpad.scale", alphaKey = "f4.vpad.alpha"
}

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

    /// The arrangements of the on-screen controller. Every controller type has the same ones (the type only changes the names and colours on the buttons). Earlier builds had eight; a name stored by one
    /// of them is read as Porthole.
    enum Preset: String, CaseIterable, Identifiable {
        /// The direction pad over the left stick, the face buttons over the right, a trigger over a bumper beside each, View and Menu in the middle.
        case porthole
        /// The sticks in the outer corners, the direction pad and the face buttons beside them, a trigger over a bumper above each stick, View and Menu in the middle: the middle of the screen is left open.
        case cornerSticks
        var id: String { rawValue }
        var title: String { self == .porthole ? "Porthole" : "Corner sticks" }
        var detail: String {
            switch self {
            case .porthole: "The direction pad over the left stick, the face buttons over the right stick, a trigger over a bumper beside each, View and Menu in the middle"
            case .cornerSticks: "A stick in each outer corner with the direction pad and the face buttons beside them, and a trigger over a bumper above each stick"
            }
        }
        /// The controls this layout has.
        var items: Set<Item> { Set(Item.allCases) }
    }

    /// The arrangement chosen last, for a game that has none of its own.
    static let lastKey = "f4.vpad.preset"
    /// The arrangement a game uses: its own choice, else the one chosen last, else Porthole (a name an earlier build stored that no longer exists reads as Porthole).
    static func preset(game: String?, last: String?) -> Preset { game.flatMap(Preset.init(rawValue:)) ?? last.flatMap(Preset.init(rawValue:)) ?? .porthole }

    /// The free room in the middle of an arrangement, between its two sides and above View and Menu: where the performance overlay sits on an iPad. `top` is the top of the controller's band (the bottom
    /// of the game picture); nil when the arrangement has no such room.
    static func centreRoom(frames f: [Item: CGRect], top: CGFloat, gap: CGFloat = 12) -> CGRect? {
        guard let lt = f[.leftTrigger], let rt = f[.rightTrigger], let back = f[.back], let start = f[.start] else { return nil }
        // The room is between the outermost edges of what is on each side: the triggers, and the direction pad and face buttons where they sit beside the sticks.
        let x0 = max(lt.maxX, f[.dpad]?.maxX ?? 0) + gap, x1 = min(rt.minX, f[.face]?.minX ?? .greatestFiniteMagnitude) - gap
        let y0 = top + gap, y1 = min(back.minY, start.minY) - gap
        guard x1 - x0 > 80, y1 - y0 > 40 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The frames, with the size scaled down (never up) until all of them fit the screen without touching each other.
    /// `wide`: an iPad, where the controls are drawn bigger and sit further in from the edges (the Porthole arrangement).
    static func frames(in size: CGSize, insets: Insets, scale: CGFloat, preset: Preset = .porthole, wide: Bool = false) -> [Item: CGRect] {
        var s = max(smallest, min(1.5, scale.isFinite ? scale : 1))
        while true {
            let f = place(size: size, insets: insets, scale: s, preset: preset, wide: wide)
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

    /// The size basis on an iPad for the Porthole arrangement: its controls are those of a big phone and a half.
    static let wideBasis: CGFloat = 560

    private static func place(size: CGSize, insets: Insets, scale: CGFloat, preset: Preset, wide: Bool) -> [Item: CGRect] {
        switch preset {
        case .porthole: return placePorthole(size: size, insets: insets, scale: scale, wide: wide)
        case .cornerSticks: return placeCornerSticks(size: size, insets: insets, scale: scale, wide: wide)
        }
    }

    /// The sticks in the outer corners (drawn by the person for an iPad, and the same on a phone): beside each stick, towards the middle, the direction pad on the left and the face buttons on the
    /// right, their middles level with the stick's; above each stick a bumper with a trigger over it, both as wide as a little less than the stick and centred on it; View and Menu small in the middle at
    /// the sticks' bottom. The middle is empty, which is where the performance overlay goes on an iPad.
    private static func placeCornerSticks(size: CGSize, insets: Insets, scale: CGFloat, wide: Bool) -> [Item: CGRect] {
        let u = min(min(size.width, size.height), wide ? wideBasis : sizeBasis) * scale
        let mid = size.width / 2
        var out: [Item: CGRect] = [:]
        let stick = 0.236 * u, dpad = 0.27 * u, face = 0.30 * u
        let tw = 0.2 * u, th = 0.15 * u, bumperH = 0.082 * u
        // The same margin from each edge, the widest the notch or the menu's strip needs.
        let edge = max(insets.left, insets.right, menuEdge) + (wide ? 0.02 * u : 0.012 * u)
        let lx = edge, rx = size.width - edge
        let base = size.height - max(insets.bottom + 0.02 * u, wide ? 0.11 * u : 0.085 * u)
        let midY = base - stick / 2
        let beside = 0.09 * u
        let left = CGRect(x: lx, y: base - stick, width: stick, height: stick), right = CGRect(x: rx - stick, y: base - stick, width: stick, height: stick)
        out[.leftStick] = left; out[.rightStick] = right
        out[.dpad] = CGRect(x: left.maxX + beside, y: midY - dpad / 2, width: dpad, height: dpad)
        out[.face] = CGRect(x: right.minX - beside - face, y: midY - face / 2, width: face, height: face)
        let above = 0.07 * u, between = 0.018 * u
        for (stickRect, bumper, trigger) in [(left, Item.leftBumper, Item.leftTrigger), (right, .rightBumper, .rightTrigger)] {
            let bumperTop = stickRect.minY - above - bumperH
            out[bumper] = CGRect(x: stickRect.midX - tw / 2, y: bumperTop, width: tw, height: bumperH)
            out[trigger] = CGRect(x: stickRect.midX - tw / 2, y: bumperTop - between - th, width: tw, height: th)
        }
        let cw = 0.117 * u, ch = 0.058 * u, gap = 0.078 * u
        out[.back] = CGRect(x: mid - gap / 2 - cw, y: base - ch, width: cw, height: ch)
        out[.start] = CGRect(x: mid + gap / 2, y: base - ch, width: cw, height: ch)
        return out
    }

    private static func placePorthole(size: CGSize, insets: Insets, scale: CGFloat, wide: Bool) -> [Item: CGRect] {
        let u = min(min(size.width, size.height), wide ? wideBasis : sizeBasis) * scale
        let mid = size.width / 2
        var out: [Item: CGRect] = [:]
        // One arrangement for every controller (drawn by the person, phone and iPad alike): on each side the direction pad / the face buttons over a stick, and beside the stick a
        // trigger over a bumper; View and Menu small in the middle at the bumpers' height.
        let stick = 0.244 * u, dpad = 0.24 * u, face = 0.31 * u
        let tw = 0.181 * u, th = 0.14 * u, bumperH = 0.075 * u
        // Mirror-image left and right: the same margin from each edge (the widest the notch or the menu's strip needs, so it fits whichever way the phone is turned), and the pad over its
        // stick centred like the face buttons over theirs.
        let across = wide ? 0.086 * u : 0.024 * u + 4
        let inset = max(insets.left, insets.right, menuEdge)
        let lx = inset + across
        let rx = size.width - inset - across
        let base = size.height - max(insets.bottom + 0.02 * u, wide ? 0.086 * u : 0.085 * u)
        let cL = lx + face / 2, cR = rx - face / 2                       // the middle of each column
        out[.leftStick] = CGRect(x: cL - stick / 2, y: base - stick, width: stick, height: stick)
        out[.dpad] = CGRect(x: cL - dpad / 2, y: base - stick - 0.054 * u - dpad, width: dpad, height: dpad)
        let rStick = CGRect(x: cR - stick / 2, y: base - stick, width: stick, height: stick)
        out[.rightStick] = rStick
        out[.face] = CGRect(x: rx - face, y: rStick.minY - 0.03 * u - face, width: face, height: face)
        let lcol = cL + stick / 2 + 0.067 * u, rcol = cR - stick / 2 - 0.067 * u - tw
        for (item, x) in [(Item.leftBumper, lcol), (.rightBumper, rcol)] { out[item] = CGRect(x: x, y: base - bumperH, width: tw, height: bumperH) }
        for (item, x) in [(Item.leftTrigger, lcol), (.rightTrigger, rcol)] { out[item] = CGRect(x: x, y: base - bumperH - 0.065 * u - th, width: tw, height: th) }
        let cw = 0.117 * u, ch = 0.058 * u, gap = 0.078 * u
        out[.back] = CGRect(x: mid - gap / 2 - cw, y: base - bumperH, width: cw, height: ch)
        out[.start] = CGRect(x: mid + gap / 2, y: base - bumperH, width: cw, height: ch)
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
