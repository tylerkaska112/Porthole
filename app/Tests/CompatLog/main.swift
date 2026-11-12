import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok:   \(name)" : "FAIL: \(name)"); if !ok { failed += 1 } }

let steam = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\"
// the words
check("a library name, a program and a Steam folder all give a word", CompatLogPicker.keys(gameName: "Pumping Simulator", exe: steam + "Pumping Simulator\\PumpingSimulator\\Pumping Simulator.exe") == ["pumpingsimulator"])
check("different spellings are kept apart when they differ", CompatLogPicker.keys(gameName: "Burnout\u{2122} Paradise Remastered", exe: steam + "BurnoutPR\\BurnoutPR_trial.exe") == ["burnoutparadiseremastered", "burnoutprtrial", "burnoutpr"])
check("a common program name is no word", CompatLogPicker.keys(gameName: "Factorio", exe: "C:\\Games\\Factorio\\bin\\launcher.exe") == ["factorio"])
check("a short name is no word", CompatLogPicker.keys(gameName: "Go", exe: "C:\\Games\\Go\\go.exe").isEmpty)
// the names of the logs
let f = CompatLogPicker.keys(gameName: "Factorio", exe: steam + "Factorio\\bin\\x64\\factorio.exe")
check("the game's own log is found by its program's name", CompatLogPicker.nameMatches("factorio.exe-2026-11-06_22-33-52.txt", keys: f))
check("... in any case", CompatLogPicker.nameMatches("Factorio.exe-2026-11-06_22-33-52.txt", keys: f))
check("... and with spaces or underscores in the name", CompatLogPicker.nameMatches("Pumping_Simulator.exe-2026-11-06_22-33-52.txt", keys: CompatLogPicker.keys(gameName: "Pumping Simulator", exe: "C:\\x\\a.exe")))
check("another game's log is not taken", !CompatLogPicker.nameMatches("StickFight.exe-2026-11-06_22-33-52.txt", keys: f))
check("a Wine program's log is not taken", !CompatLogPicker.nameMatches("explorer.exe-2026-11-06_22-33-52.txt", keys: f) && !CompatLogPicker.nameMatches("wineserver-2026-11-06_22-33-52.txt", keys: f))
check("a program with a longer library name matches through the program's own path (Stick Fight: The Game)", CompatLogPicker.nameMatches("StickFight.exe-2026-11-06_22-33-52.txt", keys: CompatLogPicker.keys(gameName: "Stick Fight: The Game", exe: steam + "StickFight\\StickFight.exe")))
check("Dying Light's log is not Dying Light 2's", !CompatLogPicker.nameMatches("DyingLightGame.exe-2026-11-06_22-33-52.txt", keys: CompatLogPicker.keys(gameName: "Dying Light 2 Stay Human", exe: steam + "Dying Light 2\\ph\\work\\bin\\x64\\DyingLightGame_x64_rwdi.exe")))
check("a name that only starts alike is not taken", !CompatLogPicker.nameMatches("Fact.exe-2026-11-06_22-33-52.txt", keys: f))
check("a log with no stamp is read by its name", CompatLogPicker.nameMatches("factorio.txt", keys: f))
// the choice
let now = Date()
func file(_ name: String, daysAgo: Double) -> (url: URL, modified: Date) { (URL(fileURLWithPath: "/logs/" + name), now.addingTimeInterval(-daysAgo * 86400)) }
let files = [file("factorio.exe-2026-11-07_10-00-00.txt", daysAgo: 0), file("factorio.exe-2026-11-06_10-00-00.txt", daysAgo: 1), file("StickFight.exe-2026-11-07_11-00-00.txt", daysAgo: 0),
             file("factorio.exe-2026-10-01_10-00-00.txt", daysAgo: 37), file("factorio.exe-2026-11-05_10-00-00.txt", daysAgo: 2), file("explorer.exe-2026-11-07_10-00-00.txt", daysAgo: 0)]
let picked = CompatLogPicker.matches(files, keys: f).map(\.lastPathComponent)
check("every log with the game's name, newest first, and no other game's", picked == ["factorio.exe-2026-11-07_10-00-00.txt", "factorio.exe-2026-11-06_10-00-00.txt", "factorio.exe-2026-11-05_10-00-00.txt"])
check("a session from long before is left out", !picked.contains("factorio.exe-2026-10-01_10-00-00.txt"))
check("at most the limit", CompatLogPicker.matches(files, keys: f, limit: 2).count == 2)
check("no match gives nothing", CompatLogPicker.matches(files, keys: ["dyinglight"]).isEmpty)

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
