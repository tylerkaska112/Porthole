import Foundation
// Run: app/Tests/Engine/run.sh
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

@main struct Tests { static func main() { run(); exit(failures == 0 ? 0 : 1) } }

func run() {
    // Everything below writes under the home folder (madeira.cfg, the Wine drive): refuse to run against a real one.
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    guard docs.contains("/home/") && NSTemporaryDirectory().count > 0 && !docs.hasPrefix("/Users/") else { print("FAIL  the test is not using a scratch home folder (\(docs)); refusing to run"); exit(1) }
    check(true, "the test runs with a scratch home folder")
    try! FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)   // on a device Documents always exists

    // MARK: per-game settings
    var g = Game(exe: "C:\\Games\\Foo\\foo.exe", args: "-windowed")
    check(g.engine == nil && GameEngine().isEmpty, "a game starts with no engine settings, and an empty GameEngine is empty")
    var e = GameEngine(); e.avx = true; e.cpuCount = 4; e.binds = ["A": "key-E"]; e.config = "env.MADEIRA_FEX_AVX = 1"
    g.engine = e
    let data = try! JSONEncoder().encode(g)
    let back = try! JSONDecoder().decode(Game.self, from: data)
    check(back == g && back.engine?.binds?["A"] == "key-E", "a game's engine settings survive being saved and loaded")
    let old = try! JSONDecoder().decode(Game.self, from: Data(#"{"exe":"C:\\a.exe","args":""}"#.utf8))
    check(old.engine == nil, "a library saved before engine settings existed still loads (no engine field)")

    // MARK: graphics route (Vulkan) and the benchmark summary
    do {
        var r = GameEngine(); r.d3d11Route = "dxvk"; r.d3d12Route = "vkd3d"; r.vulkanLibrary = "kosmickrisp"
        check(!r.isEmpty && GameEngine().d3d11Route == nil, "the graphics route fields start empty (the normal route) and count as a setting once chosen")
        var rg = Game(exe: "C:\\Games\\Foo\\foo.exe"); rg.engine = r
        let back2 = try! JSONDecoder().decode(Game.self, from: JSONEncoder().encode(rg))
        check(back2.engine?.d3d11Route == "dxvk" && back2.engine?.d3d12Route == "vkd3d" && back2.engine?.vulkanLibrary == "kosmickrisp", "a game's graphics route survives being saved and loaded")
        let text = EngineLaunch.summary(for: rg)
        check(text.contains("d3d11=dxvk") && text.contains("d3d12=vkd3d") && text.contains("vulkan=kosmickrisp"), "the benchmark line names the routes in effect (\(text))")
        let plain = EngineLaunch.summary(for: Game(exe: "C:\\a.exe"))
        check(plain.contains("d3d11=dxmt") && plain.contains("d3d12=madeira-d3d12") && plain.contains("upscale=off") && plain.contains("framegen=off"), "and the normal route when nothing is chosen (\(plain))")
    }

    // MARK: backup file names
    do {
        let s = SaveBackup.fileStamp(Date(timeIntervalSince1970: 86400 * 365))
        check(s.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, "a backup's time stamp reads yyyy-MM-dd_HH-mm-ss without the date formatter (\(s))")
    }

    // MARK: DXMT options
    check(EngineLaunch.dxmtConfig(nil, nil) == "", "no dxmt lines give no DXMT_CONFIG")
    check(EngineLaunch.dxmtConfig("d3d11.mipClampBC=1; d3d11.preferredMaxFrameRate=30", nil) == "d3d11.mipClampBC=1;d3d11.preferredMaxFrameRate=30", "the app's dxmt options are joined with ;")
    check(EngineLaunch.dxmtConfig("a=1", "b=2;#note;c=3") == "a=1;b=2;c=3", "the game's options come after the app's and comments are dropped")
    check(EngineLaunch.dxmtConfig("a=1\nb=2", "") == "a=1;b=2", "a new line separates options like ;")
    do {
        let ge = GameEngine(config: "dxmt = d3d11.mipClampBC=2")
        var dg = Game(exe: "C:\\a.exe"); dg.engine = ge
        unsetenv("DXMT_CONFIG")
        EngineLaunch.apply(for: dg)
        check(String(cString: getenv("DXMT_CONFIG") ?? strdup("")) == "d3d11.mipClampBC=2", "a game's dxmt line reaches DXMT_CONFIG at launch")
        EngineLaunch.apply(for: Game(exe: "C:\\b.exe"))
        check(getenv("DXMT_CONFIG") == nil, "a game with no dxmt line unsets what an earlier game exported")
    }

    // MARK: launch
    setenv("MADEIRA_FEX_AVX", "1", 1); setenv("MADEIRA_FRAMEGEN", "1", 1)   // left over from an earlier game
    EngineLaunch.apply(for: Game(exe: "C:\\a.exe"))
    check(getenv("MADEIRA_FEX_AVX") == nil && getenv("MADEIRA_FRAMEGEN") == nil && getenv("MADEIRA_CPU_COUNT") == nil, "a game with no engine settings unsets what an earlier game exported")
    EngineLaunch.apply(for: g)
    check(String(cString: getenv("MADEIRA_FEX_AVX")!) == "1" && String(cString: getenv("MADEIRA_CPU_COUNT")!) == "4" && getenv("MADEIRA_FRAMEGEN") == nil, "a game's AVX and CPU count are exported, frame generation stays off")
    let gameCfg = MadeiraConfig.gameURL!
    check((try? String(contentsOf: gameCfg, encoding: .utf8))?.contains("env.MADEIRA_FEX_AVX") == true && getenv("MADEIRA_CFG_GAME") != nil, "the game's own lines are written and named by MADEIRA_CFG_GAME")
    EngineLaunch.apply(for: Game(exe: "C:\\a.exe"))
    check(getenv("MADEIRA_CFG_GAME") == nil && !FileManager.default.fileExists(atPath: gameCfg.path), "the next game without lines removes them")

    check(EngineLaunch.batchCommand(for: Game(exe: "C:\\Games\\run.bat", args: "-x"))?.args == "/c \"C:\\Games\\run.bat\" -x" && EngineLaunch.batchCommand(for: Game(exe: "C:\\Games\\run.CMD"))?.exe == "C:\\windows\\system32\\cmd.exe", "a .bat or .cmd runs through cmd.exe")
    check(EngineLaunch.batchCommand(for: Game(exe: "C:\\Games\\foo.exe")) == nil, "an ordinary program is not wrapped")
    var w = Game(exe: "C:\\a.exe"); w.engine = GameEngine(workDir: "C:\\Games\\Foo")
    check(EngineLaunch.workDir(for: w) == "C:\\Games\\Foo", "a C:\\ working folder is used")
    w.engine = GameEngine(workDir: "D:\\x"); check(EngineLaunch.workDir(for: w) == nil, "another drive is refused")
    w.engine = GameEngine(workDir: "C:\\a\\..\\b"); check(EngineLaunch.workDir(for: w) == nil, "a folder with .. is refused")
    check(EngineLaunch.poolBytes() == 896 * 1024 * 1024, "the JIT pool is the standard 896 MB when nothing is set")

    // MARK: engine options storage
    check(EngineOptions.value("pool") == "", "an option nobody set reads as Default")
    EngineOptions.set("pool", "640")
    check(EngineOptions.value("pool") == "640" && EngineLaunch.poolBytes() == 640 * 1024 * 1024, "a chosen pool size is stored and used")
    EngineOptions.set("pool", "2048")
    check(EngineLaunch.poolBytes() == 896 * 1024 * 1024, "a pool size outside 256-1152 MB falls back to the standard")
    EngineOptions.set("pool", "")
    check(EngineOptions.value("pool") == "" && MadeiraConfig.get("pool") == nil, "Default removes the key")
    // A line somebody wrote by hand stays untouched when another key is changed.
    let cfg = MadeiraConfig.url!
    try? FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "# mine\nswap-mb = 2048\nasync-submit = 1\n".write(to: cfg, atomically: true, encoding: .utf8)
    EngineOptions.set("ags-rewrite", "0")
    let text = try! String(contentsOf: cfg, encoding: .utf8)
    check(text.contains("# mine") && text.contains("swap-mb = 2048") && text.contains("async-submit = 1") && text.contains("ags-rewrite = 0"), "changing one key leaves comments and every other line alone")
    check(EngineOptions.value("async-submit") == "1", "a value written by hand is shown")
    // The old "Broad swap coverage" row's line moves into Swap covers.
    let scratch = UserDefaults(suiteName: "porthole.test.swapmode")!; scratch.removePersistentDomain(forName: "porthole.test.swapmode")
    check(!EngineOptions.migrateSwapMode(defaults: scratch), "nothing to migrate without a swap-mode line")
    _ = MadeiraConfig.set("swap-mode", "2")
    check(EngineOptions.migrateSwapMode(defaults: scratch) && MadeiraConfig.get("swap-mode") == nil && scratch.string(forKey: "f4.swapCoverage") == "broad", "swap-mode = 2 becomes the Broad choice and the line goes")
    _ = MadeiraConfig.set("swap-mode", "2"); scratch.set("", forKey: "f4.swapCoverage")
    check(EngineOptions.migrateSwapMode(defaults: scratch) && scratch.string(forKey: "f4.swapCoverage") == "", "a coverage the person chose is kept; the old line still goes")
    check(MadeiraConfig.get("async-submit") == "1", "other lines are untouched by the migration")
    scratch.removePersistentDomain(forName: "porthole.test.swapmode")
    let ids = EngineOptions.groups.flatMap { $0.options.map(\.key) }
    check(Set(ids).count == ids.count, "no option appears twice")
    let managed: Set<String> = ["swap-mb", "env.MADEIRA_SWAP_COVERAGE", "vram-mb", "env.MADEIRA_AUDIO_CUSHION_MS", "env.MADEIRA_PRECISE_MATH", "d3d12"]
    check(ids.allSatisfy { !managed.contains($0) }, "none of the settings Porthole already has is in the new list")
    check(EngineOptions.groups.allSatisfy { $0.options.allSatisfy { $0.choices.first?.value == "" } }, "every option's first choice is Default (the key removed)")
    let unknown = EngineOption(key: "x", title: "x", symbol: "x", info: "", choices: [("", "Default"), ("1", "On")])
    check(EngineOptions.choices(for: unknown, current: "3").contains { $0.0 == "3" }, "a value outside the list is still shown")

    // MARK: controller actions
    check(PadActions.action("space") == .key(0x20) && PadActions.action("lmb") == .mouse(0) && PadActions.action("key-E") == .key(0x45) && PadActions.action("f5") == .key(0x74), "action ids map to keys and mouse buttons")
    check(PadActions.action("nonsense") == .none && PadActions.action(nil) == .none, "an unknown action does nothing")
    check(Set(PadActions.list.map(\.id)).count == PadActions.list.count, "action ids are unique")
    check(PadActions.buttons.allSatisfy { PadActions.template[$0] != nil } && PadActions.template.values.allSatisfy { id in PadActions.list.contains { $0.id == id } }, "the standard layout covers every button with a valid action")
    check(PadActions.bindings(["A": "key-F"])["A"] == "key-F" && PadActions.bindings(["A": "key-F"])["B"] == "ctrl" && PadActions.bindings(nil)["RT"] == "lmb", "a game's own binds sit on top of the standard layout")

    // MARK: save backups
    let drive = AppModel.driveC
    let fm = FileManager.default
    func put(_ path: String, _ text: String) { let u = drive.appendingPathComponent(path); try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try! text.write(to: u, atomically: true, encoding: .utf8) }
    put("users/mobile/Documents/My Games/Foo/save1.sav", "progress 1")
    put("users/mobile/AppData/Roaming/Foo/settings.ini", "volume=7")
    put("users/mobile/AppData/Local/Temp/junk.tmp", "junk")
    put("users/mobile/AppData/Local/Steam/local.vdf", "secret")
    put("users/mobile/Documents/Cache/skip.dat", "cache")
    do {
        let b = try SaveBackup.backup()
        check(b.files == 2, "a backup holds the saves and settings (\(b.files) files) and leaves out Temp, Steam's files and caches")
        try? fm.removeItem(at: drive.appendingPathComponent("users/mobile/Documents"))
        try? fm.removeItem(at: drive.appendingPathComponent("users/mobile/AppData/Roaming"))
        let n = try SaveBackup.restore(from: b.url)
        let save = try? String(contentsOf: drive.appendingPathComponent("users/mobile/Documents/My Games/Foo/save1.sav"), encoding: .utf8)
        let ini = try? String(contentsOf: drive.appendingPathComponent("users/mobile/AppData/Roaming/Foo/settings.ini"), encoding: .utf8)
        check(n == 2 && save == "progress 1" && ini == "volume=7", "a restore puts every file back with its contents")
        let reader = try SaveZipReader(url: b.url)
        check(reader.entries.allSatisfy { $0.name.hasPrefix("users/mobile/") && !$0.name.contains("..") }, "every entry is under users/<name>/")
        try? fm.removeItem(at: b.url)
    } catch { check(false, "backup and restore ran: \(error)") }
    let bad = fm.temporaryDirectory.appendingPathComponent("not-a-zip-\(UUID().uuidString).zip")
    try! Data("hello".utf8).write(to: bad)
    check((try? SaveBackup.restore(from: bad)) == nil, "a file that is not a zip is refused")
    try? fm.removeItem(at: bad)
    // A zip with an entry trying to leave the drive.
    let evil = fm.temporaryDirectory.appendingPathComponent("evil-\(UUID().uuidString).zip")
    if let z = try? SaveZipWriter(url: evil) {
        try? z.add(name: "users/../../escape.txt", data: Data("x".utf8)); try? z.add(name: "other/file.txt", data: Data("x".utf8)); try? z.finish()
        check((try? SaveBackup.restore(from: evil)) == nil && !fm.fileExists(atPath: drive.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("escape.txt").path), "entries outside users/ or with .. are never written")
    }
    try? fm.removeItem(at: evil)


    // MARK: bind sets
    let tpl = [TouchLayout.mouseAndKeys, TouchLayout.firstPerson]
    check(tpl.allSatisfy { $0.sanitized() == $0 && !$0.controls.isEmpty }, "the two starting layouts are valid as they are")
    check(TouchLayout.firstPerson.look && !TouchLayout.mouseAndKeys.look, "first person looks by dragging, mouse and keys does not")
    var wild = TouchLayout(controls: [
        TouchControlSpec(label: "A very long label indeed", action: "key-E", mode: "weird", x: 7, y: -3, size: 9999),
        TouchControlSpec(label: "x", action: "rm -rf", x: 0.5, y: 0.5),
        TouchControlSpec(label: "none", action: "none", x: 0.5, y: 0.5),
        TouchControlSpec(label: "", action: "stick-arrows", x: .nan, y: .infinity, size: .nan)], look: true)
    let clean = wild.sanitized()
    check(clean.controls.count == 2 && clean.controls[0].label.count == 8 && clean.controls[0].mode == "tap", "a layout from outside: unknown and empty actions dropped, long labels cut, a bad mode becomes tap")
    check(clean.controls[0].x == 0.98 && clean.controls[0].y == 0.04 && clean.controls[0].size == 160, "positions and sizes are pulled into range")
    check(clean.controls[1].x == 0.5 && clean.controls[1].size == 54, "NaN and infinite numbers become safe defaults")
    wild.controls = (0..<100).map { _ in TouchControlSpec(label: "k", action: "space", x: 0.5, y: 0.5) }
    check(TouchLayout(controls: [TouchControlSpec(label: "Look", action: "lookmode", x: 0.5, y: 0.5)]).sanitized().controls.count == 1 && PadActions.action("lookmode") == .lookToggle && !PadActions.list.contains { $0.id == "lookmode" }, "the look/mouse button is a touch-only action")
    check(wild.sanitized().controls.count == TouchLayout.maxControls, "at most \(TouchLayout.maxControls) controls")
    let padPart = PadPart(binds: ["A": "key-F", "ZZ": "space", "B": "not-an-action", "LS": "arrows", "RS": "key-E"], mouseVertical: 50).sanitized()
    check(padPart.binds == ["A": "key-F", "LS": "arrows"] && padPart.mouseVertical == 2.0, "controller binds from outside: unknown inputs and actions dropped, a stick takes only a stick mode, speed clamped")

    var set = BindSet(name: "Shooter", notes: "FPS layout", pad: PadPart(binds: ["A": "key-F"], mouseVertical: 1.5), touch: .firstPerson)
    check(set.summary == "Controller and Touch layout" && BindSet(name: "x").summary == "Empty", "a set says what it carries")
    do {
        let data = try BindSetFile.encode(set, gameName: "Some Game")
        let (back, game) = try BindSetFile.decode(data)
        check(back.name == "Shooter" && back.notes == "FPS layout" && back.pad == set.pad && back.touch?.controls.count == set.touch?.controls.count && game == "Some Game", "a set survives export and import")
        check(back.id != set.id, "an imported set gets its own id")
    } catch { check(false, "export and import ran: \(error)") }
    check((try? BindSetFile.decode(Data("{\"hello\": 1}".utf8))) == nil && (try? BindSetFile.decode(Data("not json".utf8))) == nil, "files that are not bind sets are refused")
    check((try? BindSetFile.decode(Data(repeating: 0x20, count: BindSetFile.maxBytes + 1))) == nil, "a file over 64 KB is refused")
    let newer = #"{"format":"porthole-binds","version":99,"name":"x","pad":{"binds":{}}}"#
    check((try? BindSetFile.decode(Data(newer.utf8))) == nil, "a set from a newer version is refused")
    let empty = #"{"format":"porthole-binds","version":1,"name":"x"}"#
    check((try? BindSetFile.decode(Data(empty.utf8))) == nil, "a set with neither part is refused")
    let nasty = #"{"format":"porthole-binds","version":1,"name":"  <b>Evil</b>\nname\u0007  ","notes":"line1\nline2","pad":{"binds":{"A":"zzz","B":"lmb"}}}"#
    if let (n, _) = try? BindSetFile.decode(Data(nasty.utf8)) {
        check(!n.name.contains("\n") && !n.name.contains("\u{7}") && n.notes == "line1 line2" && n.pad?.binds == ["B": "lmb"], "text from a file has control characters and line breaks removed, bad binds dropped")
    } else { check(false, "a hostile but well-formed file still imports its good parts") }
    let long = #"{"format":"porthole-binds","version":1,"name":"\#(String(repeating: "n", count: 500))","pad":{"binds":{}}}"#
    check((try? BindSetFile.decode(Data(long.utf8)))?.set.name.count == 40, "a very long name is cut to 40 characters")

    // Per game: one set in use at a time, none by default.
    var bg = Game(exe: "C:\\a.exe")
    check(bg.activeBindSet == nil, "a game with no sets has none in use")
    let s1 = BindSet(name: "One", pad: PadPart()), s2 = BindSet(name: "Two", touch: .mouseAndKeys)
    bg.bindSets = [s1, s2]
    check(bg.activeBindSet == nil, "having sets does not use one")
    bg.activeBindSetID = s2.id
    check(bg.activeBindSet?.name == "Two", "the chosen set is the one in use")
    bg.activeBindSetID = UUID()
    check(bg.activeBindSet == nil, "an id that matches no set (a deleted one) means none in use")
    let rt = try! JSONDecoder().decode(Game.self, from: JSONEncoder().encode(bg))
    check(rt == bg, "a game with sets survives being saved and loaded")
    let before = try! JSONDecoder().decode(Game.self, from: Data(#"{"exe":"C:\\a.exe","args":""}"#.utf8))
    check(before.bindSets == nil && before.activeBindSetID == nil, "a library saved before bind sets existed loads with none")


    // MARK: sharing
    // What the Hub sends for a list and for one set (no ids on the controls, optional pieces missing).
    let listJSON = #"[{"id":7,"gameId":"steam:1","name":null,"notes":null,"hasPad":true,"hasTouch":false,"controlCount":0,"bindCount":2,"look":false,"up":3,"down":1,"downloads":9,"version":2,"updated":"2026-10-04"}]"#
    let list = try! JSONDecoder().decode([SharedBind].self, from: Data(listJSON.utf8))
    check(list.count == 1 && list[0].displayName == "Shared set #7" && list[0].approval == 0.75 && list[0].contents == "Controller: 2 changed", "a list entry from the Hub decodes; a set whose name is not approved is called Shared set #id")
    let fullJSON = #"{"id":8,"gameId":"steam:1","name":"Shooter","notes":"hello","hasPad":true,"hasTouch":true,"controlCount":2,"bindCount":1,"look":true,"up":0,"down":0,"downloads":0,"version":1,"updated":"2026-10-04","pad":{"binds":{"A":"key-F","ZZ":"space"},"mouseVertical":1.5},"touch":{"look":true,"controls":[{"label":"FIRE","action":"lmb","mode":"hold","x":0.9,"y":0.8,"size":76},{"label":"","action":"bogus","x":0.5,"y":0.5},{"label":"E","action":"key-E","x":2,"y":0.5}]}}"#
    let full = try! JSONDecoder().decode(SharedBind.self, from: Data(fullJSON.utf8))
    check(full.touch?.controls.count == 3 && full.approval == nil && full.contents == "Controller: 1 changed \u{00B7} Touch layout: 2 controls, look", "a full set from the Hub decodes even though its controls carry no ids")
    let mine = BindsShare.localSet(from: full, existingNames: ["Shooter"])
    check(mine?.name == "Shooter 2" && mine?.downloadedFrom == 8 && mine?.pad?.binds == ["A": "key-F"] && mine?.touch?.controls.count == 2, "a download is checked again: unknown binds and controls dropped, the name made unique, and it remembers where it came from")
    check(mine?.touch?.controls.last?.x == 0.98, "a position outside the screen from the Hub is pulled back in")
    var nothing = full; nothing.pad = nil; nothing.touch = nil
    check(BindsShare.localSet(from: nothing, existingNames: []) == nil, "a set with nothing in it is not downloaded")
    var hostile = full; hostile.name = "  line1\nline2\u{7}  "
    check(BindsShare.localSet(from: hostile, existingNames: [])?.name == "line1 line2", "a name from the Hub is cleaned")
    var toShare = BindSet(name: "Mine", notes: "n", pad: PadPart(binds: ["A": "key-F", "bad": "x"], mouseVertical: 1.5), touch: TouchLayout.mouseAndKeys)
    let payload = BindPublishPayload(set: toShare, game: BindGameRef(kind: "steam", steamAppID: 5, fingerprint: nil, title: "Game"))
    let sent = String(data: try! JSONEncoder().encode(payload), encoding: .utf8)!
    check(payload.clientId == toShare.id.uuidString.lowercased() && payload.pad?.binds == ["A": "key-F"], "what is published is the set, checked, filed under this set's own id")
    check(sent.contains("\"clientId\"") && sent.contains("\"steamAppID\":5") && !sent.contains("downloadedFrom") && !sent.contains("remoteID"), "the payload carries no local bookkeeping")
    check(BindsShare.problem(sharing: BindSet(name: "x")) != nil && BindsShare.problem(sharing: toShare) == nil, "an empty set can not be shared")
    toShare.touch = TouchLayout(); toShare.pad = nil
    check(BindsShare.problem(sharing: toShare) != nil, "a touch layout with no controls can not be shared")
    let my = try! JSONDecoder().decode(MySharedBind.self, from: Data(#"{"id":3,"clientId":"abc","gameId":"steam:1","gameTitle":"G","textStatus":"pending","hidden":false,"up":0,"down":0,"downloads":0,"version":1}"#.utf8))
    check(my.statusText.contains("waiting"), "the state of a published set's text is explained")
    // A set saved before sharing existed still loads.
    let oldSet = try! JSONDecoder().decode(BindSet.self, from: Data(#"{"id":"11111111-2222-3333-4444-555555555555","name":"Old","notes":"","created":0,"updated":0,"pad":{"binds":{"A":"space"}}}"#.utf8))
    check(oldSet.remoteID == nil && oldSet.downloadedFrom == nil && oldSet.pad?.binds["A"] == "space", "a bind set saved before sharing loads with no links")


    // MARK: the contract with the Hub (fixtures shared with hub/test/contract.test.js)
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
    let ref = BindGameRef(kind: "steam", steamAppID: 427520, title: "Factorio")
    var a = BindSet(name: "Shooter layout", notes: "FPS", pad: PadPart(binds: ["A": "key-F", "LS": "arrows", "RT": "lmb"], mouseVertical: 1.5), touch: .firstPerson)
    a.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var b = BindSet(name: "", pad: PadPart()); b.id = UUID(uuidString: "22222222-2222-3333-4444-555555555555")!
    var c = BindSet(name: "Touch only", touch: .mouseAndKeys); c.id = UUID(uuidString: "33333333-2222-3333-4444-555555555555")!
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    // The ids of the controls are random; fix them so the fixture is stable.
    func fixed(_ set: BindSet) -> BindSet { var s = set; if var t = s.touch { t.controls = t.controls.enumerated().map { var k = $1; k.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!; return k }; s.touch = t }; return s }
    let payloads = [a, b, c].map { fixed($0) }.map { BindPublishPayload(set: $0, game: ref) }
    let wantedPayloads = try! enc.encode(payloads)
    let payloadFile = fixtures.appendingPathComponent("client-payloads.json")
    if getenv("WRITE_FIXTURES") != nil { try! wantedPayloads.write(to: payloadFile) }
    check((try? Data(contentsOf: payloadFile)) == wantedPayloads, "what the app publishes is what the Hub's tests are given (fixtures/client-payloads.json is current; WRITE_FIXTURES=1 rewrites it)")
    if let data = try? Data(contentsOf: fixtures.appendingPathComponent("server-responses.json")),
       let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        func json(_ key: String) -> Data? { all[key].flatMap { try? JSONSerialization.data(withJSONObject: $0) } }
        let list = json("list").flatMap { try? JSONDecoder().decode([SharedBind].self, from: $0) }
        let detail = json("detail").flatMap { try? JSONDecoder().decode(SharedBind.self, from: $0) }
        let mineRows = json("mine").flatMap { try? JSONDecoder().decode([MySharedBind].self, from: $0) }
        let published = json("publish").flatMap { try? JSONDecoder().decode(BindPublishResult.self, from: $0) }
        let reviewed = json("review").flatMap { try? JSONDecoder().decode(BindReviewResult.self, from: $0) }
        let reviewList = json("reviews").flatMap { try? JSONDecoder().decode([SharedBindReview].self, from: $0) }
        check(list?.isEmpty == false && detail != nil && mineRows?.isEmpty == false && published != nil && reviewed != nil && reviewList?.isEmpty == false, "every answer the Hub gives (list, set, mine, publish, review, reviews) decodes in the app")
        check(detail?.pad != nil && detail?.touch?.controls.isEmpty == false && detail?.touch?.controls.allSatisfy({ !$0.action.isEmpty }) == true, "a set from the Hub carries its binds and its layout")
        if let detail { check(BindsShare.localSet(from: detail, existingNames: []) != nil, "and becomes a usable local set") }
    } else { check(false, "fixtures/server-responses.json is missing (run hub/test/contract.test.js with WRITE_FIXTURES=1 and copy it here)") }


    // MARK: in-game editor helpers
    check(PadActions.list.filter { $0.id != "none" }.allSatisfy { !PadActions.shortLabel($0.id).isEmpty }, "every action has a short name for a control's face")
    check(PadActions.shortLabel("key-E") == "E" && PadActions.shortLabel("space") == "Space" && PadActions.shortLabel("f5") == "F5" && PadActions.shortLabel("lmb") == "LMB", "short names read as the key or button")
    // The menus also offer the pad's buttons and triggers (mixed layouts); its sticks and D-pad come with the stick picker.
    let padButtons = TouchPadControl.entries.filter { !$0.control.isRound }.map(\.id)
    check(Set(PadActions.groups.flatMap(\.ids)) == Set((PadActions.list + PadActions.touchOnly).map(\.id) + padButtons).subtracting(["none"]) && PadActions.groups.flatMap(\.ids).count == PadActions.list.count - 1 + PadActions.touchOnly.count + padButtons.count, "the editor's menus offer every action exactly once")


    // MARK: use what works for others
    typealias RV = RecommendedSettings.Values
    let current = RV(launch: "steam", power: "balanced", swapMB: 0, swapCoverage: "", vramMB: 0, preciseMath: false, desktopDisplay: false)
    let wanted = RV(launch: "direct", power: "performance", swapMB: 2048, swapCoverage: "blocks", vramMB: 3072, preciseMath: true, desktopDisplay: false)
    let counts = ["launch": 4, "power": 5, "swapMB": 4, "swapCoverage": 4, "vramMB": 3, "preciseMath": 2, "desktopDisplay": 6]
    let plan = RecommendedSettings.changes(recommended: wanted, counts: counts, reports: 6, current: current, steamGame: true)
    check(plan.map(\.key) == ["launch", "power", "swapMB", "swapCoverage"], "only settings that differ AND that more than half of the people agree on are suggested (3 of 6 and 2 of 6 are not a majority; one that already matches is skipped)")
    check(plan.first { $0.key == "power" }.map { $0.from == "Balanced" && $0.to == "Performance" && $0.count == 5 } == true && plan.first { $0.key == "swapMB" }?.to == "2 GB", "a suggestion says what it is now, what it would be, and how many agree")
    check(!RecommendedSettings.changes(recommended: wanted, counts: counts, reports: 6, current: current, steamGame: false).contains { $0.key == "launch" }, "how a game starts is only suggested for a game that starts through Steam")
    check(RecommendedSettings.changes(recommended: wanted, counts: ["power": 1], reports: 1, current: current, steamGame: true).isEmpty, "one report is not enough to suggest anything")
    check(RecommendedSettings.changes(recommended: current, counts: counts, reports: 6, current: current, steamGame: true).isEmpty, "settings that already match suggest nothing")
    var noSwap = wanted; noSwap.swapMB = 0
    check(!RecommendedSettings.changes(recommended: noSwap, counts: counts, reports: 6, current: current, steamGame: true).contains { $0.key == "swapCoverage" }, "swap coverage is not suggested when swap is off")
    var game = Game(exe: "C:\\a.exe"); game.dockAppID = 9; game.settings = GameSettings(vramMB: 1536, resolution: "1280x720")
    let original = game
    RecommendedSettings.apply(plan, recommended: wanted, to: &game)
    check(game.settings?.powerMode == 0 && game.settings?.swapMB == 2048 && game.settings?.swapCoverage == "blocks" && game.launchDirect == true, "applying writes this game's own overrides")
    check(game.settings?.vramMB == 1536 && game.settings?.resolution == "1280x720" && game.settings?.preciseMath == nil, "and leaves the game's other overrides, and the settings that were not suggested, alone")
    check(game.engine == original.engine && game.bindSets == original.bindSets, "nothing else of the game changes")
    RecommendedSettings.undo(&game)
    check(game.settings == original.settings && game.launchDirect == original.launchDirect && game.settingsUndo == nil, "undo puts the game's settings back exactly")
    var fresh = Game(exe: "C:\\b.exe"); RecommendedSettings.apply(plan.filter { $0.key == "power" }, recommended: wanted, to: &fresh)
    RecommendedSettings.undo(&fresh)
    check(fresh.settings == nil && fresh.launchDirect == nil, "undo on a game that had no overrides leaves it with none")
    check(RecommendedSettings.powerRaw("performance") == 0 && RecommendedSettings.powerRaw("balanced") == 1 && RecommendedSettings.powerRaw("saver") == 2 && RecommendedSettings.powerRaw("x") == nil, "power names map to PowerMode's raw values")


    // MARK: automatic backups
    let abDir = fm.temporaryDirectory.appendingPathComponent("autobackup-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: abDir) }
    let ud = UserDefaults(suiteName: "autobackup-test-\(UUID().uuidString)")!
    // The Wine drive from the saves tests above still has files in it.
    check(AutoBackup.enabled(ud), "automatic backups are on unless turned off")
    AutoBackup.setEnabled(false, ud)
    check(AutoBackup.run(defaults: ud, directory: abDir) == .off && AutoBackup.entries(in: abDir).isEmpty, "off means nothing is written")
    AutoBackup.setEnabled(true, ud)
    let first = AutoBackup.run(defaults: ud, directory: abDir)
    if case .written(let name) = first { check(name.hasPrefix(AutoBackup.prefix) && name.hasSuffix(".zip") && AutoBackup.entries(in: abDir).count == 1, "the first run writes a backup into the folder") } else { check(false, "the first run writes a backup: \(first)") }
    check(AutoBackup.run(defaults: ud, directory: abDir) == .unchanged && AutoBackup.entries(in: abDir).count == 1, "a second run with nothing changed writes nothing")
    put("users/mobile/Documents/My Games/Foo/save2.sav", "progress 2")
    if case .written = AutoBackup.run(defaults: ud, directory: abDir) { check(AutoBackup.entries(in: abDir).count == 2, "a changed save is backed up again") } else { check(false, "a changed save is backed up again") }
    for i in 0..<6 { put("users/mobile/Documents/My Games/Foo/loop\(i).sav", "n\(i)"); Thread.sleep(forTimeInterval: 1.1); AutoBackup.run(defaults: ud, directory: abDir) }
    check(AutoBackup.entries(in: abDir).count == AutoBackup.keep, "only the newest \(AutoBackup.keep) are kept")
    check(AutoBackup.entries(in: abDir).first!.date >= AutoBackup.entries(in: abDir).last!.date, "newest first")
    put("users/mobile/Documents/My Games/Foo/changed.sav", "x")
    if case .tooLarge(let n) = AutoBackup.run(defaults: ud, directory: abDir, maxSaves: 10) { check(n > 10, "and the outcome says how large they are") } else { check(false, "saves over the limit are refused") }
    put("users/mobile/Documents/My Games/Foo/changed2.sav", "y")
    check(AutoBackup.run(defaults: ud, directory: abDir, freeSpace: { 100 }) == .lowSpace, "nearly no free space writes nothing")
    if let newest = AutoBackup.entries(in: abDir).first {
        try? fm.removeItem(at: drive.appendingPathComponent("users/mobile/Documents"))
        check((try? SaveBackup.restore(from: newest.url)) ?? 0 > 0 && fm.fileExists(atPath: drive.appendingPathComponent("users/mobile/Documents/My Games/Foo/save1.sav").path), "an automatic backup restores like any other")
    }
    AutoBackup.deleteAll(in: abDir, defaults: ud)
    check(AutoBackup.entries(in: abDir).isEmpty, "deleting the automatic backups removes them all")
    check(AutoBackup.fingerprint(of: []) == AutoBackup.fingerprint(of: []) && AutoBackup.fingerprint(of: [SaveBackup.Item(name: "a", url: abDir, size: 1, modified: 1)]) != AutoBackup.fingerprint(of: [SaveBackup.Item(name: "a", url: abDir, size: 2, modified: 1)]), "a changed size changes the fingerprint")


    // MARK: rumble
    check(RumbleMath.scale(from: "") == 1 && RumbleMath.scale(from: "0") == 0 && RumbleMath.scale(from: "50") == 0.5 && RumbleMath.scale(from: "150") == 1.5 && RumbleMath.scale(from: "999") == 2 && RumbleMath.scale(from: "-5") == 0 && RumbleMath.scale(from: "x") == 1, "the rumble strength setting: normal, off, a percentage, and nonsense falls back to normal")
    check(RumbleMath.level(0, 1) == 0 && RumbleMath.level(65535, 1) == 1 && abs(RumbleMath.level(32768, 1) - 0.5) < 0.01 && RumbleMath.level(65535, 0) == 0, "a motor speed becomes a haptic intensity from 0 to 1, and off silences it")
    check(RumbleMath.level(40000, 2) == 1 && abs(RumbleMath.level(20000, 1.5) - 0.4577) < 0.01, "strong cannot go above full, and light and strong scale it")
    check(EngineOptions.groups.flatMap { $0.options }.contains { $0.key == "env.PORTHOLE_RUMBLE" && $0.choices.first?.value == "" }, "the rumble setting is on the Engine options page, starting on Default")


    // MARK: "Worked in v..." badges (answers written by the Hub's tests)
    if let data = try? Data(contentsOf: fixtures.appendingPathComponent("compat-badges.json")),
       let all = try? JSONDecoder().decode([String: CompatBadge].self, from: data) {
        check(all["great"]?.past?.text == "Worked in v0.50.34" && all["playable"]?.past?.text == "Somewhat worked in v0.50.34" && all["broken"]?.past?.text == "Didn't work in v0.50.34", "an earlier engine's verdict reads Worked in, Somewhat worked in, or Didn't work in, with the app version it was reported on")
        check(all["great"]?.verdict == nil && all["great"]?.needsReview == true && all["great"]?.earlier?.engine == "aaa1111-r0", "it appears while there is no verdict on this engine, and the earlier engine is known")
        check(all["current"]?.verdict == .broken && all["current"]?.past == nil, "once the current engine has a verdict, that verdict shows and the past one does not")
        check(all["current"]?.earlier?.verdict == .great, "(the earlier result is still there for the details)")
        check(all["great"]?.past?.symbol != all["great"]?.verdict?.symbol, "a past result has its own icons, not the verdict's")
    } else { check(false, "fixtures/compat-badges.json is missing or does not decode (run hub/test/compat.test.js with WRITE_FIXTURES=1 and copy it here)") }
    let older = try! JSONDecoder().decode(CompatBadge.self, from: Data(#"{"overall":null,"forDevice":null,"verdict":null,"earlier":{"reports":3}}"#.utf8))
    check(older.past == nil && older.needsReview, "an older Hub that sends no earlier verdict still decodes, and shows the old Not yet tested")
    check(CompatPast(verdict: .great, version: nil, engine: "x").text == "Worked in an earlier version" && CompatPast(verdict: .broken, version: "0.50.1", engine: nil).explanation.contains("may well run now"), "without a version it says an earlier version; a past failure says it may well run now")

    print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
}
