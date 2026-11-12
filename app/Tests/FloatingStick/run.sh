#!/bin/bash
# Floating sticks' geometry (Sources/Core/FloatingStick.swift): the zone a stick takes touches in, who owns a touch, and where the base is centred.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import CoreGraphics
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let stick = CGRect(x: 100, y: 200, width: 100, height: 100)        // a stick at the lower left
let zone = FloatingStick.zone(of: stick)
check(zone == CGRect(x: 0, y: 120, width: 300, height: 260), "the zone is the frame grown a stick's width across and 0.8 up and down (\(zone))")
check(FloatingStick.takes(CGPoint(x: 150, y: 250), frame: stick, neighbours: []), "a touch on the stick is taken")
check(FloatingStick.takes(CGPoint(x: 30, y: 330), frame: stick, neighbours: []), "a touch in the zone, off the stick, is taken")
check(!FloatingStick.takes(CGPoint(x: 400, y: 250), frame: stick, neighbours: []), "a touch outside the zone is not")
let button = CGRect(x: 230, y: 220, width: 50, height: 50)
check(!FloatingStick.takes(CGPoint(x: 255, y: 245), frame: stick, neighbours: [button]), "a touch on a neighbouring control is left to it")
check(!FloatingStick.takes(CGPoint(x: 226, y: 245), frame: stick, neighbours: [button]), "and so is one just beside it (its slop)")
check(FloatingStick.takes(CGPoint(x: 150, y: 250), frame: stick, neighbours: [button]), "a touch the neighbour is not near still goes to the stick")

let field = CGRect(x: 40, y: 20, width: 800, height: 340)          // the safe area
check(FloatingStick.centre(touch: CGPoint(x: 300, y: 200), diameter: 100, field: field) == CGPoint(x: 300, y: 200), "a base is centred on the thumb")
check(FloatingStick.centre(touch: CGPoint(x: 45, y: 200), diameter: 100, field: field) == CGPoint(x: 90, y: 200), "near the left edge it moves right just enough to fit")
check(FloatingStick.centre(touch: CGPoint(x: 300, y: 355), diameter: 100, field: field) == CGPoint(x: 300, y: 310), "near the bottom it moves up just enough to fit")
check(FloatingStick.centre(touch: CGPoint(x: 900, y: -5), diameter: 100, field: field) == CGPoint(x: 790, y: 70), "a thumb outside both edges is brought to the nearest corner")
check(FloatingStick.centre(touch: CGPoint(x: 10, y: 10), diameter: 100, field: nil) == CGPoint(x: 10, y: 10), "with no field the thumb's point is used")
check(FloatingStick.centre(touch: CGPoint(x: 10, y: 10), diameter: 500, field: field) == CGPoint(x: 10, y: 10), "a field too small for the base does not move it")
check(FloatingStick.key == "f4.floatingSticks", "the setting's key")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/FloatingStick.swift"
"$OUT/t"
rm -rf "$OUT"
