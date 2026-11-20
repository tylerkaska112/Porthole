#!/bin/bash
# The present-timing meter's arithmetic (Sources/Core/PresentTimingTracker.swift): the delay of a picture, the game's frame time from pictures in bunches, and the input lag put together from them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Double?, _ b: Double, _ eps: Double = 0.5) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

// no frame generation: one picture per game frame, 30 ms apart, each shown 120 ms after it was asked for
var t = PresentTimingTracker()
check(t.frameMs(now: 0) == nil && t.screenMs(now: 0) == nil, "nothing is reported before pictures have been seen")
for i in 0..<20 { let at = Double(i) * 0.030; t.asked(UInt64(i), at: at); t.shown(UInt64(i), at: at + 0.120) }
let end = 19 * 0.030 + 0.120
check(near(t.frameMs(now: end), 30) && near(t.screenMs(now: end), 120), "a picture every 30 ms and a delay of 120 ms are read back")

// frame generation, one generated picture per frame: pictures in pairs, the generated one shown 50 ms after it was asked, the real one 71 ms
var g = PresentTimingTracker()
for i in 0..<20 {
    let at = Double(i) * 0.040
    g.asked(UInt64(2 * i), at: at); g.asked(UInt64(2 * i + 1), at: at + 0.002)
    g.shown(UInt64(2 * i), at: at + 0.050); g.shown(UInt64(2 * i + 1), at: at + 0.073)
}
let gEnd = 19 * 0.040 + 0.073
check(near(g.frameMs(now: gEnd, picturesPerFrame: 2), 40, 1.5), "two pictures a game frame: the frame is 40 ms, not 20")
check(near(g.screenMs(now: gEnd, picturesPerFrame: 2), 71), "and the delay is the real picture's, the slower of the two: 71 ms")
check(near(g.screenMs(now: gEnd, picturesPerFrame: 1), 61, 12), "without being told how many pictures make a frame, the middle of all of them is reported")

// two generated pictures per frame (three in all) with a gap between frames
var h = PresentTimingTracker()
for i in 0..<20 {
    let at = Double(i) * 0.060
    for k in 0..<3 { h.asked(UInt64(3 * i + k), at: at + Double(k) * 0.008) }
    h.shown(UInt64(3 * i), at: at + 0.040); h.shown(UInt64(3 * i + 1), at: at + 0.060); h.shown(UInt64(3 * i + 2), at: at + 0.095)
}
let hEnd = 19 * 0.060 + 0.095
check(near(h.frameMs(now: hEnd, picturesPerFrame: 3), 60, 1.5), "three pictures a frame: 60 ms")
check(near(h.screenMs(now: hEnd, picturesPerFrame: 3), 79, 1), "and the slowest third are the real pictures")

// a dropped picture is not counted, the others are
var d = PresentTimingTracker()
for i in 0..<12 { let at = Double(i) * 0.03; d.asked(UInt64(i), at: at); if i != 5 { d.shown(UInt64(i), at: at + 0.06) } }
check(near(d.screenMs(now: 11 * 0.03 + 0.06), 60), "a picture that is never shown is skipped")

// old numbers are not reported
check(t.screenMs(now: end + 5) == nil && t.frameMs(now: end + 5) == nil, "after two seconds without pictures the numbers are dropped")

// a pause does not count: what came before it is left out
var p = PresentTimingTracker()
for i in 0..<10 { let at = Double(i) * 0.03; p.asked(UInt64(i), at: at); p.shown(UInt64(i), at: at + 0.5) }
for i in 0..<10 { let at = 1.2 + Double(i) * 0.03; p.asked(UInt64(100 + i), at: at); p.shown(UInt64(100 + i), at: at + 0.05) }
check(near(p.screenMs(now: 1.2 + 9 * 0.03 + 0.05), 50) && near(p.frameMs(now: 1.2 + 9 * 0.03 + 0.05), 30), "a stall of a second ends the picture of what came before")

// one odd picture does not move the number
var m = PresentTimingTracker()
for i in 0..<20 { let at = Double(i) * 0.030; m.asked(UInt64(i), at: at); m.shown(UInt64(i), at: at + (i == 7 ? 0.9 : 0.1)) }
check(near(m.screenMs(now: 19 * 0.03 + 0.1, picturesPerFrame: 1), 100, 5), "one slow picture among twenty moves the middle value little")

// the pictures asked for in the last two seconds only
var w = PresentTimingTracker()
for i in 0..<100 { let at = Double(i) * 0.05; w.asked(UInt64(i), at: at); w.shown(UInt64(i), at: at + (i < 50 ? 0.05 : 0.2)) }
check(near(w.screenMs(now: 99 * 0.05 + 0.2), 200), "the delay follows the last two seconds, not the whole game")

// reset
t.reset()
check(t.screenMs(now: end) == nil, "a new game starts clean")

// the estimate
check(near(InputLagEstimate.milliseconds(frameMs: 30, screenMs: 120, readMs: 3), 3 + 45 + 120, 0.001), "input lag = reading + one and a half game frames + the screen delay")
check(near(InputLagEstimate.milliseconds(frameMs: 48, screenMs: 46, readMs: 2, generating: true), 2 + 72 + 46 + 24, 0.001), "with frame generation making pictures, half a game frame more")
check(near(InputLagEstimate.milliseconds(frameMs: 30, screenMs: 120, readMs: nil), 165, 0.001), "without a measured reading it is the measured parts")
check(InputLagEstimate.milliseconds(frameMs: nil, screenMs: 100, readMs: 3) == nil && InputLagEstimate.milliseconds(frameMs: 30, screenMs: nil, readMs: 3) == nil, "and nothing until both are known")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/PresentTimingTracker.swift"
"$OUT/t"
rm -rf "$OUT"
