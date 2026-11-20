#!/bin/bash
# Compiles CommunityLinks (Sources/Core/CommunityLinks.swift) for the Mac and checks the list Settings > Community and links shows.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let shown = CommunityLinks.visible().flatMap(\.links)
let ids = CommunityLinks.all.flatMap(\.links).map(\.id)
check(Set(ids).count == ids.count, "every link has its own id")
check(shown.allSatisfy { $0.url != nil }, "a shown link always has an address")
check(shown.allSatisfy { $0.url?.scheme == "https" }, "every address is https")
check(CommunityLinks.x?.absoluteString == "https://x.com/portholehq", "X is the portholehq account, without a tracking suffix")
check(CommunityLinks.discord?.host == "discord.gg", "Discord is an invite link")
check(shown.contains { $0.id == "x" } && shown.contains { $0.id == "discord" } && shown.contains { $0.id == "github" } && shown.contains { $0.id == "website" }, "X, Discord, GitHub and the website are listed")
let allowed: Set<String> = ["x.com", "discord.gg", "github.com", "portholehq.site", "www.tiktok.com", "tiktok.com"]
check(shown.allSatisfy { allowed.contains($0.url?.host ?? "") }, "every address is on a host Porthole owns or links on purpose")

// An account that does not exist yet is not shown (TikTok until it has an address); with one it appears
check(CommunityLinks.tiktok != nil || !shown.contains { $0.id == "tiktok" }, "TikTok is hidden while it has no address")
let withTikTok = CommunityLinks.all.map { section in
    CommunityLinks.Section(title: section.title, note: section.note, links: section.links.map { $0.id == "tiktok" ? CommunityLinks.Link(id: $0.id, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, url: URL(string: "https://www.tiktok.com/@portholehq")) : $0 })
}
check(CommunityLinks.visible(withTikTok).flatMap(\.links).contains { $0.id == "tiktok" }, "TikTok appears once it has an address")
let empty = [CommunityLinks.Section(title: "Nothing", note: nil, links: [CommunityLinks.Link(id: "a", title: "A", subtitle: "", symbol: "x", url: nil)])]
check(CommunityLinks.visible(empty).isEmpty, "a section with no usable link disappears")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/CommunityLinks.swift"
"$OUT/t"
rm -rf "$OUT"
