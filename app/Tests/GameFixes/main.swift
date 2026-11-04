import Foundation
// Run: app/Tests/GameFixes/run.sh
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gamefix-\(UUID().uuidString)")
let fm = FileManager.default
let plugins = tmp.appendingPathComponent("TheForest_Data/Plugins")
try! fm.createDirectory(at: plugins, withIntermediateDirectories: true)
try! Data("dll".utf8).write(to: plugins.appendingPathComponent("OVRPlugin.dll"))
try! Data("other".utf8).write(to: plugins.appendingPathComponent("fmod.dll"))
let fix = GameFixes.fix(forSteamAppID: 242760)!

check(fix.overridesValue == "avrt=", "blocks avrt.dll through the DLL override: \(fix.overridesValue)")
check(GameFixes.Fix(steamAppID: 2, title: "t", hide: [], why: "", blockLoading: ["a", "b"]).overridesValue == "a=;b=", "several libraries are separated by semicolons")
check(GameFixes.fix(forSteamAppID: nil) == nil && GameFixes.fix(forSteamAppID: 427520) == nil, "a game with no fix gets none")
check(GameFixes.fix(forSteamAppID: 252490)?.steamProgram == "RustClient.exe" && GameFixes.fix(forSteamAppID: 252490)?.alwaysDirect == false, "Rust starts RustClient.exe next to Steam's client, not without Steam")
let first = GameFixes.hide(fix, in: tmp)
check(first == ["set aside TheForest_Data/Plugins/OVRPlugin.dll"], "hides the plugin, ignores the folder that has none: \(first)")
check(!fm.fileExists(atPath: plugins.appendingPathComponent("OVRPlugin.dll").path) && fm.fileExists(atPath: plugins.appendingPathComponent("OVRPlugin.dll.porthole-disabled").path), "the file is renamed, not deleted")
check(fm.fileExists(atPath: plugins.appendingPathComponent("fmod.dll").path), "other files are untouched")
check(GameFixes.hide(fix, in: tmp).isEmpty, "running again changes nothing")

try! Data("dll v2".utf8).write(to: plugins.appendingPathComponent("OVRPlugin.dll"))   // the game was updated
check(GameFixes.hide(fix, in: tmp).count == 1 && (try? String(contentsOf: plugins.appendingPathComponent("OVRPlugin.dll.porthole-disabled"), encoding: .utf8)) == "dll v2", "a file that comes back is set aside again")

check(GameFixes.restore(fix, in: tmp) == ["restored TheForest_Data/Plugins/OVRPlugin.dll"] && fm.fileExists(atPath: plugins.appendingPathComponent("OVRPlugin.dll").path), "restore puts it back")

let escape = GameFixes.Fix(steamAppID: 1, title: "x", hide: ["../outside.dll"], why: "")
try! Data("x".utf8).write(to: tmp.deletingLastPathComponent().appendingPathComponent("outside.dll"))
check(GameFixes.hide(escape, in: tmp).first?.hasPrefix("refused") == true && fm.fileExists(atPath: tmp.deletingLastPathComponent().appendingPathComponent("outside.dll").path), "a path that leaves the game folder is refused")
try? fm.removeItem(at: tmp.deletingLastPathComponent().appendingPathComponent("outside.dll"))
check(GameFixes.fix(forSteamAppID: 3259780)?.configLines == ["env.MADEIRA_VCRT_ARM64_KEY = 1", "env.MADEIRA_X64_IMAGE_NOCOPY = 1", "pool-split = 1"] && GameFixes.fix(forSteamAppID: 3259780)?.hide.isEmpty == true && GameFixes.fix(forSteamAppID: 3259780)?.alwaysDirect == false, "Final Fantasy Resonance: the ARM64 runtime marker, the x64 image line and the split pool, nothing hidden, still started through Steam")
check(GameFixes.fix(forSteamAppID: 4474710)?.configLines == GameFixes.fix(forSteamAppID: 3259780)?.configLines, "the demo gets the same lines as the full game")

try? fm.removeItem(at: tmp)
let ac = GameFixes.fix(forSteamAppID: 244210)!
check(ac.alwaysDirect && ac.directProgram == "acs.exe" && ac.hide.isEmpty && ac.overridesValue.isEmpty, "Assetto Corsa: start acs.exe directly, hide nothing")
check(GameFixes.windowsPath(replacingLastComponentOf: "C:\\Program Files (x86)\\Steam\\steamapps\\common\\assettocorsa\\AssettoCorsa.exe", with: "acs.exe") == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\assettocorsa\\acs.exe", "the Windows path keeps its folder and swaps the file")
let acDir = FileManager.default.temporaryDirectory.appendingPathComponent("acfix-\(UUID().uuidString)")
try! fm.createDirectory(at: acDir, withIntermediateDirectories: true)
try! Data("a".utf8).write(to: acDir.appendingPathComponent("AssettoCorsa.exe")); try! Data("g".utf8).write(to: acDir.appendingPathComponent("ACS.EXE"))
check(GameFixes.sibling(named: "acs.exe", of: acDir.appendingPathComponent("AssettoCorsa.exe"))?.lastPathComponent == "ACS.EXE", "finds acs.exe whatever its capitals")
try! fm.removeItem(at: acDir.appendingPathComponent("ACS.EXE"))
check(GameFixes.sibling(named: "acs.exe", of: acDir.appendingPathComponent("AssettoCorsa.exe")) == nil, "a missing program is reported, so the launch stays as it was")
try? fm.removeItem(at: acDir)
check(ac.ownSteamIdentity && String(GameFixes.windowsPath(replacingLastComponentOf: "C:\\a\\b\\AssettoCorsa.exe", with: "").dropLast()) == "C:\\a\\b", "the install folder is the program's folder without a trailing backslash")
print(failures == 0 ? "all passed" : "\(failures) FAILED"); 
// A file an earlier build set aside comes back, whatever its capitals on disk
let bng = tmp.appendingPathComponent("bng/Bin64"); try! fm.createDirectory(at: bng, withIntermediateDirectories: true)
try! Data("compiler".utf8).write(to: bng.appendingPathComponent("D3DCOMPILER_47.dll.porthole-disabled"))
let beam = GameFixes.fix(forSteamAppID: 284160)!
check(beam.hide.isEmpty && !beam.formerlyHidden.isEmpty, "BeamNG keeps its own shader compiler (Wine's cannot read its materials)")
let back = GameFixes.restoreFormer(beam, in: tmp.appendingPathComponent("bng"))
check(back == ["restored Bin64/D3DCOMPILER_47.dll"] && fm.fileExists(atPath: bng.appendingPathComponent("D3DCOMPILER_47.dll").path), "the former set-aside compiler is put back: \(back)")
exit(failures == 0 ? 0 : 1)
