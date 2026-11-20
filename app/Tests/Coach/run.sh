#!/bin/bash
# Where the tutorial's card goes (CoachLayout in Sources/UI/Kit/CoachMarks.swift): beside the highlighted thing, on the side with room, arrow on the facing edge, always on screen.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
# CoachLayout is pure geometry: it is cut out of the kit file so the test needs no UIKit.
python3 - "$HERE/../../Sources/UI/Kit/CoachMarks.swift" "$OUT/layout.swift" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("enum CoachSide")
b = s.index("\n", a)
sides = "import CoreGraphics\nenum CoachSide { case auto, above, below, leading, trailing }\n"
c = s.index("enum CoachLayout")
open(sys.argv[2], "w").write(sides + s[c:])
PY
cat > "$OUT/main.swift" <<'S'
import CoreGraphics
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let phone = CGRect(x: 12, y: 50, width: 366, height: 750)         // portrait phone, margins taken off
let card = CGSize(width: 340, height: 190)

// A button near the top: the card goes below it, arrow on the card's top edge pointing up at the button.
var hole = CGRect(x: 40, y: 80, width: 80, height: 44)
var p = CoachLayout.place(card: card, hole: hole, in: phone)
check(p.frame.minY >= hole.maxY, "button at the top: the card is below it")
check(p.arrow == .top, "...and its arrow is on the top edge")
check(abs((p.frame.minX + p.arrowAt) - hole.midX) < 0.5, "...pointing at the middle of the button")
check(phone.contains(p.frame), "...and the card is on screen")

// A button near the bottom: above.
hole = CGRect(x: 250, y: 700, width: 100, height: 60)
p = CoachLayout.place(card: card, hole: hole, in: phone)
check(p.frame.maxY <= hole.minY && p.arrow == .bottom, "button at the bottom: the card is above it, arrow on the bottom edge")
check(phone.contains(p.frame), "...on screen (clamped sideways at the right edge)")
check(p.arrowAt <= card.width - 22 && p.arrowAt >= 22, "...the arrow stays on the card")

// The side asked for wins when it fits.
hole = CGRect(x: 100, y: 400, width: 100, height: 50)
p = CoachLayout.place(card: card, hole: hole, in: phone, side: .above)
check(p.frame.maxY <= hole.minY && p.arrow == .bottom, "side: above is honoured")

// A phone on its side (landscape): no room above or below a wide row, so the card goes beside it.
let land = CGRect(x: 40, y: 12, width: 760, height: 366)
hole = CGRect(x: 60, y: 120, width: 300, height: 130)
p = CoachLayout.place(card: card, hole: hole, in: land)
check(land.contains(p.frame) && !p.frame.intersects(hole), "landscape: the card is on screen and does not cover the highlight")

// A highlight too big for any side (a whole list): the card sits over the top or bottom, no arrow.
hole = CGRect(x: 20, y: 60, width: 350, height: 720)
p = CoachLayout.place(card: card, hole: hole, in: phone)
check(p.arrow == nil && phone.contains(p.frame), "a huge highlight: the card sits at an edge, no arrow, still on screen")

// Nothing highlighted: centred.
p = CoachLayout.place(card: card, hole: nil, in: phone)
check(abs(p.frame.midX - phone.midX) < 0.5 && abs(p.frame.midY - phone.midY) < 0.5 && p.arrow == nil, "no highlight: the card is in the middle")

// A card wider than the screen shrinks to it.
p = CoachLayout.place(card: CGSize(width: 900, height: 100), hole: nil, in: phone)
check(p.frame.width <= phone.width, "a card wider than the screen is cut to the screen")

// A target at the far left corner of the screen: the card is not pushed off.
hole = CGRect(x: 0, y: 760, width: 40, height: 40)
p = CoachLayout.place(card: card, hole: hole, in: phone)
check(phone.contains(p.frame) && p.arrowAt >= 22, "a target in a corner: the card stays on screen and the arrow on the card")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/layout.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
