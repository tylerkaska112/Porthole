#!/bin/bash
# Compiles DiscordModels (Sources/Discord/DiscordModels.swift) for the Mac and checks how a server's channels are grouped and ordered for the Discord browser.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias C = DiscordGuild.Channel
func ch(_ id: String, _ name: String, _ kind: C.Kind, parent: String? = nil, _ position: Int = 0) -> C { C(id: id, name: name, kind: kind, parentID: parent, position: position, topic: nil) }

let guild = DiscordGuild(id: "1", name: "Porthole Testers", channels: [
    ch("v2", "Game night", .voice, parent: "cv", 1), ch("t2", "bug-reports", .text, parent: "cc", 1), ch("cv", "Voice", .category, 2),
    ch("top2", "announcements", .announcement, 1), ch("t1", "general", .text, parent: "cc", 0), ch("cc", "Chat", .category, 1), ch("top1", "welcome", .text, 0),
    ch("v1", "Lounge", .voice, parent: "cv", 0), ch("emptycat", "Nothing here", .category, 3), ch("orphan", "lost", .text, parent: "gone", 5),
    ch("mix-voice", "Voice first?", .voice, parent: "cc", 0),
])
let sections = guild.sections
check(sections.map(\.id) == ["top", "cc", "cv"], "the channels above every category come first, then the categories by position (the empty one is left out)")
check(sections[0].channels.map(\.id) == ["top1", "top2", "orphan"], "above the categories: by position, and a channel whose category is unknown goes there too")
check(sections[1].channels.map(\.id) == ["t1", "t2", "mix-voice"], "inside a category the words come before voice, then by position")
check(sections[2].channels.map(\.id) == ["v1", "v2"], "voice channels by position")
check(guild.voiceChannels.map(\.id).sorted() == ["mix-voice", "v1", "v2"], "the voice channels are all the voice ones")
check(C(id: "s", name: "Stage", kind: .stage).isVoice, "a stage channel can be joined like a voice channel")
check(C(id: "f", name: "Forum", kind: .forum).isTextual && !C(id: "f", name: "Forum", kind: .forum).isVoice, "a forum is read, not joined")
check(DiscordGuild(id: "1", name: "Porthole Testers").initials == "PT", "a server without a picture shows two letters")
check(DiscordGuild(id: "1", name: "iPad Gaming").initials == "IG" && DiscordGuild(id: "1", name: "Factorio").initials == "F", "one word gives one letter")
check(DiscordGuild(id: "1", name: "!!!").initials == "?", "a name without letters gives a question mark")
check(DiscordGuild(id: "42", name: "x", icon: "abc").iconURL?.absoluteString == "https://cdn.discordapp.com/icons/42/abc.png?size=96", "the picture address")
check(DiscordGuild(id: "42", name: "x", icon: "").iconURL == nil && DiscordGuild(id: "42", name: "x").iconURL == nil, "no picture, no address")
check(DiscordGuild(id: "1", name: "Empty").sections.isEmpty, "a server with no channel has no sections")
let g1 = DiscordGuild(id: "1", name: "Testers", channels: [ch("t", "chat", .text), ch("v", "Lounge", .voice)])
let g2 = DiscordGuild(id: "2", name: "Friends", channels: [ch("v2", "Build", .voice)])
func who(_ id: String) -> CallMember { CallMember(id: id, name: id, avatarURL: nil, speaking: false, isSelf: false) }
let call = FriendCall.of(person: "alex", roster: ["v": [who("sam"), who("alex")], "v2": [who("jo")]], guilds: [g1, g2])
check(call?.guild.id == "1" && call?.channel.id == "v" && call?.label == "Lounge, Testers", "a friend's call is the voice channel the servers list them in")
check(FriendCall.of(person: "jo", roster: ["v": [who("alex")], "v2": [who("jo")]], guilds: [g1, g2])?.guild.id == "2", "...in whichever server it is")
check(FriendCall.of(person: "mika", roster: ["v": [who("alex")]], guilds: [g1, g2]) == nil, "a friend in no channel has no call")
check(FriendCall.of(person: "alex", roster: ["gone": [who("alex")]], guilds: [g1, g2]) == nil, "a channel of a server this account does not have gives no call")
check(FriendCall.of(person: "alex", roster: ["t": [who("alex")]], guilds: [g1]) == nil, "a text channel is not a call")
// Threads and forums
let threaded = DiscordGuild(id: "9", name: "Threads", channels: [
    ch("cat", "Chat", .category, 0), ch("gen", "general", .text, parent: "cat", 0), ch("forum", "ideas", .forum, parent: "cat", 1),
    ch("th1", "plan the raid", .publicThread, parent: "gen", 0), ch("th2", "newer thread", .publicThread, parent: "gen", 0), ch("post", "a forum post", .publicThread, parent: "forum", 0),
])
check(threaded.sections.flatMap(\.channels).map(\.id) == ["gen", "forum"], "threads are not listed as channels")
check(threaded.channel("th1")?.readsMessages == true && threaded.channel("th1")?.isThread == true, "a thread reads messages like a text channel")
check(threaded.channel("forum")?.isForum == true && threaded.channel("forum")?.readsMessages == false, "a forum is a list of posts, not messages")
check(threaded.threads(of: "gen").map(\.id) == ["th2", "th1"], "the open threads of a channel, newest first")
check(threaded.threads(of: "forum").isEmpty, "a forum's posts are not listed under it as threads")
var hidden = threaded
hidden.channels[1].overwrites = [DiscordPermissions.Overwrite(id: "9", isMember: false, allow: 0, deny: DiscordPermissions.viewChannel)]
hidden.roles["9"] = DiscordPermissions.viewChannel
hidden.myRoles = []
let seen = hidden.visible(for: "me")
check(seen.channel("gen") == nil && seen.channel("th1") == nil && seen.channel("th2") == nil, "a thread of a channel this account cannot open is hidden too")
check(seen.channel("forum") != nil && seen.channel("post") != nil, "...and the other threads stay")
// Safety: gaps in what Discord sent must never hide a whole server
var noRoles = threaded
noRoles.myRoles = []
check(noRoles.visible(for: "me").channels.count == threaded.channels.count, "no role list known: every channel stays")
var allHidden = threaded
allHidden.roles["9"] = 0
allHidden.myRoles = []
check(allHidden.visible(for: "me").channels.filter { !$0.isCategory }.count == threaded.channels.filter { !$0.isCategory }.count, "if the rules would hide every channel, the server keeps them all")
var partly = threaded
partly.roles["9"] = DiscordPermissions.viewChannel
partly.myRoles = []
partly.channels[1].overwrites = [DiscordPermissions.Overwrite(id: "9", isMember: false, allow: 0, deny: DiscordPermissions.viewChannel)]
check(partly.visible(for: "me").channel("gen") == nil, "...but a single hidden channel is still hidden")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift"
"$OUT/t"
rm -rf "$OUT"
