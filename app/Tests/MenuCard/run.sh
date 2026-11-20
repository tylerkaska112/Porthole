#!/bin/bash
# The iPad menu card's sizing rules (MenuCardSizing in Sources/UI/Kit/MenuKit.swift): the standard width, how far it can be dragged, when a drag closes it, what the expand button gives.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
python3 - "$HERE/../../Sources/UI/Kit/MenuKit.swift" "$OUT/sizing.swift" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("enum MenuCardSizing")
b = s.index("/// The size the person gave the iPad's card")
open(sys.argv[2], "w").write("import CoreGraphics\n" + s[a:b])
PY
cat > "$OUT/main.swift" <<'S'
import CoreGraphics
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias S = MenuCardSizing

// Standard: 500 held sideways on a 1024 pt iPad, 560 upright on a 768 pt one, never more than the screen can hold.
check(S.standard(total: 1024) == 500, "standard on a 1024 pt wide iPad is 500")
check(S.standard(total: 1366) == 500, "standard on a 12.9 inch iPad held sideways is still 500")
check(S.standard(total: 768) == 560, "standard held upright on a 768 pt iPad is 560")
check(S.standard(total: 744) == 560 && S.standard(total: 744) <= 744 - 2 * S.margin, "standard on a 744 pt iPad mini upright fits")

// Limits.
check(S.clamp(200, total: 1024) == S.minimum, "a width below the minimum is raised to it")
check(S.clamp(5000, total: 1024) == S.maximum(total: 1024), "a width above the maximum is cut to it")
check(S.maximum(total: 1024) == 1024 - 2 * S.margin - S.handleRoom, "the maximum leaves room for the handle at the far edge")
check(S.maximum(total: 1024) > S.standard(total: 1024), "the card can be made bigger than the standard size")

// Dragging the handle: to the left (negative) widens, to the right narrows.
check(S.dragged(from: 500, by: -120) == 620, "dragging the handle 120 to the left makes the card 120 wider")
check(S.dragged(from: 500, by: 80) == 420, "dragging it 80 to the right makes it 80 narrower")

// Closing: pulled in well past the minimum.
check(!S.shouldClose(proposed: 420), "a card made smaller but above the minimum stays open")
check(!S.shouldClose(proposed: S.minimum - 40), "a little past the minimum still stays open (it keeps the minimum)")
check(S.shouldClose(proposed: S.minimum - 71), "pulled in more than 70 points past the minimum it closes on release")
check(S.shouldClose(proposed: 100), "pulled almost off the screen it closes")

// The expand button.
check(S.large(total: 1024) == S.clamp(1024 * 0.82, total: 1024), "large is 82 percent of the screen, within the limits")
check(S.isLarge(S.large(total: 1024), total: 1024), "the large size counts as large")
check(!S.isLarge(S.standard(total: 1024), total: 1024), "the standard size does not")
check(!S.isLarge(S.standard(total: 1024) + 40, total: 1024), "a card only a little wider than standard is not large")
check(S.large(total: 768) <= S.maximum(total: 768), "large never exceeds what the screen allows upright")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/sizing.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
