#!/bin/bash
# Compiles EngineStats (Sources/Core/EngineStats.swift) for the Mac and checks the swap figure read from the engine's census line.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func stats(_ line: String) -> EngineStats {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-stats-\(UUID().uuidString).txt")
    try! (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return EngineStats.read(from: url)
}
// The line from a real GTA V Enhanced run in broad mode (2026-11-13): the file ran to 37 GB, the disk held 1.9 GB, the cap was 3 GB
let broad = "[swap] census file-backed now=37187MB peak=37192MB extents=80 file=37215/3072MB free=7 merges=28 | commit MB by reason: backed=2190 small=5810 | reserve-backed 156 (37942MB) holes=3463 disk=1963MB churn-sizes=2 | reservations not taken whole MB: prot=380 | footprint=5759MB coverage=broad min=4096KB"
let b = stats(broad)
check(b.swapFileUsedMB == 1963, "broad mode shows what is on the disk (1963 MB), not the file's length")
check(b.swapFileCapMB == 3072, "the cap is read as before")
check(b.swapBackedMB == 37187, "the memory held in the file is still read")
check(b.swapCoverage == "broad", "the coverage is read")
// The classic mode has no disk= and its file= is what was handed out
let classic = "[swap] census file-backed now=900MB peak=1000MB extents=12 file=950/4096MB free=3 merges=1 | commit MB by reason: backed=900 | reserve-backed 0 (0MB) holes=0 footprint=4100MB coverage=classic"
let c = stats(classic)
check(c.swapFileUsedMB == 950 && c.swapFileCapMB == 4096, "classic mode keeps file= as the used figure")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/EngineStats.swift"
"$OUT/t"
rm -rf "$OUT"
