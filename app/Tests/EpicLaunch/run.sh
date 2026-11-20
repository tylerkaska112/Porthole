#!/bin/bash
# What Epic's launcher puts on a game's command line (Sources/Epic/EpicLaunchArguments.swift), checked against Legendary's get_launch_parameters.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias A = EpicLaunchArguments

// The catalog's answer, the shape Legendary reads: { catalogItemId: { customAttributes: { Name: { type, value } } } }
let ot: [String: Any] = ["cat1": ["customAttributes": ["OwnershipToken": ["type": "STRING", "value": "true"], "CanRunOffline": ["type": "STRING", "value": "true"],
                                                          "AdditionalCommandLine": ["type": "STRING", "value": "-NoEpicWeb -foo=bar"]]]]
check(A.attributes(fromCatalog: ot, catalogItemId: "cat1") == A.Attributes(requiresOwnershipToken: true, additionalCommandLine: "-NoEpicWeb -foo=bar"), "ownership token and extra arguments are read")
let plain: [String: Any] = ["cat2": ["customAttributes": ["CanRunOffline": ["value": "true"]]]]
check(A.attributes(fromCatalog: plain, catalogItemId: "cat2") == A.Attributes(), "a game with neither asks for neither")
let off: [String: Any] = ["cat3": ["customAttributes": ["OwnershipToken": ["value": "false"]]]]
check(!A.attributes(fromCatalog: off, catalogItemId: "cat3").requiresOwnershipToken, "OwnershipToken = false is not needed")
let upper: [String: Any] = ["cat4": ["customAttributes": ["ownershiptoken": ["value": "TRUE"], "AdditionalCommandline": ["value": "-x"]]]]
check(A.attributes(fromCatalog: upper, catalogItemId: "cat4") == A.Attributes(requiresOwnershipToken: true, additionalCommandLine: "-x"), "names and TRUE are read without regard to case (Legendary spells the extra arguments both ways)")
for odd in [[:] as [String: Any], ["cat5": 3] as [String: Any], ["cat5": ["customAttributes": [1, 2]]] as [String: Any], ["cat5": ["customAttributes": ["OwnershipToken": "true"]]] as [String: Any], ["cat5": ["customAttributes": ["OwnershipToken": ["value": 7]]]] as [String: Any]] {
    check(A.attributes(fromCatalog: odd, catalogItemId: "cat5") == A.Attributes(), "an answer of another shape gives the defaults")
}
check(A.attributes(fromCatalog: "not a dictionary", catalogItemId: "x") == A.Attributes() && A.attributes(fromCatalog: ot, catalogItemId: "missing") == A.Attributes(), "a wrong document or an id that is not there: defaults")

// Extra arguments are cleaned.
check(A.cleaned("-a\u{0A}-b\u{0D}") == "-a-b" || A.cleaned("-a\u{0A}-b") == "-a-b", "line breaks are removed")
check(A.cleaned("-NoSplash -AUTH_PASSWORD=x -epicuserid=y -epicusername=z -ok") == "-NoSplash -ok", "an extra argument cannot replace the sign-in or the account")
check(A.cleaned(String(repeating: "-a ", count: 300)).isEmpty, "an absurdly long line is dropped")
check(A.cleaned("   ").isEmpty, "blank stays blank")

// The command line: Legendary's order, plus the sandbox.
let args = try! A.build(appName: "Sugar", exchangeCode: "CODE", displayName: "Name", accountID: "ID", namespace: "ns1", ownershipTokenPath: nil)
check(args == ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=CODE", "-AUTH_TYPE=exchangecode", "-epicapp=Sugar", "-epicenv=Prod", "-EpicPortal", "-epicusername=Name", "-epicuserid=ID", "-epiclocale=en", "-epicsandboxid=ns1"], "the arguments are Legendary's, with -epicsandboxid last")
let withOT = try! A.build(appName: "Sugar", exchangeCode: "CODE", displayName: "N", accountID: "I", namespace: "ns1", ownershipTokenPath: "C:\\ProgramData\\Porthole\\epic-ovt\\Sugar.ovt")
check(withOT.firstIndex(of: "-epicovt=C:\\ProgramData\\Porthole\\epic-ovt\\Sugar.ovt") == 5 && withOT.firstIndex(of: "-EpicPortal") == 6, "-epicovt comes after -epicenv and before -EpicPortal, as in Legendary")
check(!(try! A.build(appName: "a", exchangeCode: "c", displayName: "n", accountID: "i", namespace: nil, ownershipTokenPath: nil)).contains { $0.hasPrefix("-epicsandboxid") }, "no namespace: no sandbox argument")
check(!(try! A.build(appName: "a", exchangeCode: "c", displayName: "n", accountID: "i", namespace: "", ownershipTokenPath: "")).contains { $0.hasPrefix("-epicsandboxid") || $0.hasPrefix("-epicovt") }, "empty values are left out")
var threw = 0
for bad in ["a\"b", "a\nb"] {
    do { _ = try A.build(appName: "a", exchangeCode: "c", displayName: bad, accountID: "i", namespace: nil, ownershipTokenPath: nil) } catch { threw += 1 }
    do { _ = try A.build(appName: "a", exchangeCode: "c", displayName: "n", accountID: "i", namespace: bad, ownershipTokenPath: nil) } catch { threw += 1 }
}
check(threw == 4, "a quote or a line break in the account name or the sandbox is refused (it would start another argument)")

// The token file.
check(A.tokenPath(appName: "Sugar") == "C:\\ProgramData\\Porthole\\epic-ovt\\Sugar.ovt", "one file per game, in Porthole's drive C")
check(A.tokenPath(appName: "../../x\\y").hasPrefix(A.tokenFolder + "\\") && !A.tokenPath(appName: "../../x\\y").dropFirst(A.tokenFolder.count + 1).contains("\\") && !A.tokenPath(appName: "../../x").contains(".."), "the app name cannot leave the folder")
check(A.tokenPath(appName: "") == A.tokenFolder + "\\game.ovt", "an empty name still gives a file name")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Epic/EpicLaunchArguments.swift"
"$OUT/t"
rm -rf "$OUT"
