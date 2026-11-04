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

// --- Cursor and stick helpers
let c = DesktopCursor.advance(x: 10, y: 10, dx: -50, dy: 5000, width: 1280, height: 720)
check(c.x == 0 && c.y == 719, "the desktop cursor stays inside the screen")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
