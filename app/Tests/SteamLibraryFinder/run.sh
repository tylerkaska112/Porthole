#!/bin/bash
# Compiles SteamLibraryFinder (Sources/Core/SteamLibraryFinder.swift) for the Mac and checks how a picked drive folder is searched for a Steam library.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("slf-\(UUID().uuidString)")
func make(_ path: String) -> URL { let u = base.appendingPathComponent(path, isDirectory: true); try! fm.createDirectory(at: u, withIntermediateDirectories: true); return u }

// the picked folder is itself the library
let a = make("a"); _ = make("a/steamapps")
check(SteamLibraryFinder.find(in: a) == a, "a folder with steamapps is the library")
// steamapps itself was picked
check(SteamLibraryFinder.find(in: a.appendingPathComponent("steamapps")) == a, "picking steamapps itself gives its parent")
// the whole drive was picked: a PC drive keeps SteamLibrary/steamapps
let drive = make("drive"); _ = make("drive/Documents"); _ = make("drive/SteamLibrary/steamapps"); _ = make("drive/Other/steamapps")
check(SteamLibraryFinder.find(in: drive)?.lastPathComponent == "SteamLibrary", "the usual name wins over another folder with steamapps")
// an unusual name still works one level down
let odd = make("odd"); _ = make("odd/My Games/steamapps")
check(SteamLibraryFinder.find(in: odd)?.lastPathComponent == "My Games", "any folder one level down that holds steamapps is found")
// nothing: not too deep
let deep = make("deep"); _ = make("deep/x/y/steamapps")
check(SteamLibraryFinder.find(in: deep) == nil, "only one level down is searched")
let empty = make("empty")
check(SteamLibraryFinder.find(in: empty) == nil, "an empty folder has no library")
// a file named steamapps is not a library
let file = make("file"); fm.createFile(atPath: file.appendingPathComponent("steamapps").path, contents: Data())
check(SteamLibraryFinder.find(in: file) == nil, "a file called steamapps is not a library")
// hidden folders are skipped
let hidden = make("hidden"); _ = make("hidden/.Trashes/steamapps")
check(SteamLibraryFinder.find(in: hidden) == nil, "hidden folders are skipped")

let added = SteamLibraryFinder.summary(driveName: "SanDisk", installed: 5, added: 3)
check(added.title == "Added 3 games from SanDisk", "added title")
check(SteamLibraryFinder.summary(driveName: "SanDisk", installed: 1, added: 1).title == "Added 1 game from SanDisk", "one game is singular")
check(SteamLibraryFinder.summary(driveName: "SanDisk", installed: 4, added: 0).title == "No new games on SanDisk", "nothing new")
check(SteamLibraryFinder.summary(driveName: "SanDisk", installed: 0, added: 0).title == "No Steam games found on SanDisk", "nothing found")
try? fm.removeItem(at: base)
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/SteamLibraryFinder.swift"
"$OUT/t"
rm -rf "$OUT"
