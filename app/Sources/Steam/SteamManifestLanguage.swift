// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// A real Steam install record (appmanifest_<appid>.acf) carries the game's language twice, under "UserConfig" and "MountedConfig", and Steam's own client keeps its language in the
// Windows registry (HKCU\Software\Valve\Steam\Language). That is what a game gets when it asks Steam "what language am I in?" (ISteamApps::GetCurrentGameLanguage). With neither,
// the answer is empty, and a game that takes its text from Steam (Factorio started through Steam showed "Unknown key: …" on every label) ends up with no text at all.
// Valve's client also rewrites the record when it runs, leaving both blocks empty, so the blocks that exist are filled in too, not only missing ones.
enum SteamManifestLanguage {
    static let defaultLanguage = "english"      // Porthole downloads the English, public branch only

    /// `branch` other than "public" adds the BetaKey Valve's client reads to know which version of the game these files are (without it the client takes them for the
    /// public version and offers to "update" them).
    static func blockLines(language: String = defaultLanguage, branch: String = "public") -> [String] {
        let beta = branch == "public" || branch.isEmpty ? [] : ["\t\t\"BetaKey\"\t\t\"\(branch.replacingOccurrences(of: "\"", with: ""))\""]
        return ["\t\"UserConfig\"", "\t{", "\t\t\"language\"\t\t\"\(language)\""] + beta + ["\t}", "\t\"MountedConfig\"", "\t{", "\t\t\"language\"\t\t\"\(language)\""] + beta + ["\t}"]
    }

    /// The record with a language in both blocks (added, or filled in where empty), or nil when nothing should change: not an install record, or both blocks already name a
    /// language (including a different one, which is the person's or Valve's choice).
    static func adding(to text: String, language: String = defaultLanguage) -> String? {
        guard text.lowercased().contains("\"appstate\"") else { return nil }
        var lines = text.components(separatedBy: "\n")
        var changed = false
        for name in ["userconfig", "mountedconfig"] {
            if let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "\"\(name)\"" }) {
                let open = at + 1
                guard open < lines.count, lines[open].trimmingCharacters(in: .whitespaces) == "{" else { continue }
                var depth = 0, close: Int?, languageLine: Int?
                for i in open..<lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed == "{" { depth += 1 }
                    else if trimmed == "}" { depth -= 1; if depth == 0 { close = i; break } }
                    else if trimmed.lowercased().hasPrefix("\"language\"") { languageLine = i }
                }
                guard let end = close else { continue }
                let entry = "\t\t\"language\"\t\t\"\(language)\""
                if let line = languageLine {
                    let parts = lines[line].components(separatedBy: "\"")      // ["\t\t", "language", "\t\t", "english", ""]
                    guard parts.count < 4 || parts[3].isEmpty else { continue }
                    lines[line] = entry; changed = true
                } else { lines.insert(entry, at: end); changed = true }
            } else if let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "}" }) {
                let block = blockLines(language: language)
                let part = name == "userconfig" ? Array(block[0..<4]) : Array(block[4..<8])
                lines.insert(contentsOf: part, at: last); changed = true
            }
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Repairs an existing install record in place (atomically). Returns whether it changed.
    @discardableResult
    static func ensure(appID: Int, steamApps: URL, language: String = defaultLanguage) -> Bool {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: url, encoding: .utf8), let updated = adding(to: text, language: language) else { return false }
        do { try updated.write(to: url, atomically: true, encoding: .utf8); return true } catch { return false }
    }
}

/// Valve's client in the prefix reads its own language from `Software\Valve\Steam\Language` in the current user's registry. A real install always has it; this prefix never did
/// (the client was copied in, not installed), so the client had no language to give any game. Set on disk before a session starts (the registry files are only read when the session's
/// Wine server starts), with the same one-time backup the install-script bookkeeping makes.
enum SteamClientLanguage {
    private static let header = "[Software\\\\Valve\\\\Steam]"

    /// The user registry text with `Language` set under the Steam key, or nil when it already has a language.
    static func adding(to text: String, language: String = SteamManifestLanguage.defaultLanguage, now: Int = Int(Date().timeIntervalSince1970)) -> String? {
        let entry = "\"Language\"=\"\(language)\""
        var lines = text.components(separatedBy: "\n")
        if let at = lines.firstIndex(where: { $0.lowercased() == header.lowercased() || $0.lowercased().hasPrefix(header.lowercased() + " ") }) {
            var end = at + 1
            while end < lines.count, !lines[end].isEmpty, !lines[end].hasPrefix("[") { end += 1 }
            if let existing = lines[(at + 1)..<end].firstIndex(where: { $0.lowercased().hasPrefix("\"language\"=") }) {
                let value = lines[existing].dropFirst("\"Language\"=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
                guard value.isEmpty else { return nil }
                lines[existing] = entry
            } else {
                let afterTime = at + 1 < end && lines[at + 1].hasPrefix("#time=") ? at + 2 : at + 1
                lines.insert(entry, at: afterTime)
            }
            return lines.joined(separator: "\n")
        }
        let filetime = (UInt64(now) + 11_644_473_600) * 10_000_000
        var section = ["\(header) \(now)", "#time=\(String(filetime, radix: 16))", entry, ""]
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        if !lines.isEmpty { section.insert("", at: 0) }
        return (lines + section).joined(separator: "\n") + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n")
    }

    /// Sets the language in the prefix's user.reg. Returns whether it changed; false too when the prefix has no registry yet. Only while no session runs.
    @discardableResult
    static func ensure(prefix: URL, language: String = SteamManifestLanguage.defaultLanguage) -> Bool {
        let registry = prefix.appendingPathComponent("user.reg")
        guard let data = try? Data(contentsOf: registry), !data.isEmpty,
              let updated = adding(to: String(decoding: data, as: UTF8.self), language: language) else { return false }
        let backup = registry.appendingPathExtension("madeira-bak")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: registry, to: backup) }
        do { try Data(updated.utf8).write(to: registry, options: .atomic); return true } catch { return false }
    }
}
