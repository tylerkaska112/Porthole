#!/bin/bash
# The on-screen keyboard's key table and sticky modifiers (Sources/Core/TouchKeyboardModel.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let rows = TouchKeyboard.rows
check(rows.count == 6, "six rows")
check(rows.allSatisfy { abs($0.reduce(0) { $0 + $1.weight } - TouchKeyboard.rowUnits) < 0.001 }, "every row is 15 units wide: \(rows.map { $0.reduce(0) { $0 + $1.weight } })")
let all = rows.flatMap { $0 }
func count(_ vk: Int32) -> Int { all.filter { $0.vk == vk }.count }
check("ABCDEFGHIJKLMNOPQRSTUVWXYZ".allSatisfy { count(Int32($0.asciiValue!)) == 1 }, "every letter once")
check("0123456789".allSatisfy { count(Int32($0.asciiValue!)) == 1 }, "every digit once")
check((0x70...0x7B).allSatisfy { count(Int32($0)) == 1 }, "F1 to F12 once each")
check([0x25, 0x26, 0x27, 0x28].allSatisfy { count(Int32($0)) == 1 }, "four arrows once each")
check([0x1B, 0x09, 0x0D, 0x20, 0x08, 0x14, 0x2E].allSatisfy { count(Int32($0)) == 1 }, "Esc, Tab, Enter, Space, Backspace, Caps and Delete once each")
check(count(0x10) == 2 && count(0x11) == 1 && count(0x12) == 1, "two Shifts, one Ctrl and one Alt")
check([0xC0, 0xBD, 0xBB, 0xDB, 0xDD, 0xDC, 0xBA, 0xDE, 0xBC, 0xBE, 0xBF].allSatisfy { count(Int32($0)) == 1 }, "the punctuation keys, by their OEM codes")
check(all.allSatisfy { $0.vk > 0 && $0.vk < 0xFF && !$0.legend.isEmpty }, "every key has a code and a legend")
check(all.filter { $0.isModifier }.count == 4 && all.filter { $0.isModifier }.allSatisfy { ["Shift", "Ctrl", "Alt"].contains($0.legend) }, "the modifiers are Shift, Ctrl and Alt")
check(rows[1].prefix(13).dropFirst().prefix(9).allSatisfy { $0.shifted != nil }, "the number row has shifted legends")
check(TouchKeyboard.compactRows.count == 5 && TouchKeyboard.compactRows.first?.first?.legend == "`" && TouchKeyboard.rows(compact: false).count == 6 && TouchKeyboard.rows(compact: true).count == 5, "compact drops the function row only")

var m = StickyModifiers()
check(m.held.isEmpty && m.state(0x10) == .off, "nothing held at first")
m.tap(0x10, now: 1)
check(m.state(0x10) == .once && m.held == [0x10], "a tap holds Shift for the next key")
m.keyPressed()
check(m.state(0x10) == .off && m.held.isEmpty, "an ordinary key lets it go")
m.tap(0x11, now: 10); m.tap(0x11, now: 10.2)
check(m.state(0x11) == .locked, "a quick second tap locks it")
m.keyPressed(); m.keyPressed()
check(m.state(0x11) == .locked, "a locked modifier stays through any number of keys")
m.tap(0x11, now: 20)
check(m.state(0x11) == .off, "a tap on a locked one lets go")
m.tap(0x12, now: 30); m.tap(0x12, now: 31)
check(m.state(0x12) == .off, "a slow second tap switches it off, not on")
m.tap(0x10, now: 40); m.tap(0x11, now: 40.1); m.tap(0x12, now: 40.2)
check(m.held == [0x10, 0x11, 0x12], "Shift, Ctrl and Alt together (Ctrl+Alt+Shift combinations)")
m.keyPressed()
check(m.held.isEmpty, "all three let go after the next key")
m.tap(0x10, now: 50); m.tap(0x10, now: 50.1)
m.tap(0x41, now: 51)
check(m.state(0x10) == .locked && m.state(0x41) == .off, "a key that is not a modifier is ignored")
m.reset()
check(m.held.isEmpty, "reset lets go of everything")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/TouchKeyboardModel.swift"
"$OUT/t"
rm -rf "$OUT"
