#!/bin/bash
# What a failed JIT tells the person (Sources/Core/JITFailureHint.swift): the messages and the facts come from the Hub's problem and compatibility reports (1.3.0: "JIT failed (checking the
# connection: the device is not ready for debugging)" on installs signed without the VPN permission, and with LocalDevVPN chosen but not running).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias F = JITFailureHint.Facts
let notReady = "JIT failed (checking the connection: the device is not ready for debugging): check that the tunnel (or LocalDevVPN) is on and the pairing file is current."
let timedOut = "JIT timed out. Check that the tunnel (or LocalDevVPN) is on and the pairing file is current. StikDebug is another JIT method you can choose in Settings."

// Compatibility reports 278-283 and 335: no VPN permission, "Use LocalDevVPN instead" off, no VPN on.
let noPermission = F(ownTunnelCannotStart: true, useLocalDevVPN: false, vpnInterfaceUp: false)
check(JITFailureHint.hint(for: notReady, facts: noPermission) == JITFailureHint.localDevOffByChoice, "no VPN permission, no VPN on: say to use LocalDevVPN")
check(JITFailureHint.message(notReady, facts: noPermission).hasPrefix(notReady), "the helper's own words stay first")
check(JITFailureHint.shouldFailBeforeTrying(noPermission), "that case stops before a long wait")
// A VPN is on (LocalDevVPN used without the setting): JIT is still tried.
let someVPN = F(ownTunnelCannotStart: true, useLocalDevVPN: false, vpnInterfaceUp: true)
check(!JITFailureHint.shouldFailBeforeTrying(someVPN), "a VPN that is on may be LocalDevVPN: the attempt goes ahead")
check(JITFailureHint.hint(for: notReady, facts: someVPN) == JITFailureHint.noOwnTunnel, "…and if it still fails, the hint names the missing VPN permission and the setting")
// Reports 266, 288, 299, 317, 318: "Use LocalDevVPN instead" on, JIT waited then failed.
let localOff = F(ownTunnelCannotStart: true, useLocalDevVPN: true, vpnInterfaceUp: false)
check(JITFailureHint.hint(for: timedOut, facts: localOff) == JITFailureHint.localDevNotUp, "LocalDevVPN chosen but no VPN on: open LocalDevVPN and connect")
check(!JITFailureHint.shouldFailBeforeTrying(localOff), "the setting says LocalDevVPN is the way: try it")
let localOn = F(ownTunnelCannotStart: true, useLocalDevVPN: true, vpnInterfaceUp: true)
check(JITFailureHint.hint(for: notReady, facts: localOn) == nil, "LocalDevVPN chosen and a VPN is on: nothing to add (the cause is elsewhere)")
// An install that can start its own tunnel: nothing to add, and no early stop.
let fine = F(ownTunnelCannotStart: false, useLocalDevVPN: false, vpnInterfaceUp: false)
check(JITFailureHint.hint(for: notReady, facts: fine) == nil && !JITFailureHint.shouldFailBeforeTrying(fine), "a working own tunnel: unchanged")
// Other failures keep their words.
for other in ["JIT can only be tried once each time Porthole is opened. Close Porthole completely.", "Import a pairing file first (Updates > JIT).", "The JIT helper did not start."] {
    check(JITFailureHint.hint(for: other, facts: noPermission) == nil && JITFailureHint.message(other, facts: noPermission) == other, "unrelated failure untouched: \(other.prefix(40))")
}
check(!JITFailureHint.noOwnTunnel.isEmpty && JITFailureHint.noOwnTunnel.contains("LocalDevVPN") && JITFailureHint.noOwnTunnel.contains("Settings"), "the early message names LocalDevVPN and where the setting is")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/JITFailureHint.swift"
"$OUT/t"
rm -rf "$OUT"
