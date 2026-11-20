#!/bin/bash
# Compiles LaunchArgumentText (Sources/Core/LaunchArgumentText.swift) for the Mac and checks how iOS smart punctuation is put back.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
let typed = "\u{201C}C:\\Program Files (x86)\\Steam\\steamapps\\common\\FINAL FANTASY IX\u{201D}"
check(LaunchArgumentText.plain(typed) == "\"C:\\Program Files (x86)\\Steam\\steamapps\\common\\FINAL FANTASY IX\"", "the folder of the Memoria patcher gets straight quotes")
check(LaunchArgumentText.plain("\u{2014}windowed \u{2013}w 1280") == "--windowed -w 1280", "an em dash is two hyphens, an en dash one")
check(LaunchArgumentText.plain("it\u{2019}s") == "it's", "a curly apostrophe is straight")
check(LaunchArgumentText.plain("a\u{2026}") == "a...", "an ellipsis is three dots")
check(LaunchArgumentText.plain("a\u{00A0}b") == "a b", "a no-break space is a space")
check(LaunchArgumentText.plain("-windowed -width 1280 \"C:\\My Games\\x\"") == "-windowed -width 1280 \"C:\\My Games\\x\"", "text that was already plain is not touched")
check(LaunchArgumentText.plain("") == "", "empty stays empty")
check(LaunchArgumentText.plain("\u{00E9}\u{65E5}\u{672C}") == "\u{00E9}\u{65E5}\u{672C}", "other characters are left alone")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/LaunchArgumentText.swift"
"$OUT/t"
rm -rf "$OUT"
