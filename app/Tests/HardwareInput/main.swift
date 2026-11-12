// Host tests for the hardware keyboard and mouse mapping: HID usage -> virtual key, held-key and button edges, focus gating, wheel notches, mouse motion carry,
// the pointer route and the automatic pointer lock.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok    " : "FAIL  ", what); if !ok { failures += 1 } }

// --- Keys: the usual PC keyboard
func vk(_ u: Int) -> Int32? { HardwareKeyMap.vk(forHIDUsage: u) }
check(vk(0x04) == 0x41 && vk(0x1D) == 0x5A, "letters a..z are VK_A..VK_Z")
check(vk(0x1E) == 0x31 && vk(0x26) == 0x39 && vk(0x27) == 0x30, "digits 1..9 and 0")
check(vk(0x28) == 0x0D && vk(0x29) == 0x1B && vk(0x2A) == 0x08 && vk(0x2B) == 0x09 && vk(0x2C) == 0x20, "Enter, Esc, Backspace, Tab, Space")
check(vk(0x3A) == 0x70 && vk(0x45) == 0x7B, "F1..F12")
check(vk(0x4F) == 0x27 && vk(0x50) == 0x25 && vk(0x51) == 0x28 && vk(0x52) == 0x26, "arrows (right, left, down, up)")
check(vk(0x4A) == 0x24 && vk(0x4D) == 0x23 && vk(0x4B) == 0x21 && vk(0x4E) == 0x22 && vk(0x49) == 0x2D && vk(0x4C) == 0x2E, "Home End PageUp PageDown Insert Delete")
check(vk(0x59) == 0x61 && vk(0x61) == 0x69 && vk(0x62) == 0x60 && vk(0x63) == 0x6E, "keypad 1..9, 0 and the decimal point")
check(vk(0xE0) == 0xA2 && vk(0xE4) == 0xA3, "left and right Ctrl keep their side")
check(vk(0xE1) == 0xA0 && vk(0xE5) == 0xA1, "left and right Shift keep their side")
check(vk(0xE2) == 0xA4 && vk(0xE6) == 0xA5, "left and right Alt keep their side")
check(vk(0xE3) == 0x5B && vk(0xE7) == 0x5C, "Command is the Windows key")
check(vk(0x39) == 0x14, "Caps Lock")
check(vk(0x35) == 0xC0 && vk(0x2D) == 0xBD && vk(0x2E) == 0xBB, "grave, minus and equals")
check(vk(0x7B) == nil && vk(0x7C) == nil && vk(0x7D) == nil, "Cut, Copy, Paste have no Windows key and are not sent")
check(vk(0x01) == nil && vk(0xFF) == nil, "usages that are not keys are not sent")
// every usage 0x04...0xE7 that maps does so to a plausible key code
var bad = 0
for u in 0x04...0xE7 { if let k = vk(u), k <= 0 || k > 0xFE { bad += 1 } }
check(bad == 0, "no mapped key is outside the virtual key range")

// --- Chords the app keeps for itself
let ctrlAlt: Set<Int32> = [0xA2, 0xA4]
check(HardwareKeyMap.isPointerLockChord(0x50, held: ctrlAlt) && HardwareKeyMap.isPointerLockChord(0x50, held: [0xA3, 0xA5]), "Ctrl+Alt+P is the pointer lock chord (either side)")
check(!HardwareKeyMap.isPointerLockChord(0x50, held: [0xA2]) && !HardwareKeyMap.isPointerLockChord(0x50, held: []), "P alone, or with only Ctrl, is the game's")
check(HardwareKeyMap.isMenuChord(0x4D, held: ctrlAlt) && !HardwareKeyMap.isMenuChord(0x4D, held: [0xA4]) && !HardwareKeyMap.isMenuChord(0x50, held: ctrlAlt), "Ctrl+Alt+M opens the in-game menu, M alone does not")

// --- Held keys and focus
var gate = FocusGate<Int32>()
gate.press(0x57, focused: true)
check(gate.wanted(focused: true) == [0x57], "a key pressed with focus is wanted")
check(gate.wanted(focused: false).isEmpty, "losing focus hides what is held")
gate.focusLost()
check(gate.wanted(focused: true).isEmpty, "a key held when focus was lost stays hidden when focus comes back")
gate.release(0x57)
gate.press(0x57, focused: true)
check(gate.wanted(focused: true) == [0x57], "...until it is let go and pressed again")
gate.press(0x41, focused: false)
check(gate.wanted(focused: true) == [0x57], "a key pressed while the game did not have focus never reaches it")
var edges = HeldEdges<Int32>()
var e = edges.update([0x57, 0xA0])
check(e.down == [0x57, 0xA0].sorted() && e.up.isEmpty, "held edges: both go down")
e = edges.update([0x57])
check(e.up == [0xA0] && e.down.isEmpty, "held edges: only what was let go goes up")
e = edges.update([])
check(e.up == [0x57], "held edges: everything goes up when nothing is wanted")

// --- Mouse buttons
check(HWMouseButton.left.event(down: true) == (0x0002, 0) && HWMouseButton.left.event(down: false) == (0x0004, 0), "left button flags")
check(HWMouseButton.right.event(down: true) == (0x0008, 0) && HWMouseButton.right.event(down: false) == (0x0010, 0), "right button flags")
check(HWMouseButton.middle.event(down: true) == (0x0020, 0) && HWMouseButton.middle.event(down: false) == (0x0040, 0), "middle button flags")
check(HWMouseButton.x1.event(down: true) == (0x0080, 1) && HWMouseButton.x2.event(down: false) == (0x0100, 2), "side buttons are XBUTTON1 and XBUTTON2")
var raw = RawMouseButtons<Int>()
raw.attach(1, held: [])
var r = raw.update(1, button: .left, down: true)
check(r.down == [.left] && r.up.isEmpty, "raw buttons: a press is one down edge")
r = raw.update(1, button: .left, down: true)
check(r.down.isEmpty && r.up.isEmpty, "raw buttons: a repeated report is not a second edge")
r = raw.sample(1, held: [.left, .right])
check(r.down == [.right], "raw buttons: sampling finds a press whose callback was lost")
r = raw.update(1, button: .left, down: false)
check(r.up == [.left], "raw buttons: release")
var held = RawMouseButtons<Int>()
held.attach(2, held: [.left])
check(held.sample(2, held: [.left]).down.isEmpty, "raw buttons: a button already held when the mouse attached does not click")
check(held.sample(2, held: []).up.isEmpty, "...and its release is not an edge either")
check(held.update(2, button: .left, down: true).down == [.left], "...but the next press is")
check(MouseButtonSources.merge(current: [.left], fallback: [.left, .right], rawSeen: [.left], focused: true) == [.left, .right], "buttons: raw ones keep their authority, the fallback adds the others")
check(MouseButtonSources.merge(current: [.left], fallback: [.left], rawSeen: [.left], focused: false).isEmpty, "buttons: nothing without focus")

// --- Motion: the fraction that integer movement loses is carried
var carry = HWMotionCarry()
var total = 0
for _ in 0..<12 { total += Int(carry.add(0.25, 0, gain: 1).dx) }
check(total == 3, "motion: twelve movements of a quarter add up to 3, none are lost")
carry.reset()
check(carry.add(0.4, -0.4, gain: 0.5) == (0, 0) && carry.add(0.4, -0.4, gain: 0.5) == (0, 0), "motion: slow movement waits for a whole count")
check(carry.add(100, 0, gain: 2).dx == 200, "motion: the gain scales it")
check(carry.add(.nan, 0, gain: 1) == (0, 0), "motion: not a number is ignored")
check(carry.add(1e9, -1e9, gain: 1).dx == 30000, "motion: one report cannot fling the cursor")

// --- Wheel
var wheel = WheelAccumulator()
var n = wheel.add(0, 1)
check(n.count == 1 && n[0].flags == WheelAccumulator.wheel && n[0].delta == 120, "wheel: one notch up")
n = wheel.add(0, -2)
check(n.count == 2 && n.allSatisfy { $0.delta == -120 }, "wheel: two notches down")
n = wheel.add(1, 0)
check(n.count == 1 && n[0].flags == WheelAccumulator.hwheel && n[0].delta == 120, "wheel: sideways")
wheel.reset()
check(wheel.add(0, 0.4).isEmpty && wheel.add(0, 0.4).isEmpty && wheel.add(0, 0.4).count == 1, "wheel: smooth scrolling adds up to a notch")
// a notched wheel that reads 0.3 per click: a lone click is one notch, and two alike lone clicks teach the size of a click
var click = WheelAccumulator()
check(click.add(0, 0.3, at: 10.0).isEmpty, "wheel: a click of 0.3 is not a notch by itself")
var flushed = click.flushIdle()
check(flushed.count == 1 && flushed[0].flags == WheelAccumulator.wheel && flushed[0].delta == 120, "wheel: ...but after the pause it is sent as one notch")
check(click.flushIdle().isEmpty, "wheel: a second look sends nothing more")
check(click.add(0, -0.3, at: 11.0).isEmpty, "wheel: the next lone click")
flushed = click.flushIdle()
check(flushed.count == 1 && flushed[0].delta == -120 && click.clickUnit != nil && abs(click.clickUnit! - 0.3) < 0.01, "wheel: two alike lone clicks teach a click size of 0.3")
var spin = click.add(0, 0.3, at: 12.00) + click.add(0, 0.3, at: 12.02) + click.add(0, 0.3, at: 12.04)
check(spin.count == 3 && click.flushIdle().isEmpty, "wheel: a fast spin now sends every click, and the pause adds none")
// a smooth scroll (many tiny readings) keeps adding up to whole notches and gets no extra notch at the end
var smooth = WheelAccumulator()
var sent = 0
for i in 0..<50 { sent += smooth.add(0, 0.05, at: 20.0 + Double(i) * 0.01).count }
check(sent == 2 && smooth.flushIdle().isEmpty, "wheel: smooth scrolling is unchanged (50 x 0.05 = 2 notches, none added at the end)")
// the leftover of one turn does not leak into the next turn
var leak = WheelAccumulator()
_ = leak.add(0, 0.9, at: 30.0); _ = leak.flushIdle()
check(leak.add(0, 0.5, at: 31.0).isEmpty, "wheel: the next turn starts clean")
// --- A wheel click as iPadOS reports it (readings from a Logitech G502 X): a climbing run that is the distance so far, about 94.5 at the peak
func click(_ g: inout WheelGesture, _ values: [Double], from t0: Double, step: Double = 0.010) -> Int {
    var total = 0
    for (i, v) in values.enumerated() { total += g.add(v, at: t0 + Double(i) * step) }
    return total + g.flushIdle()
}
var axesA = WheelAxes()
let a1 = axesA.map(-29.3, 0)
check(axesA.secondIsVertical == false && a1.vertical == -29.3 && a1.horizontal == 0, "wheel axes: a wheel in the first value is vertical, negative up")
var axesB = WheelAxes()
let b1 = axesB.map(0, 26.0)
check(axesB.secondIsVertical == true && b1.vertical == -26.0 && b1.horizontal == 0, "wheel axes: a wheel in the second value is vertical too, positive up becomes negative up")
var axesC = WheelAxes()
_ = axesC.map(-0.017, 0)
check(axesC.secondIsVertical == nil, "wheel axes: the 0.017 start-of-gesture reading decides nothing")
var axesD = WheelAxes()
_ = axesD.map(-50, 0)
var flipped = false
for _ in 0..<12 { flipped = axesD.map(0, 80).changed || flipped }
check(axesD.secondIsVertical == true && flipped, "wheel axes: the choice changes when the other axis carries far more (the display changed)")
var axesE = WheelAxes()
_ = axesE.map(-90, 0)
for _ in 0..<3 { _ = axesE.map(-90, 0) }
_ = axesE.map(0, 120)
check(axesE.secondIsVertical == false, "wheel axes: a single sideways click does not change it")
func real(_ g: inout WheelGesture, _ values: [(Double, Double)], from t0: Double) -> Int {
    var total = 0
    for (dt, v) in values { total += g.add(v, at: t0 + dt / 1000) }
    return total + g.flushIdle()
}
var axesN = WheelAxes()
_ = axesN.map(0, 0.017); _ = axesN.map(0, -2.67); _ = axesN.map(0, -7.3)
check(axesN.secondIsVertical == nil, "wheel axes: a few points on the other value at the start decide nothing")
_ = axesN.map(-8.5, 0); _ = axesN.map(-30.9, 0)
check(axesN.secondIsVertical == false, "wheel axes: the first real turn decides (the first value here)")
// A slow click arrives as ONE reading of about 0.017 (its sign the direction) and nothing after it: 6 up and 14 down in the 1.3.16 log were not counted at all.
var lone = WheelGesture()
check(lone.add(0.0173, at: 500.0) == 0 && lone.flushIdle(at: 500.05) == 0 && lone.flushIdle(at: 500.19) == 1, "wheel gesture: a lone 0.017 is one notch up once nothing followed it for 180 ms")
check(lone.flushIdle(at: 500.5) == 0, "wheel gesture: ...and only once")
var loneRun = 0
for (i, v) in [-0.0173, -0.0173, -0.39, -0.0173, -0.069, -0.0173].enumerated() { loneRun += lone.add(v, at: 510.0 + Double(i) * 0.3) }
loneRun += lone.flushIdle(at: 520.0)
check(loneRun == -6, "wheel gesture: six slow clicks 300 ms apart are six notches down (got \(loneRun))")
var loneBoth = WheelGesture()
var mixed = loneBoth.add(0.0173, at: 530.0) + loneBoth.add(-0.0173, at: 530.2) + loneBoth.add(0.0173, at: 530.4) + loneBoth.flushIdle(at: 531)
check(mixed == 1, "wheel gesture: up, down, up slow clicks cancel to one notch up (got \(mixed))")
// the axis of a lone slow click, before any run has decided it
var axesL = WheelAxes()
let l1 = axesL.map(0, -0.0173)
check(axesL.secondIsVertical == nil && l1.vertical == 0.0173 && l1.horizontal == 0, "wheel axes: a lone 0.017 in the second value is vertical for now (positive there is up)")
var axesM = WheelAxes()
let m1 = axesM.map(0, 4.9)
check(m1.vertical == -4.9 && m1.horizontal == 0, "wheel axes: the first small run in the second value does not go sideways")
let m2 = axesM.map(0, 33.8)
check(axesM.secondIsVertical == true && !m2.changed, "wheel axes: deciding what was already assumed changes nothing")
// --- Counted clicks (Factorio, 2026-11-05): one deliberate click is a lone 0.017; quick clicks are a ramp whose size says how many there were
func ramp(_ values: [Double], gap: Double = 0.016) -> Int {
    var g = WheelGesture(), total = 0
    for (i, v) in values.enumerated() { total += g.add(v, at: 700.0 + Double(i) * gap) }
    return total + g.flushIdle()
}
check(ramp([0.0173]) == 1 && ramp([-0.0173]) == -1, "wheel ramp: one deliberate click is one notch, either way")
check(ramp([-0.0173, -7.95]) == -1, "wheel ramp: two clicks (0.017, 8): at least a notch; a touch under 4 points is none")
check(ramp([-0.0173, -2.0]) == 0 || ramp([-0.0173, -2.0]) == -1, "wheel ramp: a touch of the wheel is at most one notch")
check(ramp([0.0173, 8.9, 31.4]) == 3, "wheel ramp: three clicks (0.017, 8.9, 31.4) are three notches")
check(ramp([0.0173, 9.1, 35.4, 50.9, 55.6]) == 5, "wheel ramp: five clicks (five readings up to 55) are five notches")
let tenClicks: [Double] = [0.0173, 7.9, 31.7, 49.3, 59.5, 65.4, 69.3, 70.1, 80.0]
check(abs(ramp(tenClicks)) >= 8 && abs(ramp(tenClicks)) <= 11, "wheel ramp: ten clicks (nine readings, sum 433) are about ten notches (got \(ramp(tenClicks)))")
let twentyClicks: [Double] = [0.0173, 5.5, 21.4, 37.1, 51.4, 59.5, 65.5, 71.2, 82.3, 85.3, 85.9, 86.3, 86.5, 86.2]
check(abs(ramp(twentyClicks)) >= 14 && abs(ramp(twentyClicks)) <= 22, "wheel ramp: twenty clicks (14 readings, sum 824) are 14 to 22 notches (got \(ramp(twentyClicks)))")
let burstOne: [Double] = [0.0173, 9.0, 93.0, 63.9, 70.9, 77.2, 174.8]
let burstTwo: [Double] = [0.0173, 8.9, 37.1, 55.4, 63.6, 148.0, 83.0, 91.6, 92.2, 91.8, 89.8]
check(abs(ramp(burstOne)) >= 9 && abs(ramp(burstOne)) <= 13, "wheel ramp: the user's first fast turn of 10 to 15 clicks is 9 to 13 notches (got \(ramp(burstOne)))")
check(abs(ramp(burstTwo)) >= 13 && abs(ramp(burstTwo)) <= 19, "wheel ramp: the user's second fast turn of 10 to 15 clicks is 13 to 19 notches (got \(ramp(burstTwo)))")
check(ramp([-0.0173, -8.9, -31.4, -50.9, -55.6]) == -5, "wheel ramp: the other direction is negative")
// the ramp is counted as it grows, not at its end
var growing = WheelGesture()
var sentSoFar = 0
for (i, v) in burstTwo.enumerated() { sentSoFar += growing.add(v, at: 710.0 + Double(i) * 0.016); if i == 5 { check(sentSoFar >= 5, "wheel ramp: half way through a turn its first clicks are already sent (\(sentSoFar))") } }
// two turns a second apart are two ramps, a flick too
var twoTurns = WheelGesture()
let t1 = click(&twoTurns, [0.0173, 8.9, 31.4], from: 720.0, step: 0.016), t2 = click(&twoTurns, [0.0173, 9.1, 35.4, 50.9, 55.6], from: 721.0, step: 0.016)
check(t1 == 3 && t2 == 5, "wheel ramp: a second turn starts from nothing (\(t1), \(t2))")
check(abs(ramp([185.2, 540.5, 582.6, 290.5])) >= 30, "wheel ramp: a hard flick (185, 540, 582, 290) adds up to many notches")
check(abs(ramp((0..<400).map { _ in 86.0 })) <= WheelGesture.maxClicks, "wheel ramp: the count is capped")

var nan = WheelGesture()
check(nan.add(.nan, at: 130) == 0 && nan.add(.infinity, at: 130.01) == 0, "wheel gesture: not-a-number readings are ignored")
let w = GCMouseWheel.axes(-1, 0)
check(w.dy == 1 && w.dx == 0, "wheel: a turn away from the user is up")
check(wheel.add(0, 1000).count == WheelAccumulator.maxNotchesPerEvent, "wheel: a huge burst is capped")

// --- Where the mouse's motion goes
check(PointerPolicy.route(focused: false, hover: true, locked: false, cursorShown: true, absoluteAllowed: true) == .blocked, "route: nothing without focus")
check(PointerPolicy.route(focused: true, hover: true, locked: false, cursorShown: true, absoluteAllowed: true) == .absolute, "route: a shown cursor follows the pointer's position")
check(PointerPolicy.route(focused: true, hover: true, locked: false, cursorShown: false, absoluteAllowed: true) == .relative, "route: a hidden cursor (mouse look) gets relative motion")
check(PointerPolicy.route(focused: true, hover: true, locked: true, cursorShown: true, absoluteAllowed: true) == .relative, "route: a locked pointer has no position")
check(PointerPolicy.route(focused: true, hover: false, locked: false, cursorShown: true, absoluteAllowed: true) == .relative, "route: no hover reports (AssistiveTouch) means relative")
check(PointerPolicy.cursorShown(desktop: false, directEnabled: true, reports: 5, shown: false, relative: false) == false, "cursor: the game hid it")
check(PointerPolicy.cursorShown(desktop: false, directEnabled: true, reports: 5, shown: true, relative: true) == false, "cursor: mouse look mode always hides it")
check(PointerPolicy.cursorShown(desktop: true, directEnabled: true, reports: 0, shown: false) == true, "cursor: a desktop session shows it until it says otherwise")

// --- The pointer lock follows the game's cursor
func lock(locked: Bool = false, byUs: Bool = false, shown: Bool = false, hiddenFor: Double = 1, over: Bool = true, focused: Bool = true, report: Double = 0.1, motion: Double = 0.1) -> AutoLock.Action {
    AutoLock.decide(locked: locked, lockedByUs: byUs, cursorShown: shown, hiddenFor: hiddenFor, pointerOver: over, focused: focused, sinceReport: report, sinceMotion: motion)
}
check(lock() == .lock, "lock: the game hides its cursor, the pointer is over it and moving")
check(lock(hiddenFor: 0.2) == .none, "lock: not before half a second of a hidden cursor")
check(lock(shown: true) == .none, "lock: not while the cursor is shown")
check(lock(over: false) == .none && lock(focused: false) == .none, "lock: not while the pointer is elsewhere or focus is lost")
check(lock(locked: true, byUs: true, shown: true) == .unlock, "lock: released when the game shows its cursor")
check(lock(locked: true, byUs: true, focused: false) == .unlock, "lock: released when focus is lost")
check(lock(locked: true, byUs: false, shown: true) == .none, "lock: a lock the person asked for stays")
check(lock(locked: true, byUs: true, report: 5, motion: 0.1) == .unlock, "lock: released when the game stopped reporting (it ended)")

// --- Touches that are really clicks
check(SynthesizedTouch.looksSynthesized(direct: true, majorRadius: 0, secondsSinceButton: 5), "a touch with no contact patch is AssistiveTouch's click")
check(SynthesizedTouch.looksSynthesized(direct: true, majorRadius: 20, secondsSinceButton: 0.01), "a touch right after a button report is the click's")
check(!SynthesizedTouch.looksSynthesized(direct: true, majorRadius: 20, secondsSinceButton: 5), "a real fingertip is a finger")
check(!SynthesizedTouch.looksSynthesized(direct: false, majorRadius: 0, secondsSinceButton: 0), "an indirect pointer is not classified here")
check(SurfacePointerEvent.map(x: 5, y: 6, flags: 0x8001, data: 0, hardwareRelative: true) == nil, "a touch's position does not warp a camera the mouse owns")
check(SurfacePointerEvent.map(x: 5, y: 6, flags: 0x8002, data: 0, hardwareRelative: true) == SurfacePointerEvent(x: 0, y: 0, flags: 0x2, data: 0), "...but its click goes through, without a position")
check(SurfacePointerEvent.map(x: 5, y: 6, flags: 0x8001, data: 0, hardwareRelative: false)?.x == 5, "without a raw mouse the touch is unchanged")


// --- Keys chosen for Porthole
check(KeyBind.parse("f10") == KeyBind(vk: 0x79) && KeyBind.parse("F10")?.string == "f10", "keybind: F10 parses and prints back")
check(KeyBind.parse("ctrl+alt+p") == KeyBind(vk: 0x50, ctrl: true, alt: true), "keybind: Ctrl+Alt+P")
check(KeyBind.parse("alt+ctrl+p")?.string == "ctrl+alt+p", "keybind: modifiers print in one order")
check(KeyBind.parse("") == nil && KeyBind.parse("ctrl") == nil && KeyBind.parse("ctrl+q+w") == nil && KeyBind.parse("banana") == nil, "keybind: not a key, not a bind")
check(KeyBind.parse("backtick")?.vk == 0xC0 && KeyBind.parse("pageup")?.vk == 0x21 && KeyBind.parse("1")?.vk == 0x31, "keybind: names of punctuation, paging keys and digits")
check(KeyBind.defaultMenu.label == "F10" && KeyBind.defaultLock.label == "Ctrl+Alt+P" && KeyBind.parse("shift+backtick")?.label == "Shift+`", "keybind: labels")
check(KeyBind.defaultMenu.matches(vk: 0x79, held: []) && !KeyBind.defaultMenu.matches(vk: 0x78, held: []), "keybind: F10 matches F10 only")
check(KeyBind.defaultLock.matches(vk: 0x50, held: [0xA3, 0xA4]) && !KeyBind.defaultLock.matches(vk: 0x50, held: [0xA2]), "keybind: needs every modifier it names")
check(KeyBind.isModifier(0xA0) && KeyBind.isModifier(0x5B) && !KeyBind.isModifier(0x41), "keybind: modifiers cannot be the key")
for (name, code) in KeyBind.names { if KeyBind.parse(name)?.vk != code { check(false, "keybind: \(name) round trips") } }
check(Set(KeyBind.names.map(\.name)).count == KeyBind.names.count, "keybind: no name twice")

// --- Pasting
func pk(_ c: Character) -> String { PasteText.key(for: c).map { "\($0.0),\($0.1)" } ?? "nil" }
check(pk("a") == "65,false" && pk("A") == "65,true" && pk("!") == "49,true", "paste: letters and shifted symbols")
check(PasteText.isCommandV(0x56, held: [0x5B]) && !PasteText.isCommandV(0x56, held: [0xA2]), "Command-V pastes, Ctrl-V is the game's")
var q = PasteQueue()
q.append("hi")
check(q.next?.vk == 0x48 && q.next?.shift == false, "paste: starts with the first character")
q.advance(); q.advance()
check(q.next == nil, "paste: ends after the last character")

// --- A gesture that never got a reading (the pointer is not on a game) must be safe to summarise: 1.3.16-1.3.20 trapped on Int(-infinity) at every scroll outside a game
var idle = WheelGesture()
let idleSummary = idle.summary
check(idleSummary.readings == 0 && idleSummary.ms == 0 && idleSummary.notches == 0, "a wheel gesture with no reading summarises as empty (no trap)")
check(idle.flushIdle(at: 0) == 0 && idle.summary.ms == 0, "flushing a gesture with no reading is empty")

// --- The system's scroll sense is learned from turns seen by both UIKit and the pad
var sense = ScrollSense()
check(sense.same == 1, "scroll sense starts as iPadOS's default (UIKit and the pad agree in sign)")
check(!sense.observe(uikit: -12, pad: -40) && sense.same == 1, "a turn that agrees keeps the sense")
check(!sense.observe(uikit: 12, pad: -40) && !sense.observe(uikit: 12, pad: -40) && sense.same == 1, "two turns against the sense are not enough")
check(sense.observe(uikit: 12, pad: -40) && sense.same == -1, "three in a row flip it")
check(!sense.observe(uikit: 0, pad: 5) && !sense.observe(uikit: 3, pad: 0) && !sense.observe(uikit: .infinity, pad: 1), "zero and non-finite readings are ignored")
var sense2 = ScrollSense()
_ = sense2.observe(uikit: 1, pad: -1); _ = sense2.observe(uikit: 1, pad: -1); _ = sense2.observe(uikit: 1, pad: 1)
check(sense2.same == 1 && !sense2.observe(uikit: 1, pad: -1), "an agreeing turn in between starts the count again")

// --- Cursor and stick helpers
let c = DesktopCursor.advance(x: 10, y: 10, dx: -50, dy: 5000, width: 1280, height: 720)
check(c.x == 0 && c.y == 719, "the desktop cursor stays inside the screen")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
