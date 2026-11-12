import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 } }
func clean(_ s: String, names: [String] = []) -> String { LogCleaner.clean(s, accountNames: names) }
func cleanBig(_ s: String, names: [String] = []) -> String { String(decoding: LogCleaner.cleanData(Data(s.utf8), accountNames: names), as: UTF8.self) }

for (name, f) in [("clean", { (s: String, n: [String]) in clean(s, names: n) }), ("cleanData", { (s: String, n: [String]) in cleanBig(s, names: n) })] {
    check(f("path /private/var/mobile/Containers/Data/Application/21205BC2-10D8-42B2-99C8-7AC89EFD4979/tmp/x", []) == "path /private/var/mobile/Containers/Data/Application/<id>/tmp/x", "\(name): container folder id")
    check(f("/Users/someone/Library/x and /Users/other/y", []) == "/Users/<user>/Library/x and /Users/<user>/y", "\(name): home folder")
    check(f("mail me at a.b+c@example.com now", []) == "mail me at <email> now", "\(name): e-mail")
    check(f("a line without one: x@y", []) == "a line without one: x@y", "\(name): not an e-mail")
    check(f("steam 76561198012345678 here", []) == "steam <steamid> here", "\(name): Steam id")
    check(f("-epicuserid=0123456789abcdef0123456789abcdef -epicusername=Bob", []) == "-epicuserid=<epic-id> -epicusername=<account>", "\(name): Epic id and name")
    check(f("AUTH_PASSWORD=hunter2hunter2 next", []) == "AUTH_PASSWORD=<redacted> next", "\(name): auth password")
    check(f("api_key = abcdefghijklmnop1234 and Token: ABCDEFGHIJKLMNOPQRSTUV", []) == "api_key = <redacted> and Token: <redacted>", "\(name): named secrets")
    check(f("ip 8.8.8.8 and 192.168.1.5 and 10.0.0.1 and 127.0.0.1", []) == "ip <ip> and 192.168.1.5 and 10.0.0.1 and 127.0.0.1", "\(name): public IPv4 only")
    check(f("v6 2001:db8::1 and ::1 and fe80::1", []) == "v6 <ip> and ::1 and fe80::1", "\(name): public IPv6 only")
    check(f("hello TheReacher24 and thereacher24", ["TheReacher24"]) == "hello <account> and <account>", "\(name): account name, any case")
    check(f("[fdtrace] close fd=2886 why=fd-cache-release", ["TheReacher24"]) == "[fdtrace] close fd=2886 why=fd-cache-release", "\(name): an ordinary line is untouched")
}
// A piece boundary inside a big text keeps whole lines.
let line = "[12:00:00.000] [INFO] hello /Users/someone/x 1.2.3.4 a@b.cc\n"
let big = String(repeating: line, count: 80_000)
let cleaned = cleanBig(big)
check(cleaned.split(separator: "\n").allSatisfy { $0 == "[12:00:00.000] [INFO] hello /Users/<user>/x <ip> <email>" }, "a big text is cleaned line by line across piece boundaries")
let t = Date()
_ = cleanBig(String(repeating: "[xp] 19:10:04.278 +730.16 dt=325 cpu=700 (thr 705) api call rdKB=6320 token ok\n", count: 90_000))
print(String(format: "     6 MB of ordinary lines: %.2f s", Date().timeIntervalSince(t)))
print(failures == 0 ? "all LogCleaner checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
