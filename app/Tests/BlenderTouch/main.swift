import Foundation
import CoreGraphics

final class Recorder: PointerSink {
    var log: [String] = []
    func pointerMove(_ p: CGPoint) { log.append("move") }
    func pointerPress(_ b: MouseButton, at p: CGPoint) { log.append("press \(b)") }
    func pointerRelease(_ b: MouseButton, at p: CGPoint) { log.append("release \(b)") }
    func pointerClick(_ b: MouseButton, at p: CGPoint) { log.append("click \(b)") }
    func pointerWheel(_ delta: Int32, at p: CGPoint) { log.append(delta > 0 ? "wheel up" : "wheel down") }
    func pointerKey(_ vk: Int32, down: Bool) { log.append("key \(vk) \(down ? "down" : "up")") }
}

var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok    \(name)") } else { failed += 1; print("FAIL  \(name) \(detail())") }
}
func make(blender: Bool, mode: NavMode = .select) -> (TouchGestureEngine, Recorder) {
    let e = TouchGestureEngine(), r = Recorder()
    e.sink = r; e.blender = blender; e.navMode = mode
    return (e, r)
}
func events(_ r: Recorder) -> [String] { r.log.filter { $0 != "move" } }
func balanced(_ r: Recorder) -> Bool {
    var shift = 0, middle = 0
    for l in r.log { if l == "key 16 down" { shift += 1 }; if l == "key 16 up" { shift -= 1 }; if l == "press middle" { middle += 1 }; if l == "release middle" { middle -= 1 } }
    return shift == 0 && middle == 0
}
var t: TimeInterval = 0
func tick() -> TimeInterval { t += 0.016; return t }

// 1. Plain mouse (not Blender): two fingers moving do nothing but wheel on a pinch; a drag is the left button.
do {
    let (e, r) = make(blender: false)
    e.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e.began(2, at: CGPoint(x: 200, y: 100), time: tick())
    for i in 1...10 { e.moved(1, to: CGPoint(x: 100, y: 100 + CGFloat(i) * 10), time: tick()); e.moved(2, to: CGPoint(x: 200, y: 100 + CGFloat(i) * 10), time: tick()) }
    e.ended(1, at: CGPoint(x: 100, y: 200), time: tick()); e.ended(2, at: CGPoint(x: 200, y: 200), time: tick())
    check("not Blender: two-finger move sends no middle button and no Shift", !r.log.contains("press middle") && !r.log.contains("key 16 down"), "\(events(r))")
    let (e2, r2) = make(blender: false, mode: .orbit)
    e2.began(1, at: CGPoint(x: 50, y: 50), time: tick()); e2.moved(1, to: CGPoint(x: 150, y: 50), time: tick()); e2.ended(1, at: CGPoint(x: 150, y: 50), time: tick())
    check("not Blender: a mode set by mistake is ignored (drag = left button)", events(r2) == ["press left", "release left"], "\(events(r2))")
}

// 2. Blender: two fingers moving = pan (Shift + middle drag).
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e.began(2, at: CGPoint(x: 200, y: 100), time: tick())
    for i in 1...10 { e.moved(1, to: CGPoint(x: 100 + CGFloat(i) * 8, y: 100), time: tick()); e.moved(2, to: CGPoint(x: 200 + CGFloat(i) * 8, y: 100), time: tick()) }
    e.ended(1, at: CGPoint(x: 180, y: 100), time: tick()); e.ended(2, at: CGPoint(x: 280, y: 100), time: tick())
    check("Blender: two-finger move = Shift down, middle press, middle release, Shift up", events(r) == ["key 16 down", "press middle", "release middle", "key 16 up"], "\(events(r))")
    check("Blender: pan leaves nothing held", balanced(r))
}

// 3. Blender: a pinch zooms (wheel) and does not pan.
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 150, y: 100), time: tick()); e.began(2, at: CGPoint(x: 250, y: 100), time: tick())
    for i in 1...8 { e.moved(1, to: CGPoint(x: 150 - CGFloat(i) * 6, y: 100), time: tick()); e.moved(2, to: CGPoint(x: 250 + CGFloat(i) * 6, y: 100), time: tick()) }
    e.ended(1, at: CGPoint(x: 100, y: 100), time: tick()); e.ended(2, at: CGPoint(x: 300, y: 100), time: tick())
    check("Blender: spreading two fingers zooms in", events(r).contains("wheel up") && !events(r).contains("press middle"), "\(events(r))")
}


// 3b. Blender: a lopsided pinch (one finger does most of the work, so the midpoint drifts) still only zooms.
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 150, y: 100), time: tick()); e.began(2, at: CGPoint(x: 250, y: 100), time: tick())
    for i in 1...14 { e.moved(1, to: CGPoint(x: 150 - CGFloat(i) * 7, y: 100 + CGFloat(i) * 2), time: tick()); e.moved(2, to: CGPoint(x: 250 + CGFloat(i) * 2, y: 100), time: tick()) }
    e.ended(1, at: CGPoint(x: 52, y: 128), time: tick()); e.ended(2, at: CGPoint(x: 278, y: 100), time: tick())
    check("Blender: a pinch whose midpoint drifts zooms and does not pan", events(r).contains("wheel up") && !events(r).contains("press middle") && !events(r).contains("key 16 down"), "\(events(r))")
    // and the other way round: closing the fingers on one side
    let (e2, r2) = make(blender: true)
    e2.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e2.began(2, at: CGPoint(x: 300, y: 100), time: tick())
    for i in 1...14 { e2.moved(1, to: CGPoint(x: 100 + CGFloat(i) * 9, y: 100 - CGFloat(i)), time: tick()); e2.moved(2, to: CGPoint(x: 300 - CGFloat(i) * 3, y: 100), time: tick()) }
    e2.ended(1, at: CGPoint(x: 226, y: 86), time: tick()); e2.ended(2, at: CGPoint(x: 258, y: 100), time: tick())
    check("Blender: closing the fingers zooms out and does not pan", events(r2).contains("wheel down") && !events(r2).contains("press middle"), "\(events(r2))")
}

// 3c. Blender: a pan whose fingers wobble a little in spacing still only pans (no zoom).
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e.began(2, at: CGPoint(x: 200, y: 100), time: tick())
    for i in 1...14 { let wobble = CGFloat(i % 3) * 2; e.moved(1, to: CGPoint(x: 100 + CGFloat(i) * 9, y: 100 + CGFloat(i) * 3), time: tick()); e.moved(2, to: CGPoint(x: 200 + CGFloat(i) * 9 + wobble, y: 100 + CGFloat(i) * 3), time: tick()) }
    e.ended(1, at: CGPoint(x: 226, y: 142), time: tick()); e.ended(2, at: CGPoint(x: 328, y: 142), time: tick())
    check("Blender: a pan with a wobbling spacing pans and does not zoom", events(r).contains("press middle") && !events(r).contains("wheel up") && !events(r).contains("wheel down"), "\(events(r))")
    check("Blender: that pan leaves nothing held", balanced(r))
}

// 4. Blender: two-finger tap is still a right click.
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e.began(2, at: CGPoint(x: 160, y: 100), time: tick())
    e.ended(1, at: CGPoint(x: 100, y: 100), time: tick()); e.ended(2, at: CGPoint(x: 160, y: 100), time: tick())
    check("Blender: two-finger tap = right click", events(r) == ["click right"], "\(events(r))")
}

// 5. Blender: three fingers orbit (middle button, no Shift).
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e.began(2, at: CGPoint(x: 160, y: 100), time: tick()); e.began(3, at: CGPoint(x: 220, y: 100), time: tick())
    for i in 1...10 { for (id, x) in [(1, 100), (2, 160), (3, 220)] { e.moved(id, to: CGPoint(x: CGFloat(x) + CGFloat(i) * 6, y: 100 + CGFloat(i) * 3), time: tick()) } }
    for id in 1...3 { e.ended(id, at: CGPoint(x: 200, y: 140), time: tick()) }
    check("Blender: three fingers = middle press and release, no Shift", events(r) == ["press middle", "release middle"], "\(events(r))")
    check("Blender: orbit leaves nothing held", balanced(r))
}

// 6. Blender: a pan that grows into three fingers hands over cleanly.
do {
    let (e, r) = make(blender: true)
    e.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e.began(2, at: CGPoint(x: 200, y: 100), time: tick())
    for i in 1...6 { e.moved(1, to: CGPoint(x: 100 + CGFloat(i) * 8, y: 100), time: tick()); e.moved(2, to: CGPoint(x: 200 + CGFloat(i) * 8, y: 100), time: tick()) }
    e.began(3, at: CGPoint(x: 300, y: 100), time: tick())
    for i in 1...6 { for (id, x) in [(1, 148), (2, 248), (3, 300)] { e.moved(id, to: CGPoint(x: CGFloat(x) + CGFloat(i) * 6, y: 100), time: tick()) } }
    for id in 1...3 { e.ended(id, at: CGPoint(x: 300, y: 100), time: tick()) }
    check("Blender: pan then a third finger leaves nothing held", balanced(r), "\(events(r))")
}

// 7. One finger in each mode.
for (mode, want) in [(NavMode.select, ["press left", "release left"]), (.orbit, ["press middle", "release middle"]), (.pan, ["key 16 down", "press middle", "release middle", "key 16 up"])] {
    let (e, r) = make(blender: true, mode: mode)
    e.began(1, at: CGPoint(x: 50, y: 50), time: tick()); e.moved(1, to: CGPoint(x: 150, y: 50), time: tick()); e.ended(1, at: CGPoint(x: 150, y: 50), time: tick())
    check("Blender one-finger drag in \(mode)", events(r) == want, "\(events(r))")
    let (e2, r2) = make(blender: true, mode: mode)
    e2.began(1, at: CGPoint(x: 50, y: 50), time: tick()); e2.ended(1, at: CGPoint(x: 50, y: 50), time: tick())
    check("Blender one-finger tap in \(mode) is a left click", events(r2) == ["click left"], "\(events(r2))")
}

// 8. A touch the system takes away mid-gesture releases everything.
do {
    let (e, r) = make(blender: true, mode: .pan)
    e.began(1, at: CGPoint(x: 50, y: 50), time: tick()); e.moved(1, to: CGPoint(x: 150, y: 50), time: tick()); e.cancelled(1)
    check("Blender: a cancelled pan leaves nothing held", balanced(r) && events(r).contains("key 16 up"), "\(events(r))")
    let (e2, r2) = make(blender: true)
    e2.began(1, at: CGPoint(x: 100, y: 100), time: tick()); e2.began(2, at: CGPoint(x: 200, y: 100), time: tick())
    for i in 1...6 { e2.moved(1, to: CGPoint(x: 100 + CGFloat(i) * 8, y: 100), time: tick()); e2.moved(2, to: CGPoint(x: 200 + CGFloat(i) * 8, y: 100), time: tick()) }
    e2.cancelled(1); e2.cancelled(2)
    check("Blender: a cancelled two-finger pan leaves nothing held", balanced(r2), "\(events(r2))")
}

print(failed == 0 ? "all passed" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
