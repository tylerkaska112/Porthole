import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 } }

// A small log is left alone.
let small = Data((0..<1000).map { "line \($0)" }.joined(separator: "\n").utf8)
check(LogThinner.thin(small).data == small, "a small log is returned unchanged")

// A synthetic big log: app lines, measurements, a noisy tag, a storm of faults with a few important lines, wine err lines, and an ending.
var text = ""
for i in 0..<20 { text += "[18:41:\(String(format: "%02d", i)).123] [INFO] [app] Porthole 1.3.96 start \(i)\n" }
for i in 0..<60_000 {
    text += "[thread-stacks] port=0x\(String(i, radix: 16)) \"worker\" pc=libsystem_kernel.dylib`read+0x8 run=3 susp=0 cpu=0\n"
    if i % 3 == 0 { text += "0198:err:seh:prepare_exception_arm64ec [rtcs] pre: code=c0000005 addr=00000001711C4CA8 armPc=00000001711C4CA8 \(i)\n" }
    if i % 10 == 0 { text += "[xp] 19:10:04.278 +730.16 dt=325 cpu=700 rdKB=\(i) | pres 4/0\n" }
    if i % 500 == 0 { text += "[guest-log] #\(i) tid=0454 Assertion failed: something \(i)\n" }
    if i % 1000 == 0 { text += "[18:42:00.123] [INFO] [telemetry] \(i % 120) fps | 200% cpu | 4.9 GB\n" }
    if i % 7000 == 0 { text += "E 5D0 [callret] RESERVE FAILED crash thread cannot start \(i)\n" }
}
text += "[18:50:00.000] [INFO] [crash] the last line of the log\n"
let big = Data(text.utf8)
let t0 = Date()
let result = LogThinner.thin(big)
let secs = Date().timeIntervalSince(t0)
let out = String(decoding: result.data, as: UTF8.self)
print(String(format: "     %.1f MB -> %.2f MB (%d of %d lines) in %.2f s", Double(big.count) / 1e6, Double(result.data.count) / 1e6, result.linesKept, result.linesIn, secs))
check(result.data.count < big.count / 4, "a log full of repetition shrinks to under a quarter")
check(out.hasPrefix("[... "), "a note on top says what was thinned")
check(out.contains("thread-stacks"), "the note names the most thinned kind")
check(out.components(separatedBy: "[INFO] [app] Porthole").count - 1 == 20, "every app line is kept")
check(out.components(separatedBy: "[xp] ").count - 1 == 6_000, "[xp] lines are kept whole")
check(out.components(separatedBy: "[guest-log] ").count - 1 == 120, "[guest-log] lines are kept whole")
check(out.components(separatedBy: "[INFO] [telemetry]").count - 1 == 60, "[telemetry] lines are kept whole")
check(out.hasSuffix("the last line of the log\n"), "the last line stays")
let stacks = out.components(separatedBy: "thread-stacks] port").count - 1
check(stacks < 3_000, "the repeated tag is thinned hard (\(stacks) of 60000)")
check(out.components(separatedBy: "thread-stacks] port").count - 1 >= 150, "its first lines stay")
check(out.contains("RESERVE FAILED crash thread cannot start 0"), "the first important line stays")
let faults = out.components(separatedBy: "0198:err:seh").count - 1
check(faults >= 150 && faults < 2_500, "a storm of fault lines keeps its beginning and a thin sample (\(faults) of 20000)")

if let path = ProcessInfo.processInfo.environment["LOG_THINNER_FILE"], let real = try? Data(contentsOf: URL(fileURLWithPath: path)) {
    let t1 = Date()
    let r = LogThinner.thin(real)
    print(String(format: "real log: %.1f MB -> %.2f MB (%d of %d lines) in %.2f s", Double(real.count) / 1e6, Double(r.data.count) / 1e6, r.linesKept, r.linesIn, Date().timeIntervalSince(t1)))
}
print(failures == 0 ? "all LogThinner checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
