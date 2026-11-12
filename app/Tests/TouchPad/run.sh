#!/bin/bash
# Mixed layouts (Sources/Core/TouchPadControls.swift): the pad controls of a custom layout and how several sources make one pad state.
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

// the controls
check(TouchPadControl.entries.count == 19 && Set(TouchPadControl.entries.map(\.id)).count == 19, "19 pad controls, every id once")
check(TouchPadControl(action: "pad-a") == .button(.a) && TouchPadControl(action: "pad-rt") == .trigger(left: false) && TouchPadControl(action: "stick-ls") == .stick(left: true) && TouchPadControl(action: "dpad-pad") == .dpad, "ids name their controls")
check(TouchPadControl(action: "key-E") == nil && TouchPadControl(action: "stick-wasd") == nil && TouchPadControl(action: "lmb") == nil && TouchPadControl(action: "") == nil, "keys, mouse buttons and the W A S D stick are not pad controls")
check(TouchPadControl.entries.allSatisfy { $0.id.hasPrefix("pad-") || $0.id.hasPrefix("stick-") || $0.id.hasPrefix("dpad-") }, "ids follow the naming")
check(TouchPadControl.stick(left: true).isRound && TouchPadControl.dpad.isRound && TouchPadControl.button(.a).isButtonLike && TouchPadControl.trigger(left: true).isButtonLike, "sticks and the D-pad are round, buttons and triggers are not")

// what a press adds
check(TouchPadControl.button(.a).sample(pressed: true).buttons == VirtualPadButton.a.rawValue, "A sets the A bit")
check(TouchPadControl.button(.a).sample(pressed: false).isNeutral, "not pressed adds nothing")
check(TouchPadControl.trigger(left: true).sample(pressed: true).leftTrigger == 255 && TouchPadControl.trigger(left: true).sample(pressed: true).rightTrigger == 0, "LT is the left trigger fully")
check(TouchPadControl.trigger(left: false).sample(pressed: true).rightTrigger == 255, "RT the right")
check(TouchPadControl.button(.up).sample(pressed: true).buttons == 0x0001 && TouchPadControl.button(.rightStick).sample(pressed: true).buttons == 0x0080, "D-pad and stick clicks use XInput's masks")

// sticks and the D-pad from a thumb
let rest = TouchPadControl.stickSample(left: true, offset: CGVector(dx: 2, dy: 2), radius: 60)
check(rest.isNeutral, "a thumb near the centre is inside the dead zone")
let right = TouchPadControl.stickSample(left: true, offset: CGVector(dx: 60, dy: 0), radius: 60)
check(right.lx > 30000 && right.ly == 0 && right.rx == 0, "pushed right: the left stick's X is near full")
let up = TouchPadControl.stickSample(left: false, offset: CGVector(dx: 0, dy: -60), radius: 60)
check(up.ry > 30000 && up.rx == 0 && up.ly == 0, "pushed up (screen y down): the right stick's Y is positive")
check(TouchPadControl.dpadSample(offset: CGVector(dx: 0, dy: -40), radius: 60).buttons == VirtualPadButton.up.rawValue, "D-pad up")
check(TouchPadControl.dpadSample(offset: CGVector(dx: 40, dy: 40), radius: 60).buttons == (VirtualPadButton.right.rawValue | VirtualPadButton.down.rawValue), "a diagonal is two directions")
check(TouchPadControl.dpadSample(offset: CGVector(dx: 3, dy: 3), radius: 60).isNeutral, "the middle of the D-pad is dead")

// the mixer
var m = TouchPadMixer()
check(m.merged.isNeutral, "no source: a neutral pad")
m.set(TouchPadControl.button(.a).sample(pressed: true), for: "x")
m.set(TouchPadControl.button(.b).sample(pressed: true), for: "y")
check(m.merged.buttons == (VirtualPadButton.a.rawValue | VirtualPadButton.b.rawValue), "two sources' buttons are together")
m.set(VirtualPadSample(), for: "x")
check(m.merged.buttons == VirtualPadButton.b.rawValue, "a neutral report removes the source")
var m2 = TouchPadMixer()
m2.set(TouchPadControl.stickSample(left: true, offset: CGVector(dx: 30, dy: 0), radius: 60), for: "a")
m2.set(TouchPadControl.stickSample(left: true, offset: CGVector(dx: 60, dy: 0), radius: 60), for: "b")
check(m2.merged.lx == TouchPadControl.stickSample(left: true, offset: CGVector(dx: 60, dy: 0), radius: 60).lx, "two thumbs on one stick: the stronger wins")
m2.set(TouchPadControl.trigger(left: true).sample(pressed: true), for: "c")
check(m2.merged.leftTrigger == 255 && m2.merged.lx > 0, "a trigger and a stick from different sources both reach the pad")
var order1 = TouchPadMixer(), order2 = TouchPadMixer()
let s1 = TouchPadControl.stickSample(left: true, offset: CGVector(dx: 40, dy: 0), radius: 60), s2 = TouchPadControl.stickSample(left: true, offset: CGVector(dx: 0, dy: 40), radius: 60)
order1.set(s1, for: "a"); order1.set(s2, for: "b"); order2.set(s2, for: "b"); order2.set(s1, for: "a")
check(order1.merged == order2.merged, "the result does not depend on which source reported first")
m2.clear()
check(m2.merged.isNeutral, "clear empties it")
// the layout model
let gp = TouchLayout.gamepad
check(gp.controls.count == 13 && gp.controls.allSatisfy { $0.pad != nil }, "the Gamepad preset is 13 pad controls")
check(gp.sanitized() == gp, "and a layout the editor makes needs no repair")
check(gp.controls.contains { $0.action == "stick-ls" && $0.isRound } && gp.controls.contains { $0.action == "dpad-pad" && $0.isRound } && gp.controls.filter { $0.isRound }.count == 3, "its sticks and D-pad are the round controls")
check(gp.controls.first { $0.action == "pad-a" }?.label == "A" && gp.controls.first { $0.action == "pad-start" }?.label == "Menu", "buttons carry their faces")
var mixed = TouchLayout.mouseAndKeys
mixed.controls.append(TouchControlSpec(label: "A", action: "pad-a", x: 0.5, y: 0.5, size: 54))
mixed.controls.append(TouchControlSpec(label: "", action: "stick-rs", x: 0.7, y: 0.7, size: 110))
check(mixed.sanitized().controls.count == TouchLayout.mouseAndKeys.controls.count + 2, "keys and pad controls live in one layout")
var bad = TouchLayout(controls: [TouchControlSpec(label: "x", action: "pad-zz", x: 0.5, y: 0.5), TouchControlSpec(label: "x", action: "stick-xx", x: 0.5, y: 0.5)])
check(bad.sanitized().controls.isEmpty, "an unknown pad id is dropped, as any unknown action is")
check(TouchControlSpec(label: "", action: "stick-wasd", x: 0.1, y: 0.1).isRound && !TouchControlSpec(label: "E", action: "key-E", x: 0.1, y: 0.1).isRound && TouchControlSpec(label: "E", action: "key-E", x: 0.1, y: 0.1).pad == nil, "keys are not pad controls, the W A S D stick is round")
check(TouchControlSpec(label: "", action: "stick-ls", x: 0.1, y: 0.1).faceText == "LS" && TouchControlSpec(label: "", action: "dpad-pad", x: 0.1, y: 0.1).faceText == "+" && TouchControlSpec(label: "", action: "stick-wasd", x: 0.1, y: 0.1).faceText == "WASD", "small pictures of a layout say what a round control is")
// layout options: opacity, haptics, combos
var opt = TouchLayout.mouseAndKeys
check(opt.opacity == 1 && opt.haptics, "a layout starts solid with haptics on")
opt.opacity = 0.1
check(opt.sanitized().opacity == TouchLayout.opacityRange.lowerBound, "opacity is kept above a quarter, so the controls are never invisible")
opt.opacity = .nan
check(opt.sanitized().opacity == 1, "a nonsense opacity becomes solid")
var combo = TouchControlSpec(label: "Jump", action: "space", x: 0.5, y: 0.5, with: ["shift", "ctrl", "ctrl", "bogus", "space"])
check(TouchLayout(controls: [combo]).sanitized().controls[0].with == ["shift", "ctrl"], "a combo keeps Shift/Ctrl/Alt once each and nothing else")
combo.action = "shift"; combo.with = ["shift", "alt"]
check(TouchLayout(controls: [combo]).sanitized().controls[0].with == ["alt"], "a key is not a combo with itself")
let lmb = TouchControlSpec(label: "F", action: "lmb", x: 0.5, y: 0.5, with: ["shift"])
check(TouchLayout(controls: [lmb]).sanitized().controls[0].with.isEmpty, "a mouse button takes no combo")
let stick = TouchControlSpec(label: "", action: "stick-wasd", x: 0.5, y: 0.5, with: ["shift"])
check(TouchLayout(controls: [stick]).sanitized().controls[0].with.isEmpty, "nor does a stick")
let optLayout = TouchLayout(controls: [TouchControlSpec(label: "C", action: "key-C", x: 0.5, y: 0.5, with: ["ctrl"])], opacity: 0.6, haptics: false)
check((try? JSONDecoder().decode(TouchLayout.self, from: JSONEncoder().encode(optLayout))) == optLayout, "opacity, haptics and a combo survive being saved and read")
check((try? JSONDecoder().decode(TouchLayout.self, from: Data(#"{"controls":[]}"#.utf8))) == TouchLayout(), "a layout saved before these options reads as solid, haptics on")
// lock, shape and colour
var shaped = TouchControlSpec(label: "E", action: "key-E", x: 0.5, y: 0.5, shape: "rounded", colour: "red")
check(TouchLayout(controls: [shaped]).sanitized().controls[0].shape == "rounded" && TouchLayout(controls: [shaped]).sanitized().controls[0].colour == "red", "a key keeps its shape and colour")
shaped.shape = "hexagon"; shaped.colour = "pink"
check(TouchLayout(controls: [shaped]).sanitized().controls[0].shape == nil && TouchLayout(controls: [shaped]).sanitized().controls[0].colour == nil, "an unknown shape or colour is dropped")
let roundStick = TouchControlSpec(label: "", action: "stick-wasd", x: 0.5, y: 0.5, shape: "square", colour: "red")
check(TouchLayout(controls: [roundStick]).sanitized().controls[0].shape == nil && TouchLayout(controls: [roundStick]).sanitized().controls[0].colour == nil, "a stick has no shape or colour of its own")
let padBtn = TouchControlSpec(label: "A", action: "pad-a", x: 0.5, y: 0.5, shape: "square", colour: "red")
check(TouchLayout(controls: [padBtn]).sanitized().controls[0].colour == nil, "nor does a gamepad button")
let lockedLayout = TouchLayout(controls: [TouchControlSpec(label: "E", action: "key-E", x: 0.5, y: 0.5, shape: "square", colour: "blue")], opacity: 0.8, haptics: false, locked: true)
check((try? JSONDecoder().decode(TouchLayout.self, from: JSONEncoder().encode(lockedLayout))) == lockedLayout, "lock, shape and colour survive being saved and read")
let plainKey = TouchControlSpec(label: "E", action: "key-E", x: 0.5, y: 0.5)
let plainJSON = String(data: try JSONEncoder().encode(TouchLayout(controls: [plainKey])), encoding: .utf8) ?? ""
check(!plainJSON.contains("shape") && !plainJSON.contains("colour") && !plainJSON.contains("locked") && !plainJSON.contains("opacity"), "a layout that uses none of the options saves exactly as before (\(plainJSON.count) characters)")
let json = try JSONEncoder().encode(gp)
check((try? JSONDecoder().decode(TouchLayout.self, from: json)) == gp, "a layout with pad controls survives being saved and read")
let old = Data(#"{"controls":[{"label":"E","action":"key-E","mode":"tap","x":0.5,"y":0.5,"size":54}],"look":true}"#.utf8)
check((try? JSONDecoder().decode(TouchLayout.self, from: old))?.controls.first?.action == "key-E", "a layout saved before pad controls still reads")
check(PadActions.label("pad-a") == "Controller A" && PadActions.shortLabel("pad-lb") == "LB" && PadActions.shortLabel("key-E") == "E" && PadActions.label("lmb") == "Left mouse button", "names for pad controls, keys as before")
check(PadActions.groups.contains { $0.title == "Controller" && $0.ids.contains("pad-a") && !$0.ids.contains("stick-ls") }, "the editor's Controller group lists buttons and triggers (sticks come with the stick picker)")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/TouchPadControls.swift" "$HERE/../../Sources/Core/VirtualPadModel.swift" "$HERE/../../Sources/Core/ControllerKind.swift" "$HERE/../../Sources/Core/BindSets.swift" "$HERE/../../Sources/Core/PadActions.swift"
"$OUT/t"
rm -rf "$OUT"
