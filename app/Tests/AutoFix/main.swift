import Foundation

var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let dir = CommandLine.arguments[1]
func evidence(_ id: Int) -> AutoFix.Evidence { AutoFix.scan(file: URL(fileURLWithPath: "\(dir)/\(id >= 1000 ? "p\(id - 1000)" : "r\(id)").log")) }
func ids(_ rules: [AutoFix.Rule]) -> [String] { rules.map(\.id) }

// The most generous situation: the run ended both ways, no swap, plenty of storage. A rule that still does not match a log never will.
let generous = AutoFix.Context(ending: .init(endedUnexpectedly: true, stoppedByPerson: true, endedEarly: true), swapMB: 0, freeStorageMB: 100_000, deviceMemoryMB: 6000, configText: "", largeAddressAllowed: false)

do {   // every log that was sent in (compat reports r<id>, problem reports p<id> = 1000 + id): exactly the rules that were found by reading them
    // What reading each log gives under the most generous situation (see `generous`), reviewed by hand: the AVX crashes of #139 and #146; the memory kills (#99 R.E.P.O., #109, #116, #149, #156, #158,
    // #167, #173, #180, #181 and problem #33 are rated broken or playable; #130 (rated great) has the same warnings, so the rule only changes a game whose run ENDED badly, which the
    // context says); the emulator's pool filled with copies of images (#101, #162, problems #32 and #33); and the installs that cannot reserve the emulator's address space.
    let expected: [Int: [String]] = [99: ["unity-texture-saver", "memory-swap"], 101: ["pool-image-copies"], 108: ["address-space-entitlement"], 109: ["address-space-entitlement", "unity-texture-saver", "memory-swap"], 112: ["address-space-entitlement"], 116: ["unity-texture-saver", "memory-swap"], 117: ["address-space-entitlement"], 130: ["memory-swap"], 139: ["avx-needed"], 143: ["address-space-entitlement"], 144: ["address-space-entitlement"], 145: ["address-space-entitlement"], 146: ["avx-needed"], 149: ["unity-texture-saver", "memory-swap"], 152: ["address-space-entitlement"], 156: ["address-space-entitlement", "unity-texture-saver", "memory-swap"], 158: ["unity-texture-saver", "memory-swap"], 161: ["address-space-entitlement"], 162: ["pool-image-copies"], 163: ["address-space-entitlement"], 167: ["memory-swap"], 173: ["unity-texture-saver", "memory-swap"], 179: ["address-space-entitlement"], 180: ["memory-swap"], 181: ["memory-swap"], 182: ["address-space-entitlement"], 1032: ["pool-image-copies", "pool-code-buffers-low"], 1033: ["pool-image-copies", "memory-swap"]]
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    let all = files.compactMap { name -> Int? in
        guard name.hasSuffix(".log"), let n = Int(name.dropFirst().dropLast(4)) else { return nil }
        return name.hasPrefix("r") ? n : name.hasPrefix("p") ? 1000 + n : nil
    }.sorted()
    check(all.count == 95, "95 logs are in the fixtures (\(all.count))")
    for id in all {
        let found = ids(AutoFix.matches(evidence(id), context: generous))
        check(found == (expected[id] ?? []), "\(id >= 1000 ? "problem #\(id - 1000)" : "report #\(id)"): \(found.isEmpty ? "no rule" : found.joined(separator: ", "))")
    }
}

do {   // FINAL FANTASY RESONANCE (problem #32): the sound library could not be copied into a pool its own code buffers had filled
    let ev = evidence(1032)
    let ended = AutoFix.Context(ending: .init(endedUnexpectedly: true))
    check(AutoFix.decide(ev, context: ended, tried: [])?.id == "pool-image-copies", "pool-low: a game without the first line is offered that one first")
    // The game already has the first line from its known fixes (the store adds those to the context's text), so only the second rule is left.
    let known = AutoFix.Context(ending: .init(endedUnexpectedly: true), configText: "env.MADEIRA_X64_IMAGE_NOCOPY = 1\npool-split = 1")
    let rule = AutoFix.decide(ev, context: known, tried: [])
    check(rule?.id == "pool-code-buffers-low", "pool-low: a game that already has the first line is offered the code-buffer region (\(rule?.id ?? "nothing"))")
    check(rule?.change == .config(key: "pool-low", line: "pool-low = 1"), "pool-low: the change is the one line, `pool-low = 1`")
    check(AutoFix.decide(ev, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), configText: "env.MADEIRA_X64_IMAGE_NOCOPY = 1\npool-low = 0"), tried: []) == nil, "pool-low: a line the person set is never overruled")
    check(AutoFix.decide(ev, context: known, tried: ["pool-code-buffers-low"]) == nil, "pool-low: once tried, it is not offered again")
    check(AutoFix.decide(ev, context: AutoFix.Context(ending: .init(), configText: "env.MADEIRA_X64_IMAGE_NOCOPY = 1"), tried: []) == nil, "pool-low: a run that ended normally changes nothing")
    var healthy = AutoFix.Evidence()
    healthy.counts["no JIT-pool copy for executable section"] = 1          // the first line of the failure without the second: not this failure
    check(AutoFix.decide(healthy, context: known, tried: []) == nil, "pool-low: both lines of the failure are needed")
}

do {   // the AVX rule needs both lines, and nothing else about the run
    let lines = ["[x] FEX: HostFeatures=0 (ml538: DISABLEAVX expected; AVX off => Skia takes SSE paths)",
                 "0044:err:seh:UnhandledExceptionFilter [uef] 0059 UnhandledExceptionFilter code=c000001d at 0000000170E525AF: top_filter=1 nested=0"]
    check(ids(AutoFix.matches(AutoFix.scan(lines: lines), context: AutoFix.Context())) == ["avx-needed"], "avx: both lines, any ending: the rule fits")
    check(AutoFix.matches(AutoFix.scan(lines: [lines[0]]), context: AutoFix.Context()).isEmpty, "avx: AVX off but no illegal instruction: no rule")
    check(AutoFix.matches(AutoFix.scan(lines: [lines[1]]), context: AutoFix.Context()).isEmpty, "avx: an illegal instruction with AVX already on: no rule (it is not the switch)")
}

do {   // the memory rule: repeated warnings, and an ending that is a sign of memory, and a device where swap can help
    let warning = "[10:00:00.000] [INFO] [mem-pressure] CRITICAL: app 4915 MB, free 1229 MB, gpu 2401 MB; malloc gave back 0 MB"
    let two = AutoFix.scan(lines: [warning, warning])
    let one = AutoFix.scan(lines: [warning])
    var ctx = AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 0, freeStorageMB: 20_000)
    check(ids(AutoFix.matches(two, context: ctx)) == ["memory-swap"], "memory: two warnings and the app ended: the rule fits")
    check(AutoFix.matches(one, context: ctx).isEmpty, "memory: one warning is normal: no rule")
    check(AutoFix.matches(two, context: AutoFix.Context(ending: .init(), swapMB: 0, freeStorageMB: 20_000)).isEmpty, "memory: the run ended on its own: no rule")
    check(AutoFix.decide(two, context: ctx, tried: [])?.change == .swap(megabytes: 4096, coverage: "wide"), "memory: the change is a 4 GB swap file with coverage wide (1 MB+ and overflow)")
    ctx.ending = .init(stoppedByPerson: true)
    check(ids(AutoFix.matches(two, context: ctx)) == ["memory-swap"], "memory: the person stopped the game: the rule fits")
    ctx.swapMB = 2048; ctx.swapCoverage = "wide"
    check(AutoFix.matches(two, context: ctx).isEmpty, "memory: swap is already on, and wide: no rule")
    ctx.swapMB = 0; ctx.freeStorageMB = 5000
    check(AutoFix.matches(two, context: ctx).isEmpty, "memory: no storage for a 4 GB swap file: no rule")
}

do {   // the pool rule adds a line to the game's text: only after a bad ending, and never over a line the game already has
    let e = AutoFix.scan(lines: ["[jit-pool] EXHAUSTED (image 0x7ff0, 4 MB)"])
    var ctx = AutoFix.Context(ending: .init(endedEarly: true))
    check(AutoFix.decide(e, context: ctx, tried: [])?.change == .config(key: "env.MADEIRA_X64_IMAGE_NOCOPY", line: "env.MADEIRA_X64_IMAGE_NOCOPY = 1"), "pool: a game that ended within minutes: the line is added")
    check(AutoFix.matches(e, context: AutoFix.Context()).isEmpty, "pool: the run ended well: no rule")
    ctx.configText = "swap-mb = 2048\nenv.MADEIRA_X64_IMAGE_NOCOPY = 0"
    check(AutoFix.matches(e, context: ctx).isEmpty, "pool: the game's own text already sets the key (even to 0): not overruled")
    check(AutoFix.hasConfigKey("a = 1\n  env.X = 2 \n", "env.X") && !AutoFix.hasConfigKey("env.XY = 2", "env.X"), "pool: a key is matched whole")
}

do {   // the address-space rule only speaks when the install really lacks the capability
    let e = AutoFix.scan(lines: ["[fex-arena] ml799 constrained 8GB: native reserve FAILED kr=3"])
    check(ids(AutoFix.matches(e, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), largeAddressAllowed: false))) == ["address-space-entitlement"], "address space: an install without the capability, the app ended: the explanation")
    check(AutoFix.matches(e, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), largeAddressAllowed: true)).isEmpty, "address space: an install that has the capability: no explanation (it is not the cause)")
    check(AutoFix.decide(e, context: AutoFix.Context(ending: .init(endedEarly: true), largeAddressAllowed: false), tried: [])?.change == .advice, "address space: the answer changes nothing")
}

do {   // the frame rate of a telemetry line, and the best one of a run
    check(AutoFix.telemetryFPS("[12:00:01.234] [INFO] [telemetry] 59 fps | 70% cpu | 5.9 GB | cool | 90% | free 6212 MB | gpu 3077 MB") == 59, "telemetry: 59 fps is read")
    check(AutoFix.telemetryFPS("[12:00:01.234] [INFO] [telemetry] 0 fps | 12% cpu") == 0, "telemetry: 0 fps is read as 0")
    check(AutoFix.telemetryFPS("[12:00:01.234] [INFO] [clamp-diag] running") == nil && AutoFix.telemetryFPS("[telemetry] fps | x") == nil && AutoFix.telemetryFPS("[telemetry] 123456 fps") == nil, "telemetry: other lines, and nonsense, are nothing")
    let e = AutoFix.scan(lines: ["[telemetry] 0 fps | a", "[telemetry] 31 fps | b", "[telemetry] 60 fps | c", "[telemetry] 12 fps | d"])
    check(e.maxFPS == 60, "telemetry: the best of the run is kept (\(e.maxFPS))")
    // The best frame rate survives being read in pieces.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("autofix-fps-\(getpid()).log")
    try! Data("[telemetry] 5 fps | a\n[telemetry] 44 fps | b\n[telemetry] 9 fps | c\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    check([1, 5, 16, 1000].allSatisfy { AutoFix.scan(file: url, chunk: $0).maxFPS == 44 }, "telemetry: the best frame rate is the same read in pieces of any size")
}

do {   // judging the run after a change
    let avx = AutoFix.rules.first { $0.id == "avx-needed" }!
    let memory = AutoFix.rules.first { $0.id == "memory-swap" }!
    var played = AutoFix.Evidence(); played.maxFPS = 45
    var blank = AutoFix.Evidence()
    check(AutoFix.judge(avx, evidence: played, duration: 600, endedBadly: false) == .worked, "judge: ten minutes at 45 fps: it worked")
    check(AutoFix.judge(avx, evidence: played, duration: 200, endedBadly: false) == .unclear, "judge: a short run that drew frames: unclear, nothing claimed")
    check(AutoFix.judge(avx, evidence: blank, duration: 40, endedBadly: true) == .failed, "judge: ended within a minute and never drew a frame: failed")
    check(AutoFix.judge(avx, evidence: played, duration: 90, endedBadly: true) == .unclear, "judge: ended early but had been drawing, with another cause: unclear, kept")
    // the same cause again
    blank.counts["[mem-pressure] CRITICAL"] = 4
    played.counts["[mem-pressure] CRITICAL"] = 4
    check(AutoFix.judge(memory, evidence: played, duration: 400, endedBadly: true) == .unclear, "judge: a long run that ended badly with the warnings again: unclear (it ran longer than a crash)")
    check(AutoFix.judge(memory, evidence: played, duration: 100, endedBadly: true) == .failed, "judge: ended early with the same warnings again: failed")
    check(AutoFix.judge(memory, evidence: played, duration: 900, endedBadly: false) == .worked, "judge: warnings again but it ran 15 minutes and ended well: worked")
    check(AutoFix.evidencePresent(memory, blank) && !AutoFix.evidencePresent(memory, AutoFix.Evidence()), "judge: the cause is shown again when the warnings are there (twice, as the rule asks)")
    blank.counts["[mem-pressure] CRITICAL"] = 1
    check(!AutoFix.evidencePresent(memory, blank), "judge: one warning is not the cause")
}

do {   // the Hub's list: what is read, what is refused, what is switched off
    func doc(_ json: String) -> Data { Data(json.utf8) }
    let builtIn = AutoFix.builtIn
    let pool = #"{"id":"pool-note","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED (image"],"endings":["early"],"change":{"kind":"config","key":"env.MADEIRA_X64_IMAGE_NOCOPY","line":"env.MADEIRA_X64_IMAGE_NOCOPY = 1"}}"#
    let r = AutoFixRemote.read(doc(#"{"schema":1,"rules":["# + pool + "]}"), builtIn: builtIn, build: 740)
    check(r != nil && r!.used == ["pool-note"] && r!.set.rules.count == builtIn.count + 1 && r!.rejected.isEmpty, "remote: a new rule is added after the built-in ones")
    let off = AutoFixRemote.read(doc(#"{"schema":1,"disabled":["memory-swap","pool-note"],"rules":["# + pool + "]}"), builtIn: builtIn, build: 740)!
    check(!off.set.rules.contains { $0.id == "memory-swap" } && !off.set.rules.contains { $0.id == "pool-note" } && off.set.rules.count == builtIn.count - 1, "remote: the kill switch turns off a built-in rule and a published one")
    check(AutoFixRemote.read(doc(#"{"schema":2,"rules":[]}"#), builtIn: builtIn, build: 740) == nil && AutoFixRemote.read(doc("{ nope"), builtIn: builtIn, build: 740) == nil, "remote: another schema, or not JSON: not used at all")
    check(AutoFixRemote.read(Data(count: 70_000), builtIn: builtIn, build: 740) == nil, "remote: a document over 64 KB is refused")
    let replaced = AutoFixRemote.read(doc(#"{"schema":1,"rules":[{"id":"memory-swap","title":"T2","reason":"R","done":"D","all":["[mem-pressure] CRITICAL"],"endings":["unexpected"],"change":{"kind":"swap","megabytes":6144,"coverage":"wide"}}]}"#), builtIn: builtIn, build: 740)!
    check(replaced.set.rules.count == builtIn.count && replaced.set.rules.first { $0.id == "memory-swap" }?.change == .swap(megabytes: 6144, coverage: "wide") && replaced.set.rules.map(\.id) == builtIn.map(\.id), "remote: a rule with a built-in id replaces it and keeps its place")
    check(AutoFixRemote.read(doc(#"{"schema":1,"rules":["# + pool.replacingOccurrences(of: #"{"id":"pool-note""#, with: #"{"id":"pool-note","minBuild":900"#) + "]}"), builtIn: builtIn, build: 740)!.used.isEmpty, "remote: a rule for newer builds is not used by this one")
    check(AutoFixRemote.read(doc(#"{"schema":1,"rules":["# + pool.replacingOccurrences(of: #"{"id":"pool-note""#, with: #"{"id":"pool-note","maxBuild":739"#) + "]}"), builtIn: builtIn, build: 740)!.used.isEmpty, "remote: a rule that stopped at an older build is not used (the app's own fix is out)")
    // refused rules: each leaves the others alone
    let bad = [
        #"{"id":"x1","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"change":{"kind":"config","key":"env.MADEIRA_X","line":"env.MADEIRA_X = 1; rm"}}"#,
        #"{"id":"x2","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"change":{"kind":"config","key":"swap-mb","line":"swap-mb = 9"}}"#,
        #"{"id":"x3","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"change":{"kind":"swap","megabytes":99999}}"#,
        #"{"id":"x4","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"change":{"kind":"deleteGame"}}"#,
        #"{"id":"X5","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"change":{"kind":"avx"}}"#,
        #"{"id":"x6","title":"T","reason":"R","done":"D","all":["ab"],"change":{"kind":"avx"}}"#,
        #"{"id":"x7","title":"T","reason":"R","done":"D","change":{"kind":"avx"}}"#,
        #"{"id":"x8","title":"T","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"endings":["always"],"change":{"kind":"avx"}}"#,
        #"{"id":"x9","title":"","reason":"R","done":"D","all":["[jit-pool] EXHAUSTED"],"change":{"kind":"avx"}}"#,
    ]
    let mixed = AutoFixRemote.read(doc(#"{"schema":1,"rules":["# + bad.joined(separator: ",") + "," + pool + "]}"), builtIn: builtIn, build: 740)!
    check(mixed.used == ["pool-note"] && mixed.rejected.count == bad.count, "remote: \(bad.count) harmful or malformed rules are refused, the good one is used (\(mixed.rejected.count) refused)")
    // a published rule works like a built-in one
    let e = AutoFix.scan(lines: ["[jit-pool] EXHAUSTED (image 0x1)"])
    AutoFix.install(r!.set)
    defer { AutoFix.install(nil) }
    let ev = AutoFix.scan(lines: ["[jit-pool] EXHAUSTED (image 0x1)", "[jit-pool] EXHAUSTED (image 0x2)"])
    check(AutoFix.decide(ev, context: AutoFix.Context(ending: .init(endedEarly: true)), tried: [])?.id == "pool-image-copies", "remote: the built-in rule still comes first when both fit")
    check(AutoFix.decide(ev, context: AutoFix.Context(ending: .init(endedEarly: true)), tried: ["pool-image-copies"])?.id == "pool-note", "remote: the published rule takes over when the built-in one was tried")
    check(AutoFix.decide(ev, context: AutoFix.Context(ending: .init(endedEarly: true), configText: "env.MADEIRA_X64_IMAGE_NOCOPY = 0"), tried: ["pool-image-copies"]) == nil, "remote: a published config rule does not overrule the game's own line")
    _ = e
    // swap rules from the Hub are held to the same conditions as the built-in one
    let swap = AutoFixRemote.read(doc(#"{"schema":1,"disabled":["memory-swap"],"rules":[{"id":"swap-hub","title":"T","reason":"R","done":"D","all":["[mem-pressure] CRITICAL"],"endings":["unexpected"],"change":{"kind":"swap","megabytes":4096}}]}"#), builtIn: builtIn, build: 740)!
    AutoFix.install(swap.set)
    let mem = AutoFix.scan(lines: ["[mem-pressure] CRITICAL a", "[mem-pressure] CRITICAL b"])
    check(AutoFix.decide(mem, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 0, freeStorageMB: 20_000), tried: [])?.id == "swap-hub", "remote: a published swap rule fits a device with room")
    check(AutoFix.decide(mem, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 0, freeStorageMB: 5_000), tried: []) == nil, "remote: ... and not one with too little storage (the size plus 2 GB)")
    check(AutoFix.decide(mem, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 2048, swapCoverage: "wide", freeStorageMB: 20_000), tried: []) == nil, "remote: ... and not one that has swap already")
    AutoFix.install(nil)
    check(AutoFix.rules.count == builtIn.count, "remote: installing nothing brings the built-in rules back")
}

do {   // swap on but hardly used: the coverage is widened (the swap file stays as it is)
    func ctx(swap: Int, coverage: String, unexpected: Bool = true) -> AutoFix.Context { AutoFix.Context(ending: .init(endedUnexpectedly: unexpected), swapMB: swap, swapCoverage: coverage, freeStorageMB: 50_000) }
    // three real logs where swap was on with the classic coverage, memory ran out, and the swap file held 0 to 1.3 GB of its 2 to 4 GB: the same rule, not the "turn swap on" one
    for (id, swap) in [(149, 4096), (156, 2048), (180, 4096)] {
        let found = AutoFix.matches(evidence(id), context: ctx(swap: swap, coverage: "")).map(\.id).filter { $0 != "unity-texture-saver" }
        check(found == ["memory-swap-coverage"], "swap coverage: report #\(id) (swap \(swap) MB, classic coverage) gets the coverage rule, not the turn-swap-on one (\(found))")
    }
    let e = evidence(149)
    check(AutoFix.decide(e, context: ctx(swap: 4096, coverage: ""), tried: ["unity-texture-saver"])?.change == .swapCoverage("wide"), "swap coverage: the change is only the coverage, wide")
    check(!AutoFix.matches(e, context: ctx(swap: 4096, coverage: "wide")).contains { $0.id.hasPrefix("memory-swap") }, "swap coverage: already wide: no swap rule")
    check(!AutoFix.matches(e, context: ctx(swap: 4096, coverage: "blocks")).contains { $0.id.hasPrefix("memory-swap") } && !AutoFix.matches(e, context: ctx(swap: 4096, coverage: "broad")).contains { $0.id.hasPrefix("memory-swap") }, "swap coverage: a person's own choice of another coverage is left alone")
    let plain = AutoFix.scan(lines: ["[mem-pressure] CRITICAL a", "[mem-pressure] CRITICAL b"])
    check(AutoFix.matches(plain, context: ctx(swap: 4096, coverage: "", unexpected: false)).isEmpty, "swap coverage: a run that ended on its own: no rule")
    check(AutoFix.matches(e, context: ctx(swap: 0, coverage: "")).map(\.id) == ["unity-texture-saver", "memory-swap"], "swap coverage: with swap off the other swap rule (turn it on) is the one")
}

do {   // the Unity texture saver
    let unity = AutoFix.scan(lines: ["D 38 Load module UnityPlayer.dll (unityplayer.dll-aa): 7000", "[mem-pressure] CRITICAL a", "[mem-pressure] CRITICAL b"])
    let notUnity = AutoFix.scan(lines: ["[mem-pressure] CRITICAL a", "[mem-pressure] CRITICAL b"])
    let bad = AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 4096, swapCoverage: "wide", freeStorageMB: 50_000)
    check(AutoFix.decide(unity, context: bad, tried: [])?.change == .config(key: "env.MADEIRA_MIP_CLAMP_AUTO", line: "env.MADEIRA_MIP_CLAMP_AUTO = 1"), "unity: a Unity game that ran out of memory gets the texture saver")
    check(AutoFix.decide(notUnity, context: bad, tried: []) == nil, "unity: a game that is not Unity does not (Devil May Cry 5 and Castle Crashers log the same warnings and run well)")
    var has = bad; has.configText = "env.MADEIRA_MIP_CLAMP_AUTO = 0"
    check(AutoFix.decide(unity, context: has, tried: []) == nil, "unity: the game's own line is not overruled")
    check(AutoFix.decide(unity, context: AutoFix.Context(swapMB: 4096, swapCoverage: "wide"), tried: []) == nil, "unity: a run that ended well: nothing")
    check(AutoFix.decide(unity, context: bad, tried: ["unity-texture-saver"]) == nil, "unity: once per game")
}

do {   // a rule is tried once per game
    let e = evidence(139)
    check(AutoFix.decide(e, context: generous, tried: [])?.id == "avx-needed", "decide: the rule is chosen")
    check(AutoFix.decide(e, context: generous, tried: ["avx-needed"]) == nil, "decide: a rule already tried for the game is not chosen again")
    check(AutoFix.decide(evidence(165), context: generous, tried: []) == nil, "decide: a log with no known cause gets no fix")
}

do {   // reading a file in small pieces gives what reading it whole does, with the needle cut by a piece boundary, a missing last newline and bytes that are not text
    let line = "UnhandledExceptionFilter code=c000001d"
    var data = Data()
    data.append(contentsOf: Array("DISABLEAVX expected\n".utf8))
    data.append(contentsOf: [0xff, 0xfe, 0x0a])
    data.append(contentsOf: Array((line).utf8))     // no newline at the end
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("autofix-\(getpid()).log")
    try! data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let whole = AutoFix.scan(file: url)
    check(whole.count("DISABLEAVX expected") == 1 && whole.count(line) == 1, "file: both lines counted")
    for chunk in [1, 3, 7, 19, 20, 21, 64] {
        check(AutoFix.scan(file: url, chunk: chunk) == whole, "file: pieces of \(chunk) bytes give the same counts")
    }
    check(AutoFix.scan(file: URL(fileURLWithPath: "/nonexistent/autofix.log")) == AutoFix.Evidence(), "file: a missing file is no evidence")
}

do {   // the Hub can say what the built-in Unity and swap-coverage rules say: the same answers on every real log, in the same situations
    let json = #"{"schema":1,"rules":[{"id":"unity-texture-saver","title":"T","reason":"R","done":"D","all":["Load module UnityPlayer.dll","[mem-pressure] CRITICAL"],"atLeast":{"[mem-pressure] CRITICAL":2},"endings":["unexpected","stopped"],"change":{"kind":"config","key":"env.MADEIRA_MIP_CLAMP_AUTO","line":"env.MADEIRA_MIP_CLAMP_AUTO = 1"}},{"id":"memory-swap-coverage","title":"T","reason":"R","done":"D","all":["[mem-pressure] CRITICAL"],"atLeast":{"[mem-pressure] CRITICAL":2},"endings":["unexpected","stopped"],"change":{"kind":"swapCoverage","coverage":"wide"}}]}"#
    let read = AutoFixRemote.read(Data(json.utf8), builtIn: AutoFix.builtIn, build: 800)
    check(read != nil && read!.rejected.isEmpty && read!.used == ["unity-texture-saver", "memory-swap-coverage"], "hub copy: a Unity rule and a swap-coverage rule are accepted")
    let contexts: [AutoFix.Context] = [
        AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 0, freeStorageMB: 50_000),
        AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 4096, swapCoverage: "", freeStorageMB: 50_000),
        AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 4096, swapCoverage: "wide", freeStorageMB: 50_000),
        AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 2048, swapCoverage: "blocks", freeStorageMB: 50_000, configText: "env.MADEIRA_MIP_CLAMP_AUTO = 0"),
        AutoFix.Context(ending: .init(endedEarly: true), swapMB: 4096, swapCoverage: "", freeStorageMB: 50_000)]
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name -> Int? in
        guard name.hasSuffix(".log"), let n = Int(name.dropFirst().dropLast(4)) else { return nil }
        return name.hasPrefix("p") ? 1000 + n : n
    }
    var same = true, compared = 0
    for id in ids {
        let ev = evidence(id)
        for ctx in contexts {
            AutoFix.install(nil)
            let own = AutoFix.matches(ev, context: ctx).map(\.id)
            AutoFix.install(read!.set)
            let hub = AutoFix.matches(ev, context: ctx).map(\.id)
            AutoFix.install(nil)
            compared += 1
            if own != hub { same = false; print("  differs: #\(id): built-in \(own) hub \(hub)") }
        }
    }
    check(same && compared > 100, "hub copy: \(compared) log and situation pairs give the same rules as the built-in ones")
    AutoFix.install(read!.set)
    let widen = AutoFix.matches(evidence(149), context: contexts[1]).first { $0.id == "memory-swap-coverage" }
    check(widen?.change == .swapCoverage("wide"), "hub copy: the published coverage rule widens to wide")
    AutoFix.install(nil)
    let own = #"{"id":"c1","title":"T","reason":"R","done":"D","all":["[mem-pressure] CRITICAL"],"change":{"kind":"swapCoverage","coverage":"everything"}}"#
    check(AutoFixRemote.read(Data(("{\"schema\":1,\"rules\":[" + own + "]}").utf8), builtIn: AutoFix.builtIn, build: 800)!.rejected.count == 1, "hub copy: an unknown coverage is refused")
}

do {   // what the Hub switched off is known to the other fixes too (tested setup, community settings, program repair are not log rules)
    let off = AutoFixRemote.read(Data(#"{"schema":1,"disabled":["tested-setup","program-moved","unity-texture-saver"],"rules":[]}"#.utf8), builtIn: AutoFix.builtIn, build: 800)!
    AutoFix.install(off.set)
    check(AutoFix.isDisabled("tested-setup") && AutoFix.isDisabled("program-moved") && !AutoFix.isDisabled("community-settings"), "switched off: the Hub's list names exactly the fixes that are off")
    check(!AutoFix.rules.contains { $0.id == "unity-texture-saver" } && AutoFix.rules.contains { $0.id == "memory-swap" }, "switched off: a log rule that is off is not used, the others are")
    AutoFix.install(nil)
    check(!AutoFix.isDisabled("tested-setup") && AutoFix.rules.contains { $0.id == "unity-texture-saver" }, "switched off: without a list nothing is off")
}

do {   // what a run says about itself (LastRun)
    let failedLine = #"[10:33:21.502 PM] [INFO] [launch-screen] shown: state=failed("File not found: C:\\Program Files (x86)\\Steam\\steamapps\\common\\Ranch Simulator\\mulator\\Ranch_Simulator.exe. Remove this entry and add the game again with +.") gameUp=false peeking=false game=Ranch Simulator"#
    let e = AutoFix.scan(lines: ["[x] something else", failedLine, #"[y] [launch-screen] shown: state=failed("A second one") gameUp=false"#])
    check(e.count(LastRun.launchFailedLine) == 2, "last run: both launch failures are counted")
    check(LastRun.launchFailure(in: e) == #"File not found: C:\Program Files (x86)\Steam\steamapps\common\Ranch Simulator\mulator\Ranch_Simulator.exe. Remove this entry and add the game again with +."#, "last run: the first one's text is kept, quotes and backslashes put right (\(LastRun.launchFailure(in: e) ?? "nil"))")
    check(LastRun.launchFailure(in: AutoFix.scan(lines: ["nothing here"])) == nil, "last run: no failure line, no text")
    var merged = AutoFix.scan(lines: [#"[a] [launch-screen] shown: state=failed("first") gameUp=false"#])
    merged.merge(AutoFix.scan(lines: [#"[b] [launch-screen] shown: state=failed("second") gameUp=false"#]))
    check(LastRun.launchFailure(in: merged) == "first", "last run: merging pieces of a log keeps the first failure")

    let none = AutoFix.Evidence()
    let w1 = LastRun.words(evidence: e, end: .early, minutes: 0, matched: [], swapMB: 0, swapCoverage: "")
    check(w1.headline == "It could not start." && w1.details.count == 1 && w1.details[0].hasPrefix("File not found:"), "last run: a game that could not start says so and why")
    let w2 = LastRun.words(evidence: none, end: .normal, minutes: 42, matched: [], swapMB: 0, swapCoverage: "")
    check(w2.headline == "It ended after 42 minutes." && w2.details.isEmpty, "last run: a normal end says how long, and nothing else")
    var fast = AutoFix.Evidence(); fast.maxFPS = 59
    check(LastRun.words(evidence: fast, end: .normal, minutes: 1, matched: [], swapMB: 0, swapCoverage: "").details == ["The best frame rate it showed was 59."], "last run: the best frame rate of a normal run")
    let w3 = LastRun.words(evidence: none, end: .crashed, minutes: 7, matched: [], swapMB: 0, swapCoverage: "")
    check(w3.headline == "Porthole was closed while the game ran, 7 minutes in." && w3.details == ["The log shows no known cause. Share it from here, or send a report from the game's page."], "last run: an end with no known cause says so")
    check(LastRun.words(evidence: none, end: .stopped, minutes: 0, matched: [], swapMB: 0, swapCoverage: "").headline == "The game was stopped while it was starting.", "last run: a stop while starting")
    check(LastRun.words(evidence: none, end: .early, minutes: 0, matched: [], swapMB: 0, swapCoverage: "").headline == "It ended after less than a minute, before it got going.", "last run: under a minute")
    // a real log: Unity game, memory warnings, iOS ended the app
    let real = evidence(149)
    let matched = AutoFix.matches(real, context: AutoFix.Context(ending: .init(endedUnexpectedly: true), swapMB: 0, freeStorageMB: 50_000))
    let w4 = LastRun.words(evidence: real, end: .crashed, minutes: 12, matched: matched, swapMB: 0, swapCoverage: "")
    check(!matched.isEmpty && matched.allSatisfy { w4.details.contains($0.reason) }, "last run: report #149: every matching rule's reason is told")
    // memory warnings with no memory rule matching (swap already on): the warnings and the swap state are told
    var warned = AutoFix.Evidence(); warned.counts["[mem-pressure] CRITICAL"] = 3
    let w5 = LastRun.words(evidence: warned, end: .crashed, minutes: 5, matched: [], swapMB: 4096, swapCoverage: "wide")
    check(w5.details == ["iOS warned 3 times that memory was almost full. Swap is 4 GB (coverage wide)."], "last run: memory warnings with swap on (\(w5.details))")
    let w6 = LastRun.words(evidence: warned, end: .normal, minutes: 90, matched: [], swapMB: 0, swapCoverage: "")
    check(w6.details.isEmpty, "last run: memory warnings in a run that ended normally are not blamed")
    let w7 = LastRun.words(evidence: warned, end: .crashed, minutes: 5, matched: [], swapMB: 0, swapCoverage: "", installNote: "NOTE")
    check(w7.details.last == "NOTE", "last run: the install's note (no extra memory) follows a bad end with memory warnings (\(w7.details))")
    let w8 = LastRun.words(evidence: none, end: .normal, minutes: 5, matched: [], swapMB: 0, swapCoverage: "", installNote: "NOTE")
    check(!w8.details.contains("NOTE"), "last run: the install's note is not told for a run that ended normally")
    let w9 = LastRun.words(evidence: none, end: .stopped, minutes: 0, matched: [], swapMB: 0, swapCoverage: "", installNote: "NOTE")
    check(!w9.details.contains("NOTE"), "last run: nor when the person stopped it")
    // the memory line of the run is told in words, with what helps when the run ended badly
    var heavy = AutoFix.Evidence(); heavy.captures["[mem-summary]"] = "[2026] [INFO] [mem-summary] 12 min: peak app 5900 MB, peak gpu 1800 MB, least free 120 MB; 40 s under 1 GB free"
    check(LastRun.memorySummary(in: heavy) == LastRun.MemorySummary(appMB: 5900, gpuMB: 1800, freeMB: 120), "last run: the memory line is read")
    let wm = LastRun.words(evidence: heavy, end: .crashed, minutes: 12, matched: [], swapMB: 4096, swapCoverage: "wide")
    check(wm.details.contains { $0.hasPrefix("The game used up to 5.8 GB of memory (graphics up to 1.8 GB).") && $0.contains("Close other apps") }, "last run: a heavy run that ended badly says how much it used and what helps (\(wm.details))")
    let wn = LastRun.words(evidence: heavy, end: .normal, minutes: 90, matched: [], swapMB: 0, swapCoverage: "")
    check(wn.details == ["The game used up to 5.8 GB of memory (graphics up to 1.8 GB)."], "last run: a heavy run that ended normally says only how much it used (\(wn.details))")
    var light = AutoFix.Evidence(); light.captures["[mem-summary]"] = "[mem-summary] 3 min: peak app 900 MB, peak gpu 100 MB, least free 3000 MB; 0 s"
    check(LastRun.words(evidence: light, end: .normal, minutes: 3, matched: [], swapMB: 0, swapCoverage: "").details.isEmpty, "last run: a light game's memory is not mentioned")
    check(AutoFix.RuleSet(AutoFix.builtIn).needles.contains(LastRun.memorySummaryLine), "last run: the scan looks for the memory summary line")
    check(AutoFix.RuleSet(AutoFix.builtIn).needles.contains(LastRun.launchFailedLine), "last run: the scan looks for the launch failure line")
}

do {
    check(AutoFix.proposal(for: .avx) == "Turn AVX and AVX2 on for this game.", "ask first: AVX is worded as something to turn on")
    check(AutoFix.proposal(for: .swap(megabytes: 4096, coverage: "wide")).contains("4 GB swap file"), "ask first: swap names its size")
    check(AutoFix.proposal(for: .swap(megabytes: 1536, coverage: "wide")).contains("1536 MB"), "ask first: a size that is not whole GB is said in MB")
    check(AutoFix.proposal(for: .config(key: "k", line: "env.X = 1")).hasSuffix("env.X = 1"), "ask first: an engine line is shown as it will be written")
    check(AutoFix.proposal(for: .advice).isEmpty, "ask first: advice changes nothing, so there is nothing to ask")
    let everyRule = AutoFix.builtIn.filter { $0.change != .advice }
    check(everyRule.allSatisfy { !AutoFix.proposal(for: $0.change).isEmpty }, "ask first: every built-in rule that changes a setting can say what it will do")
}

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
