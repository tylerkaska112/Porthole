#!/bin/bash
# The input-lag meter's timing (Sources/Core/InputLagTracker.swift): which presses are timed, and how a press is followed to the game's read and to the next picture.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Double, _ b: Double, _ eps: Double = 0.0001) -> Bool { abs(a - b) <= eps }

// which changes are timed
let rest = PadSnapshot()
check(PadSnapshot(buttons: 0x1000).startsSomething(after: rest), "a button pressed is timed")
check(!PadSnapshot(buttons: 0).startsSomething(after: PadSnapshot(buttons: 0x1000)), "a button let go is not")
check(!PadSnapshot(buttons: 0x1000).startsSomething(after: PadSnapshot(buttons: 0x1000)), "a button already down is not a new press")
check(PadSnapshot(buttons: 0x1000 | 0x2000).startsSomething(after: PadSnapshot(buttons: 0x1000)), "a second button pressed while the first is down is timed")
check(PadSnapshot(rightTrigger: 255).startsSomething(after: rest) && !PadSnapshot(rightTrigger: 60).startsSomething(after: rest) && !PadSnapshot(rightTrigger: 255).startsSomething(after: PadSnapshot(rightTrigger: 200)), "a trigger pulled in is timed, a light touch or one already pulled is not")
check(PadSnapshot(lx: 30000, ly: 0).startsSomething(after: rest) && PadSnapshot(rx: 0, ry: -32767).startsSomething(after: rest), "a stick pushed out of its rest is timed, either stick")
check(!PadSnapshot(lx: 5000, ly: 0).startsSomething(after: rest), "a stick barely moved is not")
check(!PadSnapshot(lx: 31000, ly: 0).startsSomething(after: PadSnapshot(lx: 20000, ly: 0)), "a stick already pushed and moving about is not")
check(PadSnapshot(lx: 30000, ly: 0).startsSomething(after: PadSnapshot(lx: 3000, ly: 0)), "a stick pushed from a small wobble is")
check(!PadSnapshot(lx: 0, ly: 0).startsSomething(after: PadSnapshot(lx: 30000, ly: 0)), "a stick let go is not")

// following a press
var t = InputLagTracker()
check(!t.isMeasuring && t.medianToFrameMs == nil, "nothing is timed to begin with")
t.begin(at: 10.000, reads: 100)
check(t.isMeasuring, "a press starts the timing")
check(t.observe(at: 10.002, reads: 100, presents: 50) == nil, "no new read yet: still waiting")
check(t.observe(at: 10.006, reads: 101, presents: 50) == nil, "the game reads it: now waiting for a picture")
check(t.observe(at: 10.020, reads: 104, presents: 50) == nil, "more reads do not matter")
let m = t.observe(at: 10.031, reads: 106, presents: 51)
check(m != nil && near(m!.toRead, 0.006) && near(m!.toFrame, 0.031), "the first picture after the read ends it: 6 ms to the read, 31 ms to the picture")
check(!t.isMeasuring && t.recent.count == 1, "and it is kept")
// a present that happened before the read does not count
var u = InputLagTracker()
u.begin(at: 0, reads: 5)
u.observe(at: 0.010, reads: 5, presents: 9)
u.observe(at: 0.012, reads: 6, presents: 10)
check(u.observe(at: 0.020, reads: 6, presents: 10) == nil, "a picture presented before the game read the press does not end it")
check(u.observe(at: 0.045, reads: 6, presents: 11) != nil, "the next one does")
// another press while one is timed is ignored
var v = InputLagTracker()
v.begin(at: 1, reads: 0); v.begin(at: 1.01, reads: 3)
v.observe(at: 1.02, reads: 1, presents: 0)
let first = v.observe(at: 1.05, reads: 1, presents: 1)
check(first != nil && near(first!.toFrame, 0.05) && near(first!.toRead, 0.02), "a second press during the timing does not restart it")
// give up
var w = InputLagTracker()
w.begin(at: 0, reads: 0)
check(w.observe(at: 1.5, reads: 0, presents: 0) == nil && !w.isMeasuring && w.timedOut == 1, "a press the game never reads is given up after a second")
w.begin(at: 2, reads: 0); w.observe(at: 2.1, reads: 1, presents: 0)
check(w.observe(at: 3.5, reads: 1, presents: 0) == nil && !w.isMeasuring && w.timedOut == 2 && w.recent.isEmpty, "so is one the game reads and never shows")
// medians
var x = InputLagTracker()
for (i, ms) in [30.0, 32, 500, 31, 29].enumerated() {
    x.begin(at: Double(i) * 10, reads: 0); x.observe(at: Double(i) * 10 + 0.004, reads: 1, presents: 0); x.observe(at: Double(i) * 10 + ms / 1000, reads: 1, presents: 1)
}
check(x.recent.count == 5 && near(x.medianToFrameMs!, 31, 0.01) && near(x.medianToReadMs!, 4, 0.01), "the number shown is the median, so one odd press (500 ms) does not move it")
var y = InputLagTracker()
for i in 0..<40 { y.begin(at: Double(i), reads: 0); y.observe(at: Double(i) + 0.001, reads: 1, presents: 0); y.observe(at: Double(i) + 0.02, reads: 1, presents: 1) }
check(y.recent.count == InputLagTracker.keep, "only the last \(InputLagTracker.keep) presses are kept")
y.reset()
check(y.recent.isEmpty && !y.isMeasuring && y.timedOut == 0, "a new game starts clean")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/InputLagTracker.swift"
"$OUT/t"
rm -rf "$OUT"
