// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Recognises a game folder that holds files of a cracked, repacked or emulated release (a Steam emulator's library or settings file, a release site in the title). Nothing is blocked or
/// changed because of it: the game still starts as any other. The only effect is an honest note for the person (this copy has no support, and nothing can be done if it does not
/// work). Foundation only; app/Tests/CopyMarkers runs it.
enum CopyMarkers {
    /// File names that belong to scene releases and Steam emulators and to nothing else (compared in lower case). Anything a legitimately downloaded game, a mod or a tool could also have
    /// is left out on purpose (a `.bak` of steam_api, a settings folder, a generic word in a name): a real game must never be taken for a modified copy.
    static let fileNames: Set<String> = [
        "codex64.dll", "codex32.dll", "codex.ini", "steam_emu.ini", "steam_emu.dll", "cream_api.ini", "cream_api.dll",
        "smartsteamemu.ini", "smartsteamemu.dll", "smartsteamemu64.dll", "ali213.ini", "ali213.dll", "steamclient_loader.exe", "steamclient_loader64.dll",
        "onlinefix.dll", "onlinefix64.dll", "onlinefix.ini",
    ]
    /// No folder names: the ones such releases use (Goldberg's `steam_settings`) are not exclusive to them.
    static let folderNames: Set<String> = []
    /// Piracy sites, by the names they stamp on what they publish (a game's name, a file in its folder such as "IGG-GAMES.COM.url"). A plain word such as "gog" or "steam" never counts:
    /// "gog-games.com" is a piracy site, GOG is not. Kept in step with hub/copy-marks.js (the Launcher's reviewers see the same list on the Hub). A list like this is never complete;
    /// it errs on the side of missing one over taking a real game for a modified copy.
    static let sites = [
        "steamrip", "fitgirl-repacks", "fitgirl repacks", "igg-games", "igg games", "dodi-repacks", "dodi repacks", "elamigos", "ovagames", "skidrowreloaded", "skidrow-games", "skidrowcodex",
        "gog-games.com", "gog-games.to", "gog-games.net", "pcgamestorrents", "oceanofgames", "steamunlocked", "nosteamgames", "gamesdrive", "worldofpcgames", "repack-games.com",
        "crohasit", "cs.rin.ru", "rutracker.org", "thepiratebay", "1337x.to", "nxbrew", "dlpsgame", "gamestorrents",
        "ankergames", "apunkagames", "ipcgames", "rg mechanics", "r.g. mechanics", "rg-mechanics", "rgmechanics", "xatab", "online-fix.me", "game3rb", "gogunlocked", "freegogpcgames",
        "pivigames", "unlocked-games", "crackhub", "cpy-games", "steamgg",
    ]
    /// Release groups, only as the name of the .nfo file they leave in the folder.
    static let groupNFOs: Set<String> = ["skidrow", "plaza", "razor1911", "reloaded", "flt", "cpy", "empress", "tenoke", "hoodlum", "rune", "prophet", "3dm", "ali213", "codex"].reduce(into: Set<String>()) { $0.insert($1 + ".nfo") }
    static var titleWords: [String] { sites }

    /// The sentence the person is told. It says what is true and no more.
    static let note = "This copy has files from a modified release of the game. You can still run it, but there is no support for copies like this: if it does not work, nothing can be done about it."

    /// What the game's folder holds (the names, lower case, at most 6): looks two folders deep, so the exe's own folder and a `bin` or `x64` folder inside it are covered.
    static func markers(inFolder folder: URL, fileManager fm: FileManager = .default) -> [String] {
        var found: [String] = []
        var seen = 0
        func look(_ dir: URL, depth: Int) {
            guard depth <= 2, found.count < 6, seen < 6000, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                seen += 1
                let lower = name.lowercased()
                if fileNames.contains(lower) || folderNames.contains(lower) || groupNFOs.contains(lower) {
                    if !found.contains(lower) { found.append(lower) }
                } else if let site = sites.first(where: { lower.contains($0) }) {
                    let mark = "site: " + site
                    if !found.contains(mark) { found.append(mark) }
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue { look(dir.appendingPathComponent(name), depth: depth + 1) }
                }
                if found.count >= 6 || seen >= 6000 { return }
            }
        }
        look(folder, depth: 0)
        return found
    }

    /// Release-site words in the game's name.
    static func markers(forTitle title: String) -> [String] {
        let lower = title.lowercased()
        return titleWords.filter { lower.contains($0) }.map { "title: " + $0 }
    }
}
