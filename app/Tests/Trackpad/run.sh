#!/bin/bash
# The touch screen as a trackpad (Sources/UI/TrackpadEngine.swift), with scripted touches.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import CoreGraphics
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

final class Rec: PointerSink {
    var log: [String] = []
    func pointerMove(_ p: CGPoint) { log.append("move(\(Int(p.x.rounded())),\(Int(p.y.rounded())))") }
    func pointerPress(_ b: MouseButton, at p: CGPoint) { log.append("press \(b)(\(Int(p.x.rounded())),\(Int(p.y.rounded())))") }
    func pointerRelease(_ b: MouseButton, at p: CGPoint) { log.append("release \(b)(\(Int(p.x.rounded())),\(Int(p.y.rounded())))") }
    func pointerClick(_ b: MouseButton, at p: CGPoint) { log.append("click \(b)(\(Int(p.x.rounded())),\(Int(p.y.rounded())))") }
    func pointerWheel(_ d: Int32, at p: CGPoint) { log.append("wheel \(d)") }
}
func make(accel: CGFloat = 0, start: CGPoint = CGPoint(x: 500, y: 300)) -> (TrackpadEngine, Rec) {
    let e = TrackpadEngine(), r = Rec(); e.sink = r; e.config.acceleration = accel; e.cursor = start
    e.bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    return (e, r)
}

do { // sliding moves the cursor by the finger's travel, not to the finger
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 100), time: 0)
    check(r.log.isEmpty && e.cursor == CGPoint(x: 500, y: 300), "a finger going down moves nothing")
    e.moved(1, to: CGPoint(x: 130, y: 90), time: 0.05)
    check(e.cursor == CGPoint(x: 530, y: 290) && r.log == ["move(530,290)"], "sliding 30 right and 10 up moves the cursor 30 right and 10 up from where it was")
    e.ended(1, at: CGPoint(x: 130, y: 90), time: 0.3)
    check(!r.log.contains { $0.hasPrefix("click") }, "a slide is not a click")
}
do { // a tap clicks at the cursor
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 100), time: 0); e.ended(1, at: CGPoint(x: 101, y: 100), time: 0.1)
    check(r.log == ["click left(500,300)"], "a tap clicks where the cursor is, not under the finger (\(r.log))")
}
do { // a slow press is not a tap
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 100), time: 0); e.ended(1, at: CGPoint(x: 100, y: 100), time: 0.9)
    check(r.log.isEmpty, "a long press with no movement clicks nothing")
}
do { // tap then touch again and slide = drag
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 100), time: 0); e.ended(1, at: CGPoint(x: 100, y: 100), time: 0.08)
    e.began(2, at: CGPoint(x: 200, y: 200), time: 0.2)
    e.moved(2, to: CGPoint(x: 240, y: 200), time: 0.25)
    e.ended(2, at: CGPoint(x: 240, y: 200), time: 0.4)
    check(r.log == ["click left(500,300)", "press left(500,300)", "move(540,300)", "release left(540,300)"], "tap, touch again and slide: the button is held while the cursor moves, released at lift (\(r.log))")
}
do { // the second touch too late is an ordinary slide
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 100), time: 0); e.ended(1, at: CGPoint(x: 100, y: 100), time: 0.08)
    e.began(2, at: CGPoint(x: 100, y: 100), time: 0.8)
    e.moved(2, to: CGPoint(x: 120, y: 100), time: 0.85)
    check(!r.log.contains { $0.hasPrefix("press") }, "a second touch after the drag window does not drag")
}
do { // two-finger tap = right click
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 100), time: 0); e.began(2, at: CGPoint(x: 160, y: 100), time: 0.01)
    e.ended(1, at: CGPoint(x: 100, y: 100), time: 0.12); e.ended(2, at: CGPoint(x: 160, y: 100), time: 0.13)
    check(r.log == ["click right(500,300)"], "a two-finger tap is a right click at the cursor (\(r.log))")
    check(!e.isTouching, "and ends cleanly")
}
do { // right mode swaps the buttons
    let (e, r) = make(); e.primary = .right
    e.began(1, at: CGPoint(x: 0, y: 0), time: 0); e.ended(1, at: CGPoint(x: 0, y: 0), time: 0.1)
    e.began(1, at: CGPoint(x: 0, y: 0), time: 1); e.began(2, at: CGPoint(x: 50, y: 0), time: 1.01); e.ended(1, at: CGPoint(x: 0, y: 0), time: 1.1); e.ended(2, at: CGPoint(x: 50, y: 0), time: 1.12)
    check(r.log == ["click right(500,300)", "click left(500,300)"], "right mode: a tap is the right button, two fingers the left")
}
do { // two fingers sliding scroll
    let (e, r) = make()
    e.began(1, at: CGPoint(x: 100, y: 300), time: 0); e.began(2, at: CGPoint(x: 160, y: 300), time: 0.01)
    e.moved(1, to: CGPoint(x: 100, y: 250), time: 0.05); e.moved(2, to: CGPoint(x: 160, y: 250), time: 0.05)
    check(r.log == ["wheel -120", "wheel -120"], "two fingers up 50 points: two notches, the content follows the fingers (\(r.log))")
    e.ended(1, at: CGPoint(x: 100, y: 250), time: 0.3); e.ended(2, at: CGPoint(x: 160, y: 250), time: 0.31)
    check(!r.log.contains { $0.hasPrefix("click") }, "scrolling is never a click")
    let (e2, r2) = make(); e2.naturalScroll = false
    e2.began(1, at: CGPoint(x: 100, y: 300), time: 0); e2.began(2, at: CGPoint(x: 160, y: 300), time: 0.01)
    e2.moved(1, to: CGPoint(x: 100, y: 330), time: 0.05); e2.moved(2, to: CGPoint(x: 160, y: 330), time: 0.05)
    check(r2.log == ["wheel -120"], "with natural scrolling off the direction is the wheel's own (\(r2.log))")
}
do { // the cursor stays on the picture
    let (e, _) = make(start: CGPoint(x: 990, y: 5))
    e.began(1, at: .zero, time: 0); e.moved(1, to: CGPoint(x: 200, y: -200), time: 0.05)
    check(e.cursor == CGPoint(x: 1000, y: 0), "the cursor stops at the edge of the picture (\(e.cursor))")
}
do { // faster swipes go further
    let (slow, _) = make(accel: 0.8), (fast, _) = make(accel: 0.8)
    slow.began(1, at: .zero, time: 0); slow.moved(1, to: CGPoint(x: 40, y: 0), time: 0.4)       // 100 points a second
    fast.began(1, at: .zero, time: 0); fast.moved(1, to: CGPoint(x: 40, y: 0), time: 0.02)      // 2000 points a second
    check(fast.cursor.x - 500 > slow.cursor.x - 500 + 15, "the same travel moves the cursor further when it is quick (\(slow.cursor.x - 500) against \(fast.cursor.x - 500))")
}
do { // sensitivity
    let (e, _) = make(); e.config.sensitivity = TrackpadEngine.Speed.fast.sensitivity
    e.began(1, at: .zero, time: 0); e.moved(1, to: CGPoint(x: 50, y: 0), time: 0.5)
    check(e.cursor.x == 580, "the Fast setting moves the cursor 1.6 times the finger's travel (\(e.cursor.x))")
}
do { // a held drag is released when the touch is cancelled
    let (e, r) = make()
    e.began(1, at: .zero, time: 0); e.ended(1, at: .zero, time: 0.05)
    e.began(2, at: .zero, time: 0.15); e.cancelled(2)
    check(r.log == ["click left(500,300)", "press left(500,300)", "release left(500,300)"] && !e.isTouching, "a cancelled drag lets go of the button")
}
do { // a third finger changes nothing and lets go cleanly
    let (e, r) = make()
    e.began(1, at: .zero, time: 0); e.began(2, at: CGPoint(x: 40, y: 0), time: 0.01); e.began(3, at: CGPoint(x: 80, y: 0), time: 0.02)
    e.ended(1, at: .zero, time: 0.1); e.ended(2, at: .zero, time: 0.11); e.ended(3, at: .zero, time: 0.12)
    check(r.log.isEmpty && !e.isTouching, "three fingers do nothing and leave nothing held")
}
check(PointerMode.direct.rawValue == "direct" && PointerMode.allCases.count == 2 && TrackpadEngine.Speed.allCases.count == 3, "the choices")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/UI/TrackpadEngine.swift" "$HERE/../../Sources/UI/TouchGestureEngine.swift"
"$OUT/t"
rm -rf "$OUT"
