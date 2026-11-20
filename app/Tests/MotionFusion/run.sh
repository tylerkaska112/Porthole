#!/bin/bash
# Compiles MotionFusion (Sources/Core/MotionFusion.swift) for the Mac and checks how a controller's orientation is worked out from its gyro and gravity.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
import simd
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Float, _ b: Float, _ e: Float = 0.02) -> Bool { abs(a - b) < e }
let down = SIMD3<Float>(0, 0, -1)
func deg(_ r: Float) -> Float { r * 180 / .pi }

// Held flat and still, face up.
var f = MotionFusion()
f.update(rate: [0, 0, 0], gravity: [0, 0, -1], dt: 0.01)
check(near(f.orientation.angle, 0) || near(f.orientation.real, 1), "flat and face up: no turn")
f.update(rate: [0, 0, 0], gravity: [0, 0, -1], dt: 0.01)
check(near(MotionFusion.heading(of: f.orientation), 0), "and its front points straight ahead")

// Started tilted: front end up 30 degrees. Gravity in the pad's own axes is the room's down seen from the pad.
let tilt = simd_quatf(angle: 30 * .pi / 180, axis: [1, 0, 0])
var t = MotionFusion()
let g = tilt.inverse.act(down)
t.update(rate: [0, 0, 0], gravity: g, dt: 0.01)
let seen = t.orientation.inverse.act(down)
check(simd_length(seen - g) < 0.02, "started tilted: the pad knows which way is down")
let front = t.orientation.act(SIMD3<Float>(0, 1, 0))
check(near(deg(asin(front.z)), 30, 1.5), "and that its front is up 30 degrees")

// Turned a quarter turn about the vertical in a second: the heading follows.
var y = MotionFusion()
y.update(rate: [0, 0, 0], gravity: [0, 0, -1], dt: 0.01)
for _ in 0..<100 { y.update(rate: [0, 0, .pi / 2], gravity: [0, 0, -1], dt: 0.01) }
check(near(MotionFusion.heading(of: y.orientation), .pi / 2, 0.03), "turned a quarter turn: the heading is 90 degrees")

// A gyro that drifts slowly while the pad lies still is held level by gravity.
var d = MotionFusion()
d.update(rate: [0, 0, 0], gravity: [0, 0, -1], dt: 0.01)
for _ in 0..<500 { d.update(rate: [0.05, 0, 0], gravity: [0, 0, -1], dt: 0.01) }
let up = d.orientation.act(SIMD3<Float>(0, 0, 1))
check(deg(acos(max(-1, min(1, up.z)))) < 3.0, "a drifting gyro is held level by gravity (under 3 degrees off after five seconds)")

// "Centre" takes the heading out and leaves the tilt.
let q = simd_quatf(angle: 40 * .pi / 180, axis: [0, 0, 1]) * simd_quatf(angle: 20 * .pi / 180, axis: [1, 0, 0])
let h = MotionFusion.heading(of: q)
let c = MotionFusion.levelled(q, heading: h)
check(near(MotionFusion.heading(of: c), 0, 0.02), "centred: the heading is gone")
check(near(deg(asin(c.act(SIMD3<Float>(0, 1, 0)).z)), 20, 1.0), "and the tilt is kept")

// Bad numbers change nothing.
var b = MotionFusion()
b.update(rate: [0, 0, 0], gravity: [0, 0, -1], dt: 0.01)
let before = b.orientation
b.update(rate: [.nan, 0, 0], gravity: [.nan, 0, 0], dt: 0.01)
check(near(b.orientation.real, before.real, 0.001), "a broken reading changes nothing")
b.update(rate: [1, 0, 0], gravity: nil, dt: 2)
check(near(b.orientation.real, before.real, 0.001), "a gap of seconds is skipped")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/MotionFusion.swift"
"$OUT/t"
rm -rf "$OUT"
