#!/bin/bash
# Compiles StoreVisibility (Sources/Core/StoreVisibility.swift) for the Mac with a few checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
enum Store: String, CaseIterable { case steam, epic, gog, itch, amazon, ea }
let all = Store.allCases, known = all.map(\.rawValue)

check(StoreVisibility.visible(all, raw: "") == all, "nothing hidden: every store shows")
check(StoreVisibility.visible(all, raw: "itch,amazon") == [.steam, .epic, .gog, .ea], "hidden stores leave the list, the order stays")
check(StoreVisibility.hidden(all, raw: "amazon,itch") == [.itch, .amazon], "the hidden list follows the stores' own order")
check(StoreVisibility.visible(all, raw: " gog , ,nonsense") == [.steam, .epic, .itch, .amazon, .ea], "spaces, empty parts and unknown names do no harm")
check(StoreVisibility.visible(all, raw: known.joined(separator: ",")).isEmpty, "all hidden: nothing shows (the screen explains it)")

var raw = ""
raw = StoreVisibility.setting("ea", hidden: true, in: raw, known: known)
raw = StoreVisibility.setting("itch", hidden: true, in: raw, known: known)
check(raw == "itch,ea", "hiding stores keeps the string in the stores' order (\(raw))")
raw = StoreVisibility.setting("ea", hidden: true, in: raw, known: known)
check(raw == "itch,ea", "hiding one twice changes nothing")
raw = StoreVisibility.setting("itch", hidden: false, in: raw, known: known)
check(raw == "ea", "showing one again takes it out")
check(StoreVisibility.setting("old-store", hidden: true, in: "ea,old-store", known: known) == "ea", "a name that is no store is never kept")
check(StoreVisibility.setting("ea", hidden: false, in: "ea", known: known).isEmpty, "the last one shown again leaves an empty string")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/StoreVisibility.swift"
"$OUT/t"
rm -rf "$OUT"
