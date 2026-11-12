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
        let tiny = normal.filter { min($0.value.width, $0.value.height) < 28 }.keys
        check(tiny.isEmpty || size.height < 340, "layout \(name): no control smaller than 28 pt at the normal size (\(tiny.count) are)")
    }
    let phone = VirtualPadLayout.frames(in: CGSize(width: 852, height: 393), insets: .init(left: 59, right: 59, top: 0, bottom: 21), scale: 1)
    let big = VirtualPadLayout.frames(in: CGSize(width: 1366, height: 1024), insets: .init(), scale: 1)
    check(big[.leftStick]!.width <= phone[.leftStick]!.width * 1.4, "layout: on an iPad the controls are a big phone's, not twice the size (\(Int(big[.leftStick]!.width)) vs \(Int(phone[.leftStick]!.width)))")
    check(phone[.leftStick]!.maxX < phone[.dpad]!.minX && phone[.face]!.minX > phone[.rightStick]!.maxX, "layout: stick then direction pad on the left, right stick then the diamond on the right")
    check(phone[.leftTrigger]!.maxY < phone[.leftBumper]!.minY && phone[.rightTrigger]!.maxY < phone[.rightBumper]!.minY, "layout: the trigger above the bumper in each corner")
    check(phone[.back]!.maxX < phone[.start]!.minX, "layout: View left of Menu")
}

do {   // the layout presets
    let screens: [(String, CGSize, VirtualPadLayout.Insets)] = [
        ("iPhone 15 Pro", CGSize(width: 852, height: 393), .init(left: 59, right: 59, top: 0, bottom: 21)),
        ("iPhone SE", CGSize(width: 667, height: 375), .init()),
        ("small iPhone", CGSize(width: 568, height: 320), .init()),
        ("iPad Pro 13", CGSize(width: 1366, height: 1024), .init(left: 0, right: 0, top: 24, bottom: 20)),
        ("iPad mini", CGSize(width: 1133, height: 744), .init(left: 0, right: 0, top: 24, bottom: 20)),
    ]
    check(VirtualPadLayout.Preset.allCases.count == 8 && Set(VirtualPadLayout.Preset.allCases.map(\.title)).count == 8, "presets: eight layouts, each with its own name")
    check(VirtualPadLayout.Preset.standard.items == Set(VirtualPadLayout.Item.allCases) && VirtualPadLayout.Preset(rawValue: "racing") == .racing && VirtualPadLayout.Preset(rawValue: "nonsense") == nil, "presets: the standard one has every control, and a name that is not one is no layout")
    for preset in VirtualPadLayout.Preset.allCases {
        var fitAll = true, menuClear = true, inside = true, hasExactly = true
        for (_, size, insets) in screens {
            for scale in stride(from: 0.5, through: 1.5, by: 0.25) {
                let f = VirtualPadLayout.frames(in: size, insets: insets, scale: CGFloat(scale), preset: preset)
                if !VirtualPadLayout.fits(f, in: size, insets: insets) { fitAll = false }
                if Set(f.keys) != preset.items { hasExactly = false }
                if f.values.contains(where: { $0.maxX > size.width - VirtualPadLayout.menuEdge + 0.5 }) { menuClear = false }
                if f.values.contains(where: { $0.minX < insets.left - 0.5 || $0.maxX > size.width - insets.right + 0.5 }) { inside = false }
            }
        }
        check(fitAll, "preset \(preset.title): every control is on screen and none touches another, on five screens at five sizes")
        check(hasExactly, "preset \(preset.title): it has the controls it says it has, and no others")
        check(menuClear, "preset \(preset.title): the strip for the menu swipe on the right edge is clear")
        check(inside, "preset \(preset.title): inside the safe area on the sides")
        let phone = VirtualPadLayout.frames(in: CGSize(width: 852, height: 393), insets: .init(left: 59, right: 59, top: 0, bottom: 21), scale: 1, preset: preset)
        check(phone.values.allSatisfy { min($0.width, $0.height) >= 28 }, "preset \(preset.title): no control smaller than 28 pt on an iPhone 15 Pro at the normal size (each also takes touches 12 pt beyond its edge)")
        check(!preset.detail.isEmpty && preset.detail.count < 160, "preset \(preset.title): it has a short description")
    }
    check(VirtualPadLayout.preset(game: "racing", last: "retro") == .racing && VirtualPadLayout.preset(game: nil, last: "retro") == .retro && VirtualPadLayout.preset(game: nil, last: nil) == .standard
          && VirtualPadLayout.preset(game: "gone", last: "minimal") == .minimal && VirtualPadLayout.preset(game: "gone", last: "also gone") == .standard, "presets: a game's own choice wins, then the one chosen last, then the standard (and a name that no longer exists is skipped)")
    for preset in VirtualPadLayout.Preset.allCases {
        let f = VirtualPadLayout.frames(in: CGSize(width: 852, height: 393), insets: .init(left: 59, right: 59, top: 0, bottom: 21), scale: 1, preset: preset)
        let covered = f.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        check(covered / (852 * 393) < 0.16, "preset \(preset.title): the controls cover less than 16% of an iPhone 15 Pro's screen (\(Int(covered / (852 * 393) * 100))%)")
        let free = CGRect(x: 320, y: 60, width: 852 - 320 - 320, height: 393 - 60 - 60)
        check(!f.values.contains(where: { $0.intersects(free) }) || preset == .racing || preset == .playstation, "preset \(preset.title): the middle of the screen is left free")
    }
    // choosing a style brings the shape of that controller
    check(VirtualPadStyle.allCases.map(\.nativePreset) == [.xbox, .playstation, .switchPad, .retro], "styles: each one has its own controller's layout (Xbox, PlayStation, Switch, and the Super Nintendo's pad)")
    check(Set(VirtualPadStyle.allCases.map(\.nativePreset)).count == 4, "styles: four styles, four different layouts")
    check(VirtualPadLayout.Preset.retro.items.isDisjoint(with: [.leftStick, .rightStick, .leftTrigger, .rightTrigger]), "the Super Nintendo's pad has no sticks and no triggers")
    check(VirtualPadStyle.classic.label("View") == "Select" && VirtualPadStyle.classic.label("Menu") == "Start" && VirtualPadStyle.classic.label("LB") == "L" && VirtualPadStyle.classic.label("RB") == "R", "the Super Nintendo's pad says Select, Start, L and R")
    let phoneSize = CGSize(width: 852, height: 393), phoneInsets = VirtualPadLayout.Insets(left: 59, right: 59, top: 0, bottom: 21)
    func frames(_ p: VirtualPadLayout.Preset) -> [VirtualPadLayout.Item: CGRect] { VirtualPadLayout.frames(in: phoneSize, insets: phoneInsets, scale: 1, preset: p) }
    let std = frames(.standard), mir = frames(.mirrored), retro = frames(.retro), racing = frames(.racing), minimal = frames(.minimal)
    let psf = frames(.playstation)
    check(psf[.dpad]!.maxX < psf[.leftStick]!.minX && psf[.leftStick]!.maxX <= psf[.rightStick]!.minX && psf[.rightStick]!.maxX < psf[.face]!.minX, "playstation: the direction pad, then the left stick and the right stick side by side, then the diamond")
    check(psf[.leftStick]!.minY == psf[.rightStick]!.minY && psf[.rightStick]!.minX - psf[.leftStick]!.maxX < psf[.leftStick]!.width * 0.4, "playstation: the two sticks are level with each other and close together")
    check(psf[.leftStick]!.midX < phoneSize.width / 2 && psf[.rightStick]!.midX > phoneSize.width / 2 - 1, "playstation: the sticks are in the middle, one each side of the centre of the screen")
    check(psf[.leftStick]!.width == std[.leftStick]!.width && psf[.leftTrigger] != nil && psf[.back] != nil, "playstation: the same sizes and shoulders as the standard")
    let xb = frames(.xbox), sw = frames(.switchPad)
    check(xb[.leftStick]!.minY < xb[.dpad]!.minY && xb[.face]!.minY < xb[.rightStick]!.minY, "xbox: the left stick and the diamond sit higher than the direction pad and the right stick")
    check(xb[.leftStick]!.minX < xb[.dpad]!.minX && xb[.rightStick]!.maxX < xb[.face]!.minX, "xbox: the left stick outside the pad, the right stick inside the diamond")
    check(sw[.leftStick]!.maxY <= sw[.dpad]!.minY && abs(sw[.leftStick]!.midX - sw[.dpad]!.midX) < 1, "switch: the left stick directly over the direction pad")
    check(sw[.face]!.maxY <= sw[.rightStick]!.minY && abs(sw[.face]!.midX - sw[.rightStick]!.midX) < 1, "switch: the diamond directly over the right stick")
    check(psf[.leftStick]!.minX > psf[.dpad]!.maxX && xb[.leftStick]!.minX < xb[.dpad]!.minX && sw[.leftStick]!.minX == sw[.dpad]!.minX, "the PlayStation, Xbox and Switch layouts really differ from one another")
    check(mir[.leftStick]!.midX > phoneSize.width / 2 && mir[.face]!.midX < phoneSize.width / 2 && std[.leftStick]!.midX < phoneSize.width / 2, "mirrored: the left stick is on the right and the face buttons on the left (the standard has them the other way)")
    check(mir[.leftStick]!.width == std[.leftStick]!.width && mir[.face]!.minY == std[.face]!.minY, "mirrored: the same sizes and heights as the standard")
    check(retro[.dpad]!.width > std[.dpad]!.width && retro[.face]!.width > std[.face]!.width, "retro: a bigger direction pad and bigger face buttons than the standard")
    check(retro[.leftStick] == nil && retro[.rightStick] == nil, "retro: no sticks")
    check(racing[.rightTrigger]!.height > racing[.rightTrigger]!.width * 2 && racing[.rightTrigger]!.maxX > racing[.leftTrigger]!.maxX, "racing: the pedals are tall, the gas at the edge and the brake beside it")
    check(racing[.leftStick]!.width > std[.leftStick]!.width && racing[.rightStick] == nil && racing[.dpad] == nil, "racing: a bigger steering stick, no right stick or direction pad")
    check(minimal[.face]!.width > std[.face]!.width && minimal[.rightStick] == nil && minimal[.dpad] == nil && minimal[.leftTrigger] == nil, "minimal: bigger face buttons and nothing else but a stick, bumpers, View and Menu")
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
