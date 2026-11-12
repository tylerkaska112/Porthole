// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Which of the game's own session logs (Documents/logs, named "<program>.exe-2026-11-06_22-33-52.txt") belong to a game. Foundation only; app/Tests/CompatLog runs it.
///
/// A game's name is written in three ways: as the library shows it ("Pumping Simulator"), as its program is called (PumpingSimulator.exe) and as Steam's folder is called
/// (steamapps/common/PumpingSimulator). Every spelling is reduced to its letters and digits, so "Pumping Simulator", "Pumping_Simulator" and "PumpingSimulator" are the same word.
enum CompatLogPicker {
    /// Names too common to say which game a log belongs to (a program called launcher.exe belongs to every game that has one).
    static let generic: Set<String> = ["game", "games", "launcher", "steam", "start", "main", "setup", "installer", "install", "unity", "client", "play", "player", "app", "wine",
                                       "explorer", "cmd", "services", "winedevice", "svchost", "rpcss", "plugplay", "wineserver", "program", "bin", "win64", "win32", "x64",
                                       "x86", "shipping", "release", "binaries", "windows", "common", "steamapps", "epic", "gog", "itch", "amazon"]

    /// Letters and digits only, lower case.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The words to look for: the library name, the program's name without ".exe", and Steam's folder name when the program is under steamapps/common. Each at least four
    /// characters and not one of the common names, so a log is never taken for a game by accident.
    static func keys(gameName: String, exe: String) -> [String] {
        let parts = exe.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        var words = [gameName]
        if var file = parts.last {
            if file.lowercased().hasSuffix(".exe") { file = String(file.dropLast(4)) }
            words.append(file)
        }
        if let common = parts.firstIndex(where: { $0.lowercased() == "common" }), common + 1 < parts.count - 1 { words.append(parts[common + 1]) }
        var out: [String] = []
        for word in words {
            let key = normalized(word)
            if key.count >= 4, !generic.contains(key), !out.contains(key) { out.append(key) }
        }
        return out
    }

    /// "Factorio.exe-2026-11-06_22-33-52.txt" -> "factorioexe"; names without a stamp are only lower-cased and reduced.
    static func stem(of fileName: String) -> String {
        var name = fileName
        if name.lowercased().hasSuffix(".txt") { name = String(name.dropLast(4)) }
        if let range = name.range(of: #"-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) { name = String(name[..<range.lowerBound]) }
        return normalized(name)
    }

    /// Does this log's name say it belongs to the game? The name holds one of the game's words. (Only that way round: a short program name inside a longer library name would
    /// pair "dyinglight.exe" with "Dying Light 2 Stay Human".)
    static func nameMatches(_ fileName: String, keys: [String]) -> Bool {
        let stem = stem(of: fileName)
        guard !stem.isEmpty else { return false }
        return keys.contains { stem.contains($0) }
    }

    /// The logs whose names match, newest first: at most `limit`, and none written more than `window` before the newest one (an old session says nothing about this problem).
    static func matches(_ files: [(url: URL, modified: Date)], keys: [String], limit: Int = 5, window: TimeInterval = 14 * 24 * 3600) -> [URL] {
        let named = files.filter { nameMatches($0.url.lastPathComponent, keys: keys) }.sorted { $0.modified > $1.modified }
        guard let newest = named.first?.modified else { return [] }
        return named.filter { newest.timeIntervalSince($0.modified) <= window }.prefix(limit).map(\.url)
    }
}
