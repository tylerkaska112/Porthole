#!/bin/bash
# Which of a server's channels this account may open, and the order of its servers (Sources/Discord/DiscordPermissions.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias P = DiscordPermissions

let guild = "100", me = "7", staff = "200", muted = "201"
func standing(roles mine: [String]?, owner: String? = "1") -> P.Standing {
    P.Standing(guildID: guild, ownerID: owner, me: me, roles: [guild: P.viewChannel | P.sendMessages, staff: P.administrator == 0 ? 0 : 1 << 13, muted: 0], myRoles: mine)
}
func ow(_ id: String, member: Bool = false, allow: UInt64 = 0, deny: UInt64 = 0) -> P.Overwrite { P.Overwrite(id: id, isMember: member, allow: allow, deny: deny) }

// Parsing
check(P.parse("1071698660929") == 1071698660929, "permission bits arrive as a decimal string")
check(P.parse(1024) == 1024 && P.parse(nil) == 0 && P.parse("junk") == 0, "numbers parse, junk is none")
let list: [[String: Any]] = [["id": "100", "type": 0, "allow": "0", "deny": "1024"], ["id": "7", "type": 1, "allow": "1024", "deny": "0"], ["id": "5", "type": "role", "allow": "0", "deny": "0"]]
let parsed = P.overwrites(from: list)
check(parsed.count == 3 && parsed[0].deny == 1024 && parsed[1].isMember && !parsed[2].isMember, "overwrites: role, member (as number) and role (as word)")

// Base
check(P.base(standing(roles: [])) == P.viewChannel | P.sendMessages, "no roles: what @everyone grants")
check(P.base(standing(roles: [], owner: me)) == P.all, "the owner has everything")
var admin = standing(roles: ["900"]); admin.roles["900"] = P.administrator
check(P.base(admin) == P.all, "an administrator role gives everything")

// Channels
check(P.canView([], standing(roles: [])), "a channel with no overwrites follows the server-wide permissions")
check(!P.canView([ow(guild, deny: P.viewChannel)], standing(roles: [])), "@everyone denied: hidden")
check(P.canView([ow(guild, deny: P.viewChannel), ow(staff, allow: P.viewChannel)], standing(roles: [staff])), "a role of mine allows what @everyone denies")
check(!P.canView([ow(guild, deny: P.viewChannel), ow(staff, allow: P.viewChannel)], standing(roles: [])), "...but not for someone without that role")
check(!P.canView([ow(muted, deny: P.viewChannel)], standing(roles: [muted])), "a role of mine denies it")
check(P.canView([ow(muted, deny: P.viewChannel), ow(staff, allow: P.viewChannel)], standing(roles: [muted, staff])), "an allow from one role wins over a deny from another at the same level")
check(P.canView([ow(guild, deny: P.viewChannel), ow(me, member: true, allow: P.viewChannel)], standing(roles: [])), "my own overwrite allows it")
check(!P.canView([ow(staff, allow: P.viewChannel), ow(me, member: true, deny: P.viewChannel)], standing(roles: [staff])), "my own overwrite denies it even when a role allows it")
check(P.canView([ow(guild, deny: P.viewChannel)], standing(roles: [], owner: me)), "the owner sees everything")
check(P.canView([ow(guild, deny: P.viewChannel)], admin), "an administrator sees everything")
check(P.canView([ow(guild, deny: P.viewChannel)], standing(roles: nil)), "roles not known: nothing is hidden")

// Server order
let settings: [String: Any] = ["guild_folders": [["id": NSNull(), "guild_ids": ["3", "1"]], ["id": 5, "guild_ids": [2]]]]
check(P.serverOrder(fromSettings: settings) == ["3", "1", "2"], "folders give the order, servers inside a folder in their own order")
check(P.serverOrder(fromSettings: ["guild_positions": ["9", "8", "9"]]) == ["9", "8"], "a plain list works and a repeat is dropped")
check(P.serverOrder(fromSettings: nil).isEmpty, "no settings, no order")
struct G { var id: String }
let sorted = P.sort([G(id: "1"), G(id: "2"), G(id: "3"), G(id: "4")], id: { $0.id }, by: ["3", "1"]).map(\.id)
check(sorted == ["3", "1", "2", "4"], "servers in the list first, the rest after in the order they came")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordPermissions.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
