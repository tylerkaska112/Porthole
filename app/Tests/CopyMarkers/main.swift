import Foundation

var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("copymarkers-\(UUID().uuidString)")
func make(_ path: String, folder: Bool = false) {
    let url = root.appendingPathComponent(path)
    try? fm.createDirectory(at: folder ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !folder { fm.createFile(atPath: url.path, contents: Data()) }
}

make("Clean/Game.exe"); make("Clean/steam_api64.dll"); make("Clean/data/level1.pak")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Clean")).isEmpty, "a clean game folder has no marks")

make("Cracked/Game.exe"); make("Cracked/CODEX64.dll"); make("Cracked/steam_api64.dll")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Cracked")) == ["codex64.dll"], "a Steam emulator's library beside the exe is found, whatever its case")

make("Nested/bin/x64/Game.exe"); make("Nested/bin/x64/steam_emu.ini")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Nested")) == ["steam_emu.ini"], "two folders down is found too")

make("Deep/a/b/c/steam_emu.ini")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Deep")).isEmpty, "deeper than two folders is not looked at")

make("Legit/steam_settings", folder: true); make("Legit/Game.exe"); make("Legit/steam_api64.dll.bak"); make("Legit/Darksiders.ini")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Legit")).isEmpty, "a settings folder, a .bak of steam_api and a game's own ini are not taken for a modified copy")

check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Missing")).isEmpty, "a folder that is not there has no marks")
check(CopyMarkers.markers(forTitle: "WEBFISHING-SteamRIP.com") == ["title: steamrip"], "a release site in the title")
check(CopyMarkers.markers(forTitle: "Plants_vs_Zombies_Replanted_--_fitgirl-repacks.site_--") == ["title: fitgirl-repacks"], "another release site in the title")
check(CopyMarkers.markers(forTitle: "Codex Repack Girl Skidrow Simulator").isEmpty, "generic words in a title are not enough")
check(CopyMarkers.markers(forTitle: "Crash Bandicoot N. Sane Trilogy").isEmpty, "an ordinary title has none")
make("Sites/Game.exe"); make("Sites/IGG-GAMES.COM.url"); make("Sites/SKIDROW.nfo")
check(Set(CopyMarkers.markers(inFolder: root.appendingPathComponent("Sites"))) == Set(["site: igg-games", "skidrow.nfo"]), "a piracy site's shortcut and a release group's .nfo are found (\(CopyMarkers.markers(inFolder: root.appendingPathComponent("Sites"))))")
check(CopyMarkers.markers(forTitle: "Megabonk-AnkerGames") == ["title: ankergames"], "AnkerGames in a name")
make("Online/Game.exe"); make("Online/OnlineFix64.dll")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Online")) == ["onlinefix64.dll"], "the OnlineFix library is found")
check(CopyMarkers.markers(forTitle: "Some Game [GOG-Games.com]") == ["title: gog-games.com"], "a piracy site that has GOG in its name is found by its whole name")
for fine in ["GOG Galaxy", "gog.com", "The Matrix Reloaded", "Plaza Hotel", "Codex Arcanum", "FitGirl", "Steam Unlocked achievements", "flt"] {
    check(CopyMarkers.markers(forTitle: fine).isEmpty, "\(fine) is not taken for a piracy site")
}
make("Fine/Reloaded.exe"); make("Fine/flt.txt"); make("Fine/gog.com.url")
check(CopyMarkers.markers(inFolder: root.appendingPathComponent("Fine")).isEmpty, "ordinary file names in a folder are not marks")
check(CopyMarkers.note.contains("no support") && !CopyMarkers.note.lowercased().contains("report") && !CopyMarkers.note.lowercased().contains("mark"), "the note says there is no support and nothing about reports")

try? fm.removeItem(at: root)
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
