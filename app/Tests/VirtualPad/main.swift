import CoreGraphics
import Foundation

var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) <= eps }

do {   // sticks
    let r: CGFloat = 60
    check(VirtualPadMath.stick(offset: CGVector(dx: 0, dy: 0), radius: r) == (0, 0), "stick: at the centre is at rest")
    check(VirtualPadMath.stick(offset: CGVector(dx: 5, dy: -4), radius: r) == (0, 0), "stick: inside the deadzone is at rest")
    let up = VirtualPadMath.stick(offset: CGVector(dx: 0, dy: -r), radius: r)
    check(near(up.x, 0) && near(up.y, 1), "stick: a thumb at the top edge is full up (screen y goes down, the pad's up is positive): \(up)")
    let left = VirtualPadMath.stick(offset: CGVector(dx: -r, dy: 0), radius: r)
    check(near(left.x, -1) && near(left.y, 0), "stick: the left edge is full left")
    let far = VirtualPadMath.stick(offset: CGVector(dx: 300, dy: 300), radius: r)
    check(near((far.x * far.x + far.y * far.y).squareRoot(), 1) && far.x > 0 && far.y < 0, "stick: far outside the base stays at its edge in the same direction (down right: x positive, y negative)")
    let just = VirtualPadMath.stick(offset: CGVector(dx: 0, dy: -(r * 0.14 + 1)), radius: r)
    check(just.y > 0 && just.y < 0.05, "stick: just past the deadzone starts from nearly zero, not from a jump (\(just.y))")
    let half = VirtualPadMath.stick(offset: CGVector(dx: r / 2, dy: 0), radius: r)
    check(half.x > 0.3 && half.x < 0.6, "stick: half way is about half (\(half.x))")
    check(VirtualPadMath.stick(offset: CGVector(dx: 10, dy: 10), radius: 0) == (0, 0) && VirtualPadMath.stick(offset: CGVector(dx: CGFloat.nan, dy: 3), radius: r) == (0, 0), "stick: no radius, or a broken number, is at rest")
    check(VirtualPadMath.axis(1) == 32767 && VirtualPadMath.axis(-1) == -32767 && VirtualPadMath.axis(0) == 0 && VirtualPadMath.axis(5) == 32767 && VirtualPadMath.axis(Double.nan) == 0, "axis: the 16-bit numbers XInput reports")
}

do {   // the direction pad
    let r: CGFloat = 60
    func d(_ dx: CGFloat, _ dy: CGFloat) -> UInt16 { VirtualPadMath.dpad(offset: CGVector(dx: dx, dy: dy), radius: r) }
    check(d(0, 0) == 0 && d(5, 5) == 0, "dpad: the middle is dead")
    check(d(40, 0) == 0x0008 && d(-40, 0) == 0x0004 && d(0, -40) == 0x0001 && d(0, 40) == 0x0002, "dpad: right, left, up, down")
    check(d(30, -30) == 0x0009 && d(-30, -30) == 0x0005 && d(-30, 30) == 0x0006 && d(30, 30) == 0x000A, "dpad: the diagonals are both directions")
    check(d(40, -10) == 0x0008 && d(10, -40) == 0x0001, "dpad: a little off the axis is still the one direction")
    // a slide round the pad goes through the directions in order
    var seen: [UInt16] = []
    for degrees in stride(from: 0.0, to: 360.0, by: 10) {
        let a = degrees * .pi / 180
        let m = d(CGFloat(cos(a)) * 40, CGFloat(-sin(a)) * 40)
        if seen.last != m { seen.append(m) }
    }
    check(seen.count >= 8 && !seen.contains(0), "dpad: a circle round it passes all eight directions and no gap (\(seen.count))")
}

do {   // the face buttons
    let s: CGFloat = 45
    func f(_ dx: CGFloat, _ dy: CGFloat) -> VirtualPadButton? { VirtualPadMath.face(offset: CGVector(dx: dx, dy: dy), spacing: s) }
    check(f(0, -s) == .y && f(0, s) == .a && f(-s, 0) == .x && f(s, 0) == .b, "face: Y up, A down, X left, B right")
    check(f(0, 0) == nil, "face: the middle presses nothing")
    check(f(5, -s - 8) == .y && f(s + 10, 4) == .b, "face: a touch a little off its button still presses it")
    check(f(s * 2.5, 0) == nil, "face: far outside presses nothing")
    check(f(s * 0.6, s * 0.6) != nil, "face: between two buttons presses the nearer one")
    check(f(s * 0.7, s * 0.4) == .b, "face: nearer B than A is B")
}

do {   // merging with a real controller
    var real = VirtualPadSample(); real.buttons = VirtualPadButton.a.rawValue; real.leftTrigger = 100; real.lx = 20000; real.ly = 0
    var virt = VirtualPadSample(); virt.buttons = VirtualPadButton.b.rawValue | VirtualPadButton.a.rawValue; virt.leftTrigger = 255; virt.lx = 0; virt.ly = 30000; virt.rx = 100
    let m = VirtualPadSample.merged(real, with: virt)
    check(m.buttons == (VirtualPadButton.a.rawValue | VirtualPadButton.b.rawValue), "merge: buttons from both")
    check(m.leftTrigger == 255 && m.rightTrigger == 0, "merge: the larger trigger")
    check(m.lx == 0 && m.ly == 30000, "merge: the stick pushed further wins, as a pair (not x from one and y from the other)")
    check(m.rx == 100, "merge: a stick only one of them touches comes from that one")
    check(VirtualPadSample().isNeutral && !m.isNeutral && VirtualPadSample.merged(VirtualPadSample(), with: VirtualPadSample()).isNeutral, "merge: nothing with nothing is nothing")
}

do {   // the layout, on many screens and at every size
    let screens: [(String, CGSize, VirtualPadLayout.Insets)] = [
        ("iPhone 15 Pro, landscape", CGSize(width: 852, height: 393), .init(left: 59, right: 59, top: 0, bottom: 21)),
        ("iPhone 17 Pro Max, landscape", CGSize(width: 956, height: 440), .init(left: 62, right: 62, top: 0, bottom: 21)),
        ("iPhone SE, landscape", CGSize(width: 667, height: 375), .init()),
        ("small iPhone, landscape", CGSize(width: 568, height: 320), .init()),
        ("iPad Pro 13, landscape", CGSize(width: 1366, height: 1024), .init(left: 0, right: 0, top: 24, bottom: 20)),
        ("iPad mini, landscape", CGSize(width: 1133, height: 744), .init(left: 0, right: 0, top: 24, bottom: 20)),
        ("a game window 1280x720", CGSize(width: 1280, height: 720), .init()),
    ]
    for (name, size, insets) in screens {
        var allFit = true, menuClear = true, inInsets = true
        for scale in stride(from: 0.5, through: 1.5, by: 0.1) {
            let f = VirtualPadLayout.frames(in: size, insets: insets, scale: CGFloat(scale))
            if !VirtualPadLayout.fits(f, in: size, insets: insets) { allFit = false }
            if f.values.contains(where: { $0.maxX > size.width - VirtualPadLayout.menuEdge + 0.5 }) { menuClear = false }
            if f.values.contains(where: { $0.minX < insets.left - 0.5 || $0.maxX > size.width - insets.right + 0.5 }) { inInsets = false }
        }
        check(allFit, "layout \(name): at every size from 0.5 to 1.5 all ten controls are on screen and none touches another")
        check(menuClear, "layout \(name): the right edge strip of the menu swipe is clear")
        check(inInsets, "layout \(name): inside the safe area on the sides")
        let normal = VirtualPadLayout.frames(in: size, insets: insets, scale: 1)
        check(normal.count == VirtualPadLayout.Item.allCases.count, "layout \(name): every control has a place")
        let tiny = normal.filter { min($0.value.width, $0.value.height) < 18 }.keys
        check(tiny.isEmpty || size.height < 340, "layout \(name): no control smaller than 18 pt at the normal size (\(tiny.count) are; each also takes touches 12 pt beyond its edge)")
    }
    let phone = VirtualPadLayout.frames(in: CGSize(width: 852, height: 393), insets: .init(left: 59, right: 59, top: 0, bottom: 21), scale: 1)
    let big = VirtualPadLayout.frames(in: CGSize(width: 1366, height: 1024), insets: .init(), scale: 1)
    check(big[.leftStick]!.width <= phone[.leftStick]!.width * 1.4, "layout: on an iPad the controls are a big phone's, not twice the size (\(Int(big[.leftStick]!.width)) vs \(Int(phone[.leftStick]!.width)))")
    check(phone[.dpad]!.maxY < phone[.leftStick]!.minY && phone[.face]!.maxY < phone[.rightStick]!.minY, "layout: the direction pad over the left stick, the diamond over the right")
    check(phone[.leftTrigger]!.maxY < phone[.leftBumper]!.minY && phone[.rightTrigger]!.maxY < phone[.rightBumper]!.minY, "layout: the trigger above the bumper in each corner")
    check(phone[.back]!.maxX < phone[.start]!.minX, "layout: View left of Menu")
}

do {   // the Porthole arrangement, the only one
    let screens: [(String, CGSize, VirtualPadLayout.Insets, Bool)] = [
        ("iPhone 15 Pro, notch on the left", CGSize(width: 852, height: 393), .init(left: 59, right: 0, top: 0, bottom: 21), false),
        ("iPhone 15 Pro, notch on the right", CGSize(width: 852, height: 393), .init(left: 0, right: 59, top: 0, bottom: 21), false),
        ("iPhone 17 Pro Max, landscape", CGSize(width: 956, height: 440), .init(left: 62, right: 62, top: 0, bottom: 21), false),
        ("iPhone SE, landscape", CGSize(width: 667, height: 375), .init(), false),
        ("small iPhone, landscape", CGSize(width: 568, height: 320), .init(), false),
        ("iPad Pro 13, landscape", CGSize(width: 1376, height: 1032), .init(), true),
        ("iPad Air 11, landscape", CGSize(width: 1180, height: 820), .init(), true),
        ("iPad mini, landscape", CGSize(width: 1133, height: 744), .init(), true),
    ]
    for (name, size, insets, wide) in screens {
        var fitAll = true, menuClear = true, inside = true, exact = true
        for scale in stride(from: 0.5, through: 1.5, by: 0.25) {
            let f = VirtualPadLayout.frames(in: size, insets: insets, scale: CGFloat(scale), preset: .porthole, wide: wide)
            if !VirtualPadLayout.fits(f, in: size, insets: insets) { fitAll = false }
            if Set(f.keys) != VirtualPadLayout.Preset.porthole.items { exact = false }
            if f.values.contains(where: { $0.maxX > size.width - VirtualPadLayout.menuEdge + 0.5 }) { menuClear = false }
            if f.values.contains(where: { $0.minX < insets.left - 0.5 || $0.maxX > size.width - insets.right + 0.5 }) { inside = false }
        }
        check(fitAll, "porthole \(name): every control is on screen and none touches another, at every size from 0.5 to 1.5")
        check(exact, "porthole \(name): all ten controls, no others")
        check(menuClear, "porthole \(name): the strip for the menu swipe on the right edge is clear")
        check(inside, "porthole \(name): inside the safe area on the sides")
        let f = VirtualPadLayout.frames(in: size, insets: insets, scale: 1, preset: .porthole, wide: wide)
        check(f.values.allSatisfy { min($0.width, $0.height) >= 18 } || size.height < 340, "porthole \(name): no control smaller than 18 pt at the normal size (each also takes touches 12 pt beyond its edge)")
        guard let ls = f[.leftStick], let rs = f[.rightStick], let dp = f[.dpad], let fc = f[.face], let lt = f[.leftTrigger], let rt = f[.rightTrigger],
              let lb = f[.leftBumper], let rb = f[.rightBumper], let back = f[.back], let start = f[.start] else { check(false, "porthole \(name): every control is there"); continue }
        check(near(ls.midX + rs.midX, size.width, 0.5) && near(dp.midX, ls.midX, 0.5) && near(fc.midX, rs.midX, 0.5), "porthole \(name): the sticks mirror each other, the pad is centred over the left stick and the face buttons over the right")
        check(near(lt.minX + rt.maxX, size.width, 0.5) && near(lb.minX + rb.maxX, size.width, 0.5) && near(lt.minX, lb.minX, 0.5), "porthole \(name): each trigger sits over its bumper and the two sides mirror")
        check(near(back.minX + start.maxX, size.width, 0.5) && near(back.minY, start.minY, 0.5) && back.maxX < start.minX, "porthole \(name): View and Menu are centred on the screen, View on the left")
        check(ls.maxY <= size.height - insets.bottom + 0.5 && dp.maxY < ls.minY && fc.maxY < rs.minY && lt.maxY < lb.minY, "porthole \(name): the pad over the stick, the face buttons over theirs, the trigger over the bumper")
        check(ls.maxX < lt.minX && rt.maxX < rs.minX, "porthole \(name): the triggers and bumpers are between the sticks")
        let covered = f.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        check(covered / (size.width * size.height) < 0.23, "porthole \(name): the controls cover under 23% of the screen (\(Int(covered / (size.width * size.height) * 100))%)")
        if let room = VirtualPadLayout.centreRoom(frames: f, top: size.height * 0.75) {
            check(near(room.midX, size.width / 2, 0.5) && room.minX > lt.maxX && room.maxX < rt.minX && room.maxY < back.minY, "porthole \(name): the room for the overlays is centred, between the trigger columns and above View and Menu")
        }
    }
    let phoneF = VirtualPadLayout.frames(in: CGSize(width: 852, height: 393), insets: .init(), scale: 1, preset: .porthole, wide: false)
    let padF = VirtualPadLayout.frames(in: CGSize(width: 1376, height: 1032), insets: .init(), scale: 1, preset: .porthole, wide: true)
    check((padF[.leftStick]?.width ?? 0) > (phoneF[.leftStick]?.width ?? 0) * 1.3, "porthole: the controls are drawn bigger on an iPad than on a phone")
    check(VirtualPadLayout.centreRoom(frames: padF, top: 774) != nil, "porthole: a 13-inch iPad has room for the overlays under a 16:9 picture")
    check(VirtualPadLayout.Preset.allCases == [.porthole, .cornerSticks] && VirtualPadLayout.Preset(rawValue: "racing") == nil && VirtualPadLayout.preset(game: "racing", last: "retro") == .porthole && VirtualPadLayout.preset(game: nil, last: nil) == .porthole,
          "presets: Porthole and Corner sticks, and a name an earlier build stored that no longer exists is read as Porthole")
    check(VirtualPadLayout.preset(game: "cornerSticks", last: nil) == .cornerSticks && VirtualPadLayout.preset(game: nil, last: "cornerSticks") == .cornerSticks && VirtualPadLayout.preset(game: "porthole", last: "cornerSticks") == .porthole,
          "presets: a game's own choice wins over the one chosen last")
    check(!VirtualPadLayout.Preset.porthole.detail.isEmpty && VirtualPadLayout.Preset.porthole.detail.count < 190, "porthole: it has a short description")
    check(VirtualPadStyle.classic.label("View") == "Select" && VirtualPadStyle.classic.label("Menu") == "Start" && VirtualPadStyle.classic.label("LB") == "L" && VirtualPadStyle.classic.label("RB") == "R", "the Super Nintendo's pad says Select, Start, L and R")
}

do {   // the Corner sticks arrangement (drawn by the person for an iPad)
    let screens: [(String, CGSize, VirtualPadLayout.Insets, Bool)] = [
        ("iPhone 15 Pro", CGSize(width: 852, height: 393), .init(left: 59, right: 59, top: 0, bottom: 21), false),
        ("iPhone SE", CGSize(width: 667, height: 375), .init(), false),
        ("small iPhone", CGSize(width: 568, height: 320), .init(), false),
        ("iPad Pro 13", CGSize(width: 1376, height: 1032), .init(left: 0, right: 0, top: 24, bottom: 20), true),
        ("iPad Air 11", CGSize(width: 1180, height: 820), .init(left: 0, right: 0, top: 24, bottom: 20), true),
        ("iPad mini", CGSize(width: 1133, height: 744), .init(left: 0, right: 0, top: 24, bottom: 20), true),
    ]
    for (name, size, insets, wide) in screens {
        var allFit = true, menuClear = true, inInsets = true
        for scale in stride(from: 0.5, through: 1.5, by: 0.1) {
            let f = VirtualPadLayout.frames(in: size, insets: insets, scale: CGFloat(scale), preset: .cornerSticks, wide: wide)
            if !VirtualPadLayout.fits(f, in: size, insets: insets) { allFit = false }
            if f.values.contains(where: { $0.maxX > size.width - VirtualPadLayout.menuEdge + 0.5 }) { menuClear = false }
            if f.values.contains(where: { $0.minX < insets.left - 0.5 || $0.maxX > size.width - insets.right + 0.5 }) { inInsets = false }
        }
        check(allFit, "corner sticks \(name): at every size from 0.5 to 1.5 all ten controls are on screen and none touches another")
        check(menuClear && inInsets, "corner sticks \(name): clear of the menu's edge strip and inside the safe area")
        let f = VirtualPadLayout.frames(in: size, insets: insets, scale: 1, preset: .cornerSticks, wide: wide)
        check(f.count == VirtualPadLayout.Item.allCases.count, "corner sticks \(name): every control has a place")
        let mirror = abs((f[.leftStick]!.minX) - (size.width - f[.rightStick]!.maxX)) < 0.5 && abs(f[.dpad]!.midY - f[.leftStick]!.midY) < 0.5 && abs(f[.face]!.midY - f[.rightStick]!.midY) < 0.5
        check(mirror, "corner sticks \(name): the two sides are mirror images, the direction pad and the face buttons level with the sticks")
        check(f[.leftStick]!.maxX < f[.dpad]!.minX && f[.face]!.maxX < f[.rightStick]!.minX, "corner sticks \(name): the direction pad and the face buttons are beside the sticks, towards the middle")
        check(f[.leftTrigger]!.maxY < f[.leftBumper]!.minY && f[.leftBumper]!.maxY < f[.leftStick]!.minY && f[.rightTrigger]!.maxY < f[.rightBumper]!.minY && f[.rightBumper]!.maxY < f[.rightStick]!.minY,
              "corner sticks \(name): a trigger over a bumper over the stick, in each corner")
        check(abs(f[.leftTrigger]!.midX - f[.leftStick]!.midX) < 0.5 && abs(f[.rightBumper]!.midX - f[.rightStick]!.midX) < 0.5, "corner sticks \(name): the triggers and bumpers are centred on their stick")
        check(f[.back]!.maxX < f[.start]!.minX && f[.dpad]!.maxX < f[.back]!.minX && f[.start]!.maxX < f[.face]!.minX, "corner sticks \(name): View and Menu sit between the direction pad and the face buttons")
    }
    let ipad = VirtualPadLayout.frames(in: CGSize(width: 1376, height: 1032), insets: .init(), scale: 1, preset: .cornerSticks, wide: true)
    let room = VirtualPadLayout.centreRoom(frames: ipad, top: 700)
    check(room != nil && room!.width > 400 && room!.height > 60 && room!.minX > ipad[.dpad]!.maxX && room!.maxX < ipad[.face]!.minX, "corner sticks: the middle between the direction pad and the face buttons is open, for the overlays")
    check(VirtualPadLayout.centreRoom(frames: VirtualPadLayout.frames(in: CGSize(width: 1376, height: 1032), insets: .init(), scale: 1, preset: .porthole, wide: true), top: 774) != nil, "porthole: its centre room is still found with the wider rule")
}

do {   // where the game's picture goes
    let ipad = CGSize(width: 1376, height: 1032), air = CGSize(width: 1180, height: 820), mini = CGSize(width: 1133, height: 744), phone = CGSize(width: 852, height: 393)
    let g169 = CGSize(width: 1280, height: 720), g43 = CGSize(width: 1024, height: 768), g219 = CGSize(width: 2560, height: 1080)
    let centred = PictureBand.fit(screen: ipad, guest: g169, up: false), up = PictureBand.fit(screen: ipad, guest: g169, up: true)
    check(near(centred.width, 1376) && near(centred.height, 774) && near(centred.minY, (1032 - 774) / 2), "picture: centred, a 16:9 picture fills the width of a 13-inch iPad with room above and below")
    check(near(up.width, centred.width) && near(up.height, centred.height) && up.minY == 0 && near(up.minX, centred.minX), "picture: moved up it is the same size, against the top edge, and still centred sideways")
    let upPad = PictureBand.rect(screen: ipad, guest: g169, placement: nil, isPad: true, controlsOn: true, enabled: true)
    check(near(upPad.minY, PictureBand.padCornerInset) && near(upPad.width, centred.width) && near(upPad.minX, 0), "picture: on an iPad it sits a corner's radius below the top edge, so the rounded corners do not cut it")
    check(PictureBand.fit(screen: ipad, guest: g43, up: true).maxY <= 1032 + 0.001 && near(PictureBand.fit(screen: ipad, guest: g43, up: true).height, 1032), "picture: a 4:3 picture fills the whole iPad (nothing to move into)")
    for (size, guest) in [(ipad, g169), (air, g219), (phone, g169), (mini, g43)] {
        let r = PictureBand.fit(screen: size, guest: guest, up: true)
        check(r.minX >= -0.001 && r.minY >= -0.001 && r.maxX <= size.width + 0.001 && r.maxY <= size.height + 0.001 && near(r.width / r.height, guest.width / guest.height, 0.001), "picture: the whole picture is on the screen, with its own shape (\(Int(size.width))x\(Int(size.height)), \(Int(guest.width))x\(Int(guest.height)))")
    }
    check(PictureBand.applies(screen: ipad, guest: g169, isPad: true, controlsOn: true, enabled: true), "picture: goes up on a 13-inch iPad with on-screen controls (258 pt free)")
    check(PictureBand.applies(screen: air, guest: g169, isPad: true, controlsOn: true, enabled: true), "picture: goes up on an 11-inch iPad Air (156 pt free, 136 after the corner margin)")
    check(!PictureBand.applies(screen: mini, guest: g169, isPad: true, controlsOn: true, enabled: true), "picture: stays on an iPad mini, which has only 107 pt free (87 after the corner margin)")
    check(!PictureBand.applies(screen: phone, guest: g169, isPad: false, controlsOn: true, enabled: true) && !PictureBand.applies(screen: phone, guest: g169, isPad: true, controlsOn: true, enabled: true), "picture: never moves on a phone")
    check(!PictureBand.applies(screen: ipad, guest: g169, isPad: true, controlsOn: false, enabled: true), "picture: stays when the on-screen controls are not in use (mouse and keyboard, a real controller)")
    check(!PictureBand.applies(screen: ipad, guest: g169, isPad: true, controlsOn: true, enabled: false), "picture: stays when the setting is off")
    check(!PictureBand.applies(screen: ipad, guest: g43, isPad: true, controlsOn: true, enabled: true), "picture: stays when it already fills the screen (a 4:3 game on a 4:3 iPad)")
    check(!PictureBand.applies(screen: CGSize(width: 1032, height: 1376), guest: g169, isPad: true, controlsOn: true, enabled: true), "picture: stays on an iPad held upright")
    // 4:3 and squarer pictures fill the screen by default, even where there would be room
    let g54 = CGSize(width: 1280, height: 1024), g1610 = CGSize(width: 1920, height: 1200)
    let tall = CGSize(width: 1500, height: 1000)     // a screen so wide that even a 4:3 picture would leave room if it were shrunk, and a 5:4 one too
    check(!PictureBand.applies(screen: ipad, guest: g54, isPad: true, controlsOn: true, enabled: true) && !PictureBand.applies(screen: tall, guest: g43, isPad: true, controlsOn: true, enabled: true), "picture: 4:3 and 5:4 pictures are left full screen by default")
    check(PictureBand.applies(screen: ipad, guest: g1610, isPad: true, controlsOn: true, enabled: true), "picture: a 16:10 picture can still go up on a 13-inch iPad (172 pt free)")
    // a layout's own placement
    let top = PicturePlacement(across: 0.5, down: 0, scale: 1), small = PicturePlacement(across: 1, down: 0, scale: 0.5)
    let phoneRect = PictureBand.rect(screen: phone, guest: g169, placement: small, isPad: false, controlsOn: true, enabled: true)
    check(near(phoneRect.width, 852 * 0 + 393 * 16 / 9 * 0.5, 0.01) && phoneRect.minY == 0 && near(phoneRect.maxX, 852), "picture: a layout's placement works on a phone: half size, in the top right corner (\(Int(phoneRect.width)) pt wide)")
    check(PictureBand.rect(screen: ipad, guest: g43, placement: top, isPad: true, controlsOn: true, enabled: true).minY == 0 && PictureBand.rect(screen: ipad, guest: g43, placement: PicturePlacement(down: 1, scale: 0.8), isPad: true, controlsOn: true, enabled: true).maxY == 1032,
          "picture: a layout's placement is kept for a 4:3 picture too")
    check(PictureBand.rect(screen: ipad, guest: g169, placement: top, isPad: true, controlsOn: true, enabled: false).minY == PictureBand.padCornerInset, "picture: a layout's placement does not depend on the iPad setting")
    check(PictureBand.rect(screen: ipad, guest: g169, placement: top, isPad: true, controlsOn: false, enabled: true) == PictureBand.fit(screen: ipad, guest: g169, up: false), "picture: the layout's placement waits until its controls are showing")
    check(PictureBand.rect(screen: ipad, guest: g169, placement: nil, isPad: true, controlsOn: true, enabled: true) == PictureBand.fit(screen: ipad, guest: g169, up: true, cornerInset: PictureBand.padCornerInset) && PictureBand.rect(screen: phone, guest: g169, placement: nil, isPad: false, controlsOn: true, enabled: true) == PictureBand.fit(screen: phone, guest: g169, up: false), "picture: automatic is the iPad rule, and nothing on a phone")
    for p in [PicturePlacement(across: 0, down: 0, scale: 0.5), PicturePlacement(across: 1, down: 1, scale: 1), PicturePlacement(across: 0.5, down: 0.5, scale: 0.7)] {
        for (size, guest) in [(ipad, g169), (phone, g169), (phone, g43), (air, g219)] {
            let r = PictureBand.fit(screen: size, guest: guest, placement: p)
            check(r.minX >= -0.001 && r.minY >= -0.001 && r.maxX <= size.width + 0.001 && r.maxY <= size.height + 0.001 && near(r.width / r.height, guest.width / guest.height, 0.001), "picture: a placed picture is whole, on the screen, with its own shape")
        }
    }
    // rounded corners
    let c = PictureBand.padCornerInset
    let fullTop = PictureBand.fit(screen: ipad, guest: g169, placement: PicturePlacement(down: 0), cornerInset: c)
    check(near(fullTop.minY, c) && near(fullTop.height, 774), "corners: a picture against the top that reaches both sides is moved down by the margin and keeps its size")
    check(PictureBand.fit(screen: ipad, guest: g43, placement: PicturePlacement(down: 0), cornerInset: c).minY == 0, "corners: a picture that fills the height has no room to move, so it stays")
    check(near(PictureBand.fit(screen: ipad, guest: g169, placement: PicturePlacement(down: 1), cornerInset: c).maxY, 1032 - c), "corners: a picture against the bottom that reaches both sides is moved up by the margin")
    check(PictureBand.fit(screen: ipad, guest: g169, placement: PicturePlacement(across: 0.5, down: 0, scale: 0.6), cornerInset: c).minY == 0, "corners: a picture that stays clear of the sides needs no margin")
    check(near(PictureBand.fit(screen: ipad, guest: g169, placement: PicturePlacement(across: 1, down: 0, scale: 0.6), cornerInset: c).minY, c), "corners: nor does one in a corner of the screen (it gets the margin)")
    let tight = CGSize(width: 1376, height: 790)
    check(near(PictureBand.fit(screen: tight, guest: g169, placement: PicturePlacement(down: 0), cornerInset: c).minY, 790 - 774), "corners: with less room than the margin it moves down as far as there is room (\(790 - 774) pt)")
    check(PictureBand.rect(screen: phone, guest: g169, placement: PicturePlacement(down: 0), isPad: false, controlsOn: true, enabled: true).minY == 0, "corners: no margin on a phone")
    let bad = PicturePlacement(across: .nan, down: 9, scale: -3).sanitized()
    check(bad.across == 0.5 && bad.down == 1 && bad.scale == 0.5 && PicturePlacement(across: 0.3, down: 0.6, scale: 0.84).sanitized() == PicturePlacement(across: 0.5, down: 0.5, scale: 0.84), "picture: a placement from a file is snapped to the three positions and a size in range")
}

do {   // the styles
    let faces: [VirtualPadButton] = [.a, .b, .x, .y]
    check(VirtualPadStyle.allCases.count == 4 && Set(VirtualPadStyle.allCases.map(\.title)).count == 4, "styles: four, each with its own name")
    check(VirtualPadStyle.allCases.allSatisfy { !$0.detail.isEmpty && $0.detail.count < 190 }, "styles: each has a short description")
    check(VirtualPadStyle.style(game: "playstation", last: "xbox") == .playstation && VirtualPadStyle.style(game: nil, last: "classic") == .classic && VirtualPadStyle.style(game: nil, last: nil) == .xbox
          && VirtualPadStyle.style(game: "gone", last: "nintendo") == .nintendo, "styles: a game's own choice, then the one chosen last, then Xbox")
    // Xbox: letters where they are, in the Xbox colours
    check(faces.map { VirtualPadStyle.xbox.face($0) } == [.text("A"), .text("B"), .text("X"), .text("Y")], "xbox: A B X Y")
    check(VirtualPadStyle.xbox.faceColor(.a) != nil && Set(faces.map { VirtualPadStyle.xbox.faceColor($0)! }.map { "\($0)" }).count == 4, "xbox: four different colours")
    check(VirtualPadStyle.xbox.label("LB") == "LB" && VirtualPadStyle.xbox.label("LT") == "LT" && VirtualPadStyle.xbox.label("Menu") == "Menu" && VirtualPadStyle.xbox.label("View") == "View", "xbox: LB LT Menu View")
    // PlayStation: the four shapes on the same four places, and its words
    check(VirtualPadStyle.playstation.face(.a) == .cross && VirtualPadStyle.playstation.face(.b) == .circle && VirtualPadStyle.playstation.face(.x) == .square && VirtualPadStyle.playstation.face(.y) == .triangle, "playstation: the bottom button is the cross, the right the circle, the left the square, the top the triangle")
    let ps = VirtualPadStyle.playstation
    check(ps.label("LB") == "L1" && ps.label("RB") == "R1" && ps.label("LT") == "L2" && ps.label("RT") == "R2" && ps.label("Menu") == "Options" && ps.label("View") == "Create", "playstation: L1 R1 L2 R2, Options and Create")
    let psc = ps.faceColor(.a)!, pso = ps.faceColor(.b)!, pss = ps.faceColor(.x)!, pst = ps.faceColor(.y)!
    check(psc.blue > psc.red && pso.red > pso.blue && pso.red > pso.green && pss.red > 0.8 && pss.blue > pss.green && pst.green > pst.red && pst.green > pst.blue, "playstation: the cross is blue, the circle red, the square pink, the triangle green")
    // Nintendo: the letters in Nintendo's places (by position), plain buttons
    let ns = VirtualPadStyle.nintendo
    check(ns.face(.a) == .text("B") && ns.face(.b) == .text("A") && ns.face(.x) == .text("Y") && ns.face(.y) == .text("X"), "nintendo: B at the bottom, A on the right, Y on the left, X at the top")
    check(ns.label("LB") == "L" && ns.label("RB") == "R" && ns.label("LT") == "ZL" && ns.label("RT") == "ZR" && ns.label("Menu") == "+" && ns.label("View") == "\u{2212}", "nintendo: L R ZL ZR, plus and minus")
    check(faces.allSatisfy { ns.faceColor($0) == nil }, "nintendo: plain buttons, no colours")
    // Super Nintendo: the same letters, in its four colours
    let sn = VirtualPadStyle.classic
    check(faces.map { sn.face($0) } == faces.map { ns.face($0) }, "classic: the letters are Nintendo's")
    check(sn.faceColor(.b)!.red > 0.8 && sn.faceColor(.b)!.green < 0.3, "classic: the right button (A) is red")
    check(sn.faceColor(.a)!.red > 0.9 && sn.faceColor(.a)!.green > 0.7 && sn.faceColor(.a)!.blue < 0.3, "classic: the bottom button (B) is yellow")
    check(sn.faceColor(.y)!.blue > sn.faceColor(.y)!.red && sn.faceColor(.y)!.blue > 0.8, "classic: the top button (X) is blue")
    check(sn.faceColor(.x)!.green > sn.faceColor(.x)!.red && sn.faceColor(.x)!.green > sn.faceColor(.x)!.blue, "classic: the left button (Y) is green")
    // what the game receives never depends on the style: the same four XInput masks in every style
    check(faces.map(\.rawValue) == [0x1000, 0x2000, 0x4000, 0x8000], "the buttons the game sees are the Xbox A B X Y masks in every style (the style only changes what is drawn)")
}

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
