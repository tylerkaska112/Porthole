#!/bin/bash
# Compiles SteamDownloadRegion (Sources/Steam/SteamDownloadRegion.swift) for the Mac and checks the region list and the saved choice.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
let cells = SteamDownloadRegion.all.map(\.cell), names = SteamDownloadRegion.all.map(\.name)
check(Set(cells).count == cells.count, "every region number is listed once")
check(Set(names).count == names.count, "every region name is listed once")
check(!cells.contains(0) && cells.allSatisfy { $0 > 0 }, "0 is kept for Steam's own choice")
check(names.allSatisfy { !$0.isEmpty }, "every region has a name")
check(SteamDownloadRegion.name(forCell: 5) == "Frankfurt" && SteamDownloadRegion.name(forCell: 1) == "Chicago", "numbers read from Steam's directory map to their cities")
check(SteamDownloadRegion.name(forCell: 9999) == nil, "an unknown number has no name")
let d = UserDefaults(suiteName: "region-test-\(UUID().uuidString)")!
check(SteamDownloadRegion.chosen(d) == nil, "nothing saved means Steam's own choice")
d.set(5, forKey: SteamDownloadRegion.key)
check(SteamDownloadRegion.chosen(d) == 5, "a saved region is used")
d.set(9999, forKey: SteamDownloadRegion.key)
check(SteamDownloadRegion.chosen(d) == nil, "a number that is not in the list is ignored")
d.set(0, forKey: SteamDownloadRegion.key)
check(SteamDownloadRegion.chosen(d) == nil, "0 means automatic")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Steam/SteamDownloadRegion.swift"
"$OUT/t"
rm -rf "$OUT"
