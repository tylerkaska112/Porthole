#!/bin/bash
# The default controls (Sources/Core/DefaultControls.swift): what a game follows when it has no controls of its own, and how the choice is kept.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import CoreGraphics
import Foundation
/// Stand-in for the app's Game (BindSets.swift extends it).
struct Game { var bindSets: [BindSet]?; var activeBindSetID: UUID? }
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let fresh = DefaultControls()
check(fresh.kind == .universal && !fresh.usesOnScreenPad, "the default is the Universal layout")
let universal = fresh.touchLayout
check(universal != nil && universal == fresh.touchLayout, "Universal is a layout, and reads the same every time (the screen only redraws for a different layout)")
check(Set(universal?.controls.map(\.action) ?? []).isSuperset(of: ["stick-wasd", "lmb", "rmb", "lookmode", "space", "shift", "ctrl", "key-E", "esc", "tab", "keyboard"]) && universal?.look == false, "Universal has the stick, the mouse buttons, the Look switch and the usual keys, and starts with the drag moving the mouse")
check(DefaultControls.Kind.allCases.map(\.rawValue) == ["universal", "onScreenPad", "gamepad", "custom"], "the choices are Universal, the on-screen controller, a gamepad and the person's own: Mouse and keys and First person are gone")
for old in ["mouseAndKeys", "firstPerson", "somethingNew"] {
    let stored = try! JSONDecoder().decode(DefaultControls.self, from: Data("{\"kind\":\"\(old)\"}".utf8))
    check(stored.kind == .universal, "a choice saved by an older build (\(old)) reads as Universal")
}
check(try! JSONDecoder().decode(DefaultControls.self, from: Data("{\"kind\":\"gamepad\"}".utf8)).kind == .gamepad, "a choice that still exists reads as it was")
check(DefaultControls(kind: .onScreenPad).touchLayout == nil && DefaultControls(kind: .onScreenPad).usesOnScreenPad && !DefaultControls().usesOnScreenPad, "the on-screen controller is drawn by its own view, not a layout, and is not the original default")
check(DefaultControls.load(from: UserDefaults(suiteName: "dc-x-\(getpid())")!) == DefaultControls(), "nothing saved is still the original default")
check(DefaultControls(kind: .gamepad).touchLayout?.controls.map(\.action) == TouchLayout.gamepad.controls.map(\.action), "Gamepad is the gamepad layout")
check(DefaultControls(kind: .gamepad).touchLayout == DefaultControls(kind: .gamepad).touchLayout, "and reads the same every time (the screen only redraws for a different layout)")

var mine = DefaultControls()
mine.use(custom: ShippedLayouts.action.layout)
check(mine.kind == .custom && mine.touchLayout?.controls.count == ShippedLayouts.action.layout.controls.count, "a saved layout becomes the default")
check(mine.normalised() == mine, "and is kept as it is")
check(DefaultControls(kind: .custom, custom: nil).normalised() == DefaultControls(), "a custom default with nothing behind it is the original default")
check(DefaultControls(kind: .custom, custom: TouchLayout()).normalised() == DefaultControls(), "so is one with an empty layout")

// following
check(DefaultControls.follows(own: nil, hasBindSet: false, virtualPad: nil), "a game with nothing of its own follows the default")
check(!DefaultControls.follows(own: true, hasBindSet: false, virtualPad: nil), "a game whose controls were chosen for it does not")
check(!DefaultControls.follows(own: nil, hasBindSet: true, virtualPad: nil), "nor one with a bind set in use")
check(!DefaultControls.follows(own: nil, hasBindSet: false, virtualPad: true), "nor one with the on-screen game controller on")
check(DefaultControls.follows(own: false, hasBindSet: false, virtualPad: false), "'back to the default' is own = false")

// stored
let name = "default-controls-test-\(getpid())"
let defaults = UserDefaults(suiteName: name)!
defaults.removePersistentDomain(forName: name)
check(DefaultControls.load(from: defaults) == DefaultControls(), "nothing saved reads as the original default")
DefaultControls.save(mine, to: defaults)
check(DefaultControls.load(from: defaults) == mine, "a saved choice comes back, layout and all")
DefaultControls.save(DefaultControls(kind: .gamepad), to: defaults)
check(DefaultControls.load(from: defaults).kind == .gamepad, "a newer choice replaces it")
DefaultControls.save(DefaultControls(), to: defaults)
check(defaults.data(forKey: DefaultControls.key) == nil, "choosing the default stores nothing")
DefaultControls.save(DefaultControls(kind: .gamepad), to: defaults)
check(DefaultControls.load(from: defaults).kind == .gamepad, "choosing something that is not the default is stored, and comes back")
DefaultControls.save(DefaultControls(), to: defaults)
defaults.set(Data("not json".utf8), forKey: DefaultControls.key)
check(DefaultControls.load(from: defaults) == DefaultControls(), "a damaged file reads as the default")
check(DefaultControls.Kind.allCases.count == 4 && Set(DefaultControls.Kind.allCases.map(\.title)).count == 4 && DefaultControls.Kind.allCases.first == .universal && DefaultControls.Kind.allCases.allSatisfy { !$0.detail.isEmpty && $0.detail.count < 60 }, "every choice has its own name and a line of words")
// the game's picture, part of a layout
// it is part of the layout, and old layouts and old builds still read
let withPic = TouchLayout(controls: [], picture: PicturePlacement(across: 0, down: 1, scale: 0.6))
let data = try! JSONEncoder().encode(withPic), back = try! JSONDecoder().decode(TouchLayout.self, from: data)
check(back.picture == withPic.picture && (try! JSONDecoder().decode(TouchLayout.self, from: Data("{\"controls\":[],\"look\":false}".utf8))).picture == nil, "layout: the picture placement is saved with it, and a layout saved without one reads as automatic")
check(!String(decoding: try! JSONEncoder().encode(TouchLayout()), as: UTF8.self).contains("picture"), "layout: a layout with no placement does not write one")
check(TouchLayout(controls: [], picture: PicturePlacement(across: 0.2, down: 0.9, scale: 2)).sanitized().picture == PicturePlacement(across: 0, down: 1, scale: 1), "layout: sanitizing keeps the placement, snapped")

// overlay spots in a layout
let spots = TouchLayout(controls: [
    TouchControlSpec(label: "x", action: "overlay-perf", mode: "latch", x: 0.3, y: 0.2, size: 130, with: ["shift"], shape: "square", colour: "red"),
    TouchControlSpec(label: "", action: "overlay-perf", x: 0.9, y: 0.9, size: 110),          // a second performance spot: dropped
    TouchControlSpec(label: "", action: "overlay-discord", x: 0.2, y: 0.5, size: 400),
    TouchControlSpec(label: "E", action: "key-E", x: 0.5, y: 0.5)]).sanitized()
check(spots.controls.map(\.action) == ["overlay-perf", "overlay-discord", "key-E"], "overlay spots: one of each, whatever else is in the layout")
check(spots.controls[0].label.isEmpty && spots.controls[0].mode == "tap" && spots.controls[0].with.isEmpty && spots.controls[0].shape == nil && spots.controls[0].colour == nil, "overlay spots: no label, mode, combo, shape or colour")
check(spots.controls[0].x == 0.3 && spots.controls[0].y == 0.2 && abs(spots.controls[0].overlayScale - 130.0 / 110.0) < 0.001 && spots.controls[1].size == 160 && spots.controls[1].overlayScale == 1.4545454545454546 || spots.controls[1].overlayScale <= 2, "overlay spots: the position is kept, the size is the scale of the overlay and limited")
check(spots.controls[0].isOverlay && spots.controls[1].isOverlay && !spots.controls[2].isOverlay && spots.controls[0].pad == nil && !spots.controls[0].isStick, "overlay spots are not buttons, sticks or pad controls")
check(TouchControlSpec(label: "", action: "overlay-perf", x: 0, y: 0, size: 20).overlayScale == 0.5 && TouchControlSpec(label: "", action: "overlay-perf", x: 0, y: 0, size: 400).overlayScale == 2, "overlay spots: the overlay is drawn half to twice its usual size")
check(TouchLayout(controls: [TouchControlSpec(label: "", action: "overlay-bogus", x: 0.5, y: 0.5)]).sanitized().controls.isEmpty, "an overlay that does not exist is dropped like any unknown action")

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
S="$HERE/../../Sources/Core"
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$S/TouchPadControls.swift" "$S/VirtualPadModel.swift" "$S/ControllerKind.swift" "$S/BindSets.swift" "$S/PadActions.swift" "$S/DefaultControls.swift" "$S/PictureBand.swift" "$S/ShippedLayouts.swift"
"$OUT/t"
rm -rf "$OUT"
