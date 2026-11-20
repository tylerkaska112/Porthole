#!/bin/bash
# The maths behind multi-select in the controls editor (Sources/Core/ControlArrange.swift): align, space evenly, flip, move and scale a group, size alike, copies, clipboard.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import CoreGraphics
import Foundation
struct Game { var bindSets: [BindSet]?; var activeBindSetID: UUID? }
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Double, _ b: Double, _ e: Double = 0.0005) -> Bool { abs(a - b) < e }
func key(_ n: String, _ x: Double, _ y: Double, _ size: Double = 60) -> TouchControlSpec { TouchControlSpec(label: n, action: "key-\(n)", x: x, y: y, size: size) }

let field = CGSize(width: 1000, height: 500)
let a = key("A", 0.20, 0.30, 60), b = key("B", 0.40, 0.60, 100), c = key("C", 0.90, 0.40, 80), d = key("D", 0.5, 0.5, 60)
let all = [a, b, c, d]
let three: Set<UUID> = [a.id, b.id, c.id]

// align
var r = ControlArrange.align(all, ids: three, edge: .left, in: field)
let left = ControlArrange.bounds(all, ids: three, in: field)!.minX
check(r.prefix(3).allSatisfy { abs(ControlArrange.frame($0, in: field).minX - left) < 0.5 } && r[3] == d, "align left: the chosen controls share the leftmost edge, the others stay")
r = ControlArrange.align(all, ids: three, edge: .right, in: field)
let right = ControlArrange.bounds(all, ids: three, in: field)!.maxX
check(r.prefix(3).allSatisfy { abs(ControlArrange.frame($0, in: field).maxX - right) < 0.5 }, "align right: the rightmost edge")
r = ControlArrange.align(all, ids: three, edge: .centreX, in: field)
check(r.prefix(3).allSatisfy { near($0.x, r[0].x) } && near(r[0].x, ControlArrange.bounds(all, ids: three, in: field)!.midX / 1000), "align centres: one vertical line through the middle of the group")
r = ControlArrange.align(all, ids: three, edge: .top, in: field)
let top = ControlArrange.bounds(all, ids: three, in: field)!.minY
check(r.prefix(3).allSatisfy { abs(ControlArrange.frame($0, in: field).minY - top) < 0.5 }, "align top")
r = ControlArrange.align(all, ids: three, edge: .bottom, in: field)
let bottom = ControlArrange.bounds(all, ids: three, in: field)!.maxY
check(r.prefix(3).allSatisfy { abs(ControlArrange.frame($0, in: field).maxY - bottom) < 0.5 }, "align bottom")
r = ControlArrange.align(all, ids: three, edge: .centreY, in: field)
check(r.prefix(3).allSatisfy { near($0.y, r[0].y) }, "align middles")
check(ControlArrange.align(all, ids: [a.id], edge: .left, in: field) == all, "one control cannot be aligned with itself")
check(ControlArrange.align(all, ids: three, edge: .left, in: field).map(\.id) == all.map(\.id), "order and ids are kept")

// distribute
r = ControlArrange.distribute(all, ids: three, axis: .across, in: field)
let fa = r.prefix(3).map { ControlArrange.frame($0, in: field) }.sorted { $0.minX < $1.minX }
check(abs((fa[1].minX - fa[0].maxX) - (fa[2].minX - fa[1].maxX)) < 0.5, "spread across: the gaps between neighbours are equal")
check(near(r[0].x, a.x) && near(r[2].x, c.x), "spread across: the first and the last stay")
r = ControlArrange.distribute(all, ids: three, axis: .down, in: field)
let fd = r.prefix(3).map { ControlArrange.frame($0, in: field) }.sorted { $0.minY < $1.minY }
check(abs((fd[1].minY - fd[0].maxY) - (fd[2].minY - fd[1].maxY)) < 0.5, "spread down: equal gaps")
check(ControlArrange.distribute(all, ids: [a.id, b.id], axis: .across, in: field) == all, "two controls are not spread")

// mirror
r = ControlArrange.mirror(all, ids: Set(all.map(\.id)), wholeScreen: true, in: field)
check(near(r[0].x, 0.80) && near(r[2].x, 0.10) && near(r[3].x, 0.5) && r.map(\.y) == all.map(\.y), "mirror the screen: x becomes 1 - x, y stays")
check(ControlArrange.mirror(r, ids: Set(all.map(\.id)), wholeScreen: true, in: field).map(\.x).enumerated().allSatisfy { near($0.element, all[$0.offset].x) }, "and mirroring twice is where it began")
r = ControlArrange.mirror(all, ids: [a.id, c.id], wholeScreen: false, in: field)
check(near(r[0].x, 0.90) && near(r[2].x, 0.20) && near(r[1].x, b.x), "mirror a cluster: about its own middle, the others stay")

// move
r = ControlArrange.moved(all, ids: three, dx: 0.05, dy: -0.1)
check(near(r[0].x, 0.25) && near(r[1].y, 0.50) && r[3] == d, "move: every chosen control moves by the same amount")
r = ControlArrange.moved(all, ids: three, dx: 0.5, dy: 0)
check(near(r[2].x, 0.98) && near(r[0].x - a.x, r[2].x - c.x) && near(r[1].x - b.x, r[0].x - a.x), "move: stops when one control reaches the edge, the group keeps its shape")
r = ControlArrange.moved(all, ids: three, dx: 0, dy: -1)
check(near(r[0].y, 0.04) && near(r[1].y - 0.04, b.y - a.y) , "move up: the top of the screen stops the group")

// scale
r = ControlArrange.scaled(all, ids: three, by: 1.2, in: field)
check(r[0].size == 72 && r[1].size == 120 && r[2].size == 96 && r[3] == d, "scale: sizes grow together, the others stay")
check(near(r[0].x - r[2].x, (a.x - c.x) * 1.2), "scale: so does the space between controls")
check(near((r[0].x + r[2].x) / 2, (a.x + c.x) / 2), "scale: about the middle of the group")
check(ControlArrange.scaled(all, ids: three, by: 0.01, in: field).allSatisfy { $0.size >= TouchLayout.sizeRange.lowerBound }, "scale: never smaller than the smallest size")
check(ControlArrange.scaled(all, ids: three, by: 50, in: field).allSatisfy { $0.size <= TouchLayout.sizeRange.upperBound && $0.x <= 0.98 && $0.y <= 0.96 }, "scale: never bigger than the biggest size or off the screen")

// same size
r = ControlArrange.sized(all, ids: three, to: 70)
check(r.prefix(3).allSatisfy { $0.size == 70 } && r[3].size == 60 && ControlArrange.commonSize(Array(r.prefix(3))) == 70 && ControlArrange.commonSize(all) == nil, "size alike: all the chosen ones, and the common size is told when there is one")
check(ControlArrange.sized(all, ids: three, to: 5).allSatisfy { $0.size >= TouchLayout.sizeRange.lowerBound }, "size alike: kept inside the allowed sizes")

// copies
let cp = ControlArrange.copies(of: all, ids: three)
check(cp.count == 3 && Set(cp.map(\.id)).isDisjoint(with: Set(all.map(\.id))) && cp.map(\.action) == ["key-A", "key-B", "key-C"], "copies: new ids, same actions, same order")
check(near(cp[0].x - a.x, cp[1].x - b.x) && near(cp[0].y - a.y, cp[1].y - b.y), "copies: moved together")
check(cp.allSatisfy { $0.x <= 0.98 && $0.y <= 0.96 }, "copies: still on the screen")

// box select
check(Set(ControlArrange.inside(CGRect(x: 100, y: 100, width: 450, height: 300), specs: all, in: field)) == [a.id, b.id, d.id], "a box takes the controls whose centres are inside")
check(ControlArrange.inside(CGRect(x: 0, y: 0, width: 10, height: 10), specs: all, in: field).isEmpty, "an empty box takes none")

// overlay chips are wider than tall
let spot = TouchControlSpec(label: "", action: "overlay-perf", x: 0.5, y: 0.5, size: 160)
check(ControlArrange.extent(spot) == CGSize(width: 160, height: max(34, 160 * 0.42)) && ControlArrange.extent(a) == CGSize(width: 60, height: 60), "extents: a button is square, an overlay spot is a chip")

// clipboard
ControlClipboard.copy([a, b, spot])
check(ControlClipboard.count == 3, "clipboard holds what was copied")
let pasted = ControlClipboard.paste(into: [], room: 10)
check(pasted.count == 3 && Set(pasted.map(\.id)).isDisjoint(with: [a.id, b.id, spot.id]), "paste: fresh ids")
check(ControlClipboard.paste(into: [TouchControlSpec(label: "", action: "overlay-perf", x: 0.1, y: 0.1, size: 110)], room: 10).map(\.action) == ["key-A", "key-B"], "paste: an overlay spot the layout already has is left out")
check(ControlClipboard.paste(into: [], room: 2).count == 2 && ControlClipboard.paste(into: [], room: 0).isEmpty, "paste: no more than the room there is")

// The Universal layout leaves the right thumb room to drag in
let phone = CGSize(width: 844, height: 390), ipad = CGSize(width: 1376, height: 1032)
let universal = ShippedLayouts.universal.layout
let zone = TouchLayout.lookZone
func onScreen(_ spec: TouchControlSpec, _ sp: ControlSpace) -> CGRect {
    let c = sp.point(x: spec.x, y: spec.y), e = ControlArrange.extent(spec)
    return CGRect(x: c.x - e.width / 2, y: c.y - e.height / 2, width: e.width, height: e.height)
}
for (name, size) in [("phone", phone), ("iPad", ipad), ("small phone", CGSize(width: 660, height: 320))] {
    let sp = ControlSpace(field: size)
    let a = sp.point(x: zone.minX, y: zone.minY), b = sp.point(x: zone.maxX, y: zone.maxY)
    let zoneRect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    let inZone = universal.controls.filter { onScreen($0, sp).intersects(zoneRect) }.map(\.action)
    check(inZone.isEmpty, "Universal on a \(name): no control in the right thumb's look area (found: \(inZone))")
    check(universal.controls.allSatisfy { CGRect(origin: .zero, size: size).contains(onScreen($0, sp)) }, "Universal on a \(name): every control is on the screen")
}

// Screen size: a phone-sized layout keeps its spacing on a big screen
let spPhone = ControlSpace(field: CGSize(width: 750, height: 380)), spPad = ControlSpace(field: CGSize(width: 1180, height: 800))
check(spPhone.design == CGSize(width: 750, height: 380) && ControlSpace(field: CGSize(width: 640, height: 300)).design == CGSize(width: 640, height: 300), "the design area is the whole screen on a phone")
check(spPad.design.width < 1180 && spPad.design.height < 800 && spPad.design.width >= 750, "on an iPad the design area is a little bigger than a phone's, far smaller than the screen")
for sp in [spPhone, spPad, ControlSpace(field: CGSize(width: 808, height: 409))] {
    var ok = true, last = (x: -1.0, y: -1.0)
    for i in 0...200 {
        let f = Double(i) / 200
        let p = sp.point(x: f, y: f), back = sp.fractions(of: p)
        if abs(back.x - f) > 1e-9 || abs(back.y - f) > 1e-9 { ok = false }
        if p.x < last.x || p.y < last.y { ok = false }
        last = (p.x, p.y)
    }
    check(ok, "ControlSpace \(Int(sp.field.width))x\(Int(sp.field.height)): points and fractions are each other's inverse and never run backwards")
    let o = sp.point(x: 0, y: 0), e = sp.point(x: 1, y: 1)
    check(o == .zero && abs(e.x - sp.field.width) < 1e-9 && abs(e.y - sp.field.height) < 1e-9, "ControlSpace \(Int(sp.field.width)): the corners are the corners")
}
let ph = spPhone.point(x: 0.3, y: 0.7)
check(abs(ph.x - 0.3 * 750) < 1e-9 && abs(ph.y - 0.7 * 380) < 1e-9, "on a phone the mapping is plain fractions")
let stickPhone = universal.controls.first { $0.action == "stick-wasd" }!
let pPhone = spPhone.point(x: stickPhone.x, y: stickPhone.y), pPad = spPad.point(x: stickPhone.x, y: stickPhone.y)
check(pPad.x < pPhone.x * 1.4 && 800 - pPad.y < (380 - pPhone.y) * 1.4, "the stick sits about as far from its corner on an iPad as on a phone (\(Int(pPad.x)),\(Int(800 - pPad.y)) vs \(Int(pPhone.x)),\(Int(380 - pPhone.y)))")
let lmb = universal.controls.first { $0.action == "lmb" }!
check(1180 - spPad.point(x: lmb.x, y: lmb.y).x < (750 - spPhone.point(x: lmb.x, y: lmb.y).x) * 1.4, "the mouse buttons stay near the right edge on an iPad")
let shift = universal.controls.first { $0.action == "shift" || $0.label == "Shift" }!
let reachPhone = spPhone.point(x: shift.x, y: shift.y).y - pPhone.y, reachPad = spPad.point(x: shift.x, y: shift.y).y - pPad.y
check(abs(reachPad) < abs(reachPhone) * 1.5 + 1, "Shift is about as far above the stick on an iPad as on a phone (\(Int(-reachPad)) vs \(Int(-reachPhone)) points)")
check(ControlSpace(field: .zero).design == .zero, "an empty screen does not divide by zero")

let leftHalf = universal.controls.filter { $0.x < 0.5 }.count, rightHalf = universal.controls.filter { $0.x >= 0.5 && $0.y > 0.2 }.count
check(universal.controls.contains { $0.action == "lmb" } && universal.controls.contains { $0.action == "rmb" } && universal.controls.contains { $0.action == "lookmode" } && universal.controls.contains { $0.action == "stick-wasd" }, "Universal has the stick, both mouse buttons and the Look switch")
check(rightHalf <= 4 && leftHalf >= 6, "Universal: few controls on the right under the top row (\(rightHalf)), the rest on the left (\(leftHalf))")
check(ShippedLayouts.all.first?.id == "universal" && Set(ShippedLayouts.all.map(\.id)).count == ShippedLayouts.all.count, "Universal is first in the list and ids are unique")

// Button size (TouchButtonSize): a factor on what is drawn, and the arrangement maths follows it
check(TouchButtonSize.factor(setting: nil, isPad: false) == 1 && TouchButtonSize.factor(setting: "", isPad: false) == 1, "button size: automatic on a phone is the stored size")
check(TouchButtonSize.factor(setting: nil, isPad: true) == 1.2 && TouchButtonSize.factor(setting: "", isPad: true) == 1.2, "button size: automatic on an iPad is a little larger")
check(TouchButtonSize.factor(setting: "1", isPad: true) == 1 && TouchButtonSize.factor(setting: "1.2", isPad: false) == 1.2 && TouchButtonSize.factor(setting: "0.85", isPad: true) == 0.85, "button size: a chosen size wins on either device")
check(TouchButtonSize.factor(setting: "banana", isPad: false) == 1 && TouchButtonSize.factor(setting: "9", isPad: true) == 1.2 && TouchButtonSize.factor(setting: "0", isPad: false) == 1, "button size: a value that makes no sense is Automatic")
check(TouchButtonSize.choices.map(\.title) == ["Automatic", "Smaller", "Normal", "Larger", "Largest"] && Set(TouchButtonSize.choices.map(\.value)).count == 5, "button size: five distinct choices")
check(TouchButtonSize.title(setting: "1.1") == "Larger" && TouchButtonSize.title(setting: nil) == "Automatic" && TouchButtonSize.title(setting: "7") == "Automatic", "button size: names")
let sk = key("S", 0.5, 0.5, 60)
check(ControlArrange.extent(sk, scale: 1.5) == CGSize(width: 90, height: 90) && ControlArrange.extent(sk) == CGSize(width: 60, height: 60), "button size: a control is drawn at its size times the factor")
let spot2 = TouchControlSpec(label: "", action: "overlay-perf", x: 0.3, y: 0.3, size: 160)
check(ControlArrange.extent(spot2, scale: 1.5) == ControlArrange.extent(spot2), "button size: an overlay's spot is not a button and is not scaled")
do {
    let l = key("L", 0.2, 0.5, 40), r = key("R", 0.8, 0.5, 100)
    let f = CGSize(width: 1000, height: 500)
    let out = ControlArrange.align([l, r], ids: [l.id, r.id], edge: .bottom, in: f, scale: 1.5)
    check(abs(ControlArrange.frame(out[0], in: f, scale: 1.5).maxY - ControlArrange.frame(out[1], in: f, scale: 1.5).maxY) < 0.5, "button size: Align bottom lines up the edges as drawn at a larger size")
}
// Left-handed: the display flips, the stored layout does not
do {
    let right = ControlSpace(field: CGSize(width: 1180, height: 800)), left = ControlSpace(field: CGSize(width: 1180, height: 800), mirrored: true)
    for (x, y) in [(0.12, 0.72), (0.925, 0.80), (0.5, 0.5), (0.3, 0.1)] {
        let a = right.point(x: x, y: y), b = left.point(x: x, y: y)
        check(abs(a.x + b.x - 1180) < 1e-6 && abs(a.y - b.y) < 1e-6, "left-handed: a control at (\(x), \(y)) is on the opposite side, at the same height")
        let back = left.fractions(of: b)
        check(abs(back.x - x) < 1e-9 && abs(back.y - y) < 1e-9, "left-handed: points and fractions are each other's inverse")
    }
    let box = CGRect(x: 100, y: 100, width: 450, height: 300), mine = right.designRect(box), flipped = left.designRect(CGRect(x: 1180 - 550, y: 100, width: 450, height: 300))
    check(abs(mine.minX - flipped.minX) < 0.5 && abs(mine.width - flipped.width) < 0.5 && mine.width > 0, "left-handed: a box drawn on the mirrored screen selects the same controls")
    let phone = ControlSpace(field: CGSize(width: 750, height: 380), mirrored: true)
    check(abs(phone.point(x: 0.25, y: 0.5).x - 562.5) < 1e-9, "left-handed: on a phone it is a plain flip")
}
check(TouchHandedness.storedEdge(1, left: 1, right: 2, flipped: true) == 2 && TouchHandedness.storedEdge(2, left: 1, right: 2, flipped: true) == 1 && TouchHandedness.storedEdge(3, left: 1, right: 2, flipped: true) == 3 && TouchHandedness.storedEdge(1, left: 1, right: 2, flipped: false) == 1, "left-handed: Align left means the layout's right edge when flipped, and top, bottom, centres stay")
// The layout check: overlapping and tiny buttons
do {
    let phoneField = CGSize(width: 750, height: 380), padField = CGSize(width: 1180, height: 800)
    for l in ShippedLayouts.all {
        for (name, f) in [("phone", phoneField), ("iPad", padField)] {
            for k in [0.85, 1.0, 1.1, 1.2] {
                let r = LayoutCheck.run(l.layout, field: f, scale: k)
                check(r.overlapping.isEmpty, "check: the \(l.title) layout has no overlapping buttons on a \(name) at size \(k) (\(r.overlapping.count))")
            }
        }
    }
    let a = key("A", 0.5, 0.5, 60), b = key("B", 0.55, 0.5, 60), far = key("F", 0.9, 0.2, 60), tiny = key("T", 0.2, 0.8, 30)
    let r = LayoutCheck.run(TouchLayout(controls: [a, b, far, tiny]), field: CGSize(width: 750, height: 380))
    check(Set(r.overlapping) == [a.id, b.id], "check: two buttons on top of each other are found, and only those")
    check(r.small == [tiny.id], "check: a 30 point button is very small")
    check(r.summary == "2 buttons overlap another and 1 button is very small.", "check: the sentence (\(r.summary ?? "nil"))")
    check(LayoutCheck.run(TouchLayout(controls: [a, far]), field: CGSize(width: 750, height: 380)).summary == nil, "check: a clean layout says nothing")
    let rim = LayoutCheck.run(TouchLayout(controls: [key("L", 0.40, 0.5, 60), key("R", 0.40 + 60.0 / 750, 0.5, 60)]), field: CGSize(width: 750, height: 380))
    check(rim.isClean, "check: buttons touching rim to rim are not overlapping")
    let big = LayoutCheck.run(TouchLayout(controls: [key("L", 0.40, 0.5, 60), key("R", 0.40 + 70.0 / 750, 0.5, 60)]), field: CGSize(width: 750, height: 380), scale: 1.4)
    check(big.overlapping.count == 2, "check: a larger button size can make buttons overlap")
    let sp = TouchControlSpec(label: "", action: "overlay-perf", x: 0.5, y: 0.5, size: 160)
    check(LayoutCheck.run(TouchLayout(controls: [a, sp]), field: CGSize(width: 750, height: 380)).isClean, "check: an overlay spot is not a button")
    check(LayoutCheck.run(TouchLayout(), field: CGSize(width: 750, height: 380)).isClean, "check: an empty layout is clean")
}
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
S="$HERE/../../Sources/Core"
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$S/ControlArrange.swift" "$S/TouchPadControls.swift" "$S/VirtualPadModel.swift" "$S/ControllerKind.swift" "$S/BindSets.swift" "$S/PadActions.swift" "$S/DefaultControls.swift" "$S/PictureBand.swift" "$S/ShippedLayouts.swift" "$S/TouchButtonSize.swift" "$S/LayoutCheck.swift"
"$OUT/t"
rm -rf "$OUT"
