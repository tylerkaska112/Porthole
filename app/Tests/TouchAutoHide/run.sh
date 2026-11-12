#!/bin/bash
# The on-screen controls' idle timer (Sources/Core/TouchAutoHide.swift): when they hide, and what brings them back.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

var h = TouchAutoHide(); h.seconds = 10
h.tick(now: 0, suspended: false)
check(!h.hidden, "a fresh timer shows the controls")
check(!h.tick(now: 9.9, suspended: false) && !h.hidden, "just under the time: still shown")
check(h.tick(now: 10, suspended: false) && h.hidden, "after the time without a touch: hidden (and the change is reported)")
check(!h.tick(now: 30, suspended: false) && h.hidden, "stays hidden, no further change reported")
check(h.touch(now: 31, fingers: 1) && !h.hidden, "a touch brings them back at once (and says so)")
check(!h.touch(now: 32, fingers: 1), "a touch while shown reports no change")

h.touch(now: 100, fingers: 0)
check(!h.tick(now: 109, suspended: false) && !h.hidden, "the clock restarts at the last touch")
check(h.tick(now: 110, suspended: false) && h.hidden, "and runs out ten seconds after it")

var held = TouchAutoHide(); held.seconds = 5; held.tick(now: 0, suspended: false)
held.touch(now: 1, fingers: 1)
check(!held.tick(now: 60, suspended: false) && !held.hidden, "a finger held down (a stick) is never idle")
held.touch(now: 61, fingers: 0)
check(!held.tick(now: 65.9, suspended: false) && held.tick(now: 66, suspended: false), "the clock starts when the finger lifts")

var off = TouchAutoHide(); off.seconds = 0; off.tick(now: 0, suspended: false)
check(!off.tick(now: 1000, suspended: false) && !off.hidden, "0 means never")

var menu = TouchAutoHide(); menu.seconds = 5; menu.tick(now: 0, suspended: false)
check(menu.tick(now: 5, suspended: false) && menu.hidden, "hidden after the time")
check(menu.tick(now: 6, suspended: true) && !menu.hidden, "a menu or the editor opening shows them")
check(!menu.tick(now: 10.9, suspended: false) && !menu.hidden, "and the clock starts again when it closes, not from before")
check(menu.tick(now: 11, suspended: false) && menu.hidden, "so they hide five seconds after it closed")

var turnedOff = TouchAutoHide(); turnedOff.seconds = 5; turnedOff.tick(now: 0, suspended: false); turnedOff.tick(now: 6, suspended: false)
turnedOff.seconds = 0
check(turnedOff.tick(now: 7, suspended: false) && !turnedOff.hidden, "switching the setting off while hidden shows them")

check(TouchAutoHide.choices == [0, 5, 10, 20] && TouchAutoHide.title(0) == "Never" && TouchAutoHide.title(5) == "After 5 seconds", "the menu's choices and their words")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/TouchAutoHide.swift"
"$OUT/t"
rm -rf "$OUT"
