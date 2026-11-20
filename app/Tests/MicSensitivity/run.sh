#!/bin/bash
# Compiles MicSensitivity for the Mac and checks the percent -> level mapping and the meter position.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Float, _ b: Float, _ eps: Float) -> Bool { abs(a - b) <= eps }

check(near(MicSensitivity.threshold(percent: 50), 0.012, 0.0001), "50 % is the level the app always used (0.012)")
check(MicSensitivity.threshold(percent: 100) < MicSensitivity.threshold(percent: 50) && MicSensitivity.threshold(percent: 50) < MicSensitivity.threshold(percent: 0), "more sensitive = a lower level is enough")
check(near(MicSensitivity.threshold(percent: 100), 0.0012, 0.0001), "100 % is about -58 dB")
check(near(MicSensitivity.threshold(percent: 0), 0.12, 0.002), "0 % is about -18 dB")
check(MicSensitivity.threshold(percent: -40) == MicSensitivity.threshold(percent: 0) && MicSensitivity.threshold(percent: 900) == MicSensitivity.threshold(percent: 100), "out of range values are held to 0...100")
let a = MicSensitivity.threshold(percent: 30) / MicSensitivity.threshold(percent: 40), b = MicSensitivity.threshold(percent: 70) / MicSensitivity.threshold(percent: 80)
check(near(a, b, 0.001), "every ten percent is the same number of decibels")
check(MicSensitivity.meterPosition(rms: 0) == 0 && MicSensitivity.meterPosition(rms: 1) == 1 && MicSensitivity.meterPosition(rms: 0.0001) == 0, "the meter holds silence at 0 and anything loud at 1")
check(near(MicSensitivity.meterPosition(rms: powf(10, -37.5 / 20)), 0.5, 0.001), "-37.5 dB is the middle of the meter")
let t = MicSensitivity.thresholdPosition(percent: 50)
check(t > 0.4 && t < 0.6, "the standard threshold is drawn near the middle")
check(MicSensitivity.thresholdPosition(percent: 100) < t && t < MicSensitivity.thresholdPosition(percent: 0), "the tick moves left as sensitivity goes up")
check(MicSensitivity.clamp(49.6) == 50, "percent is rounded")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/MicSensitivity.swift"
"$OUT/t"
rm -rf "$OUT"
