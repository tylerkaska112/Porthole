// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Steam's own switches for which controller types Steam Input takes over, `SteamController_PS4Support` (PlayStation 4 and 5 pads), `SteamController_XBoxSupport`,
/// `SteamController_SwitchSupport` and `SteamController_GenericGamepadSupport` (names read from the strings of Valve's steamclient64.dll). With the PlayStation one off, Steam's
/// SDL layer only probes a DualSense (a read-attributes open) and never opens it to read, so a game that takes its pad from Steam Input (Portal) gets nothing. Text edit of
/// Steam's config.vdf, nothing else rewritten; the same file-editing idea as DockLaunchOptions.
enum SteamInputConfig {
    private static func tokens(_ line: String) -> [String] {
        var out: [String] = [], cur = "", inQuote = false
        for ch in line {
            if inQuote { if ch == "\"" { out.append(cur); cur = ""; inQuote = false } else { cur.append(ch) } }
            else if ch == "\"" { inQuote = true }
        }
        return out
    }

    /// `text` with `key` = `value` inside the block at `path` (lower-case names from the file's root), or nil when it already has that value or the block is not there.
    static func setting(_ key: String, _ value: String, path: [String], in text: String) -> String? {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var stack: [String] = []
        var blockOpen: Int?                        // the index of the `{` line of the wanted block
        var keyLine: Int?
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let toks = tokens(trimmed)
            if trimmed == "{" { i += 1; continue }
            if trimmed == "}" { if !stack.isEmpty { stack.removeLast() }; i += 1; continue }
            if toks.count == 1, i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces) == "{" {
                stack.append(toks[0].lowercased())
                if stack == path, blockOpen == nil { blockOpen = i + 1 }
                i += 2; continue
            }
            if toks.count >= 2, stack == path, blockOpen != nil, keyLine == nil, toks[0].lowercased() == key.lowercased() { keyLine = i }
            i += 1
        }
        guard let open = blockOpen else { return nil }
        if let line = keyLine {
            let indent = String(lines[line].prefix(while: { $0 == "\t" || $0 == " " }))
            let new = "\(indent)\"\(key)\"\t\t\"\(value)\""
            if lines[line] == new || tokens(lines[line]).dropFirst().first == value { return nil }
            lines[line] = new
        } else {
            let indent = String(lines[open].prefix(while: { $0 == "\t" || $0 == " " })) + "\t"
            lines.insert("\(indent)\"\(key)\"\t\t\"\(value)\"", at: open + 1)
        }
        return lines.joined(separator: eol)
    }

    /// The `SteamController_*` lines of a file, as written (name and value only), for the log.
    static func controllerLines(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { raw in
            let t = tokens(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            return t.count >= 2 && t[0].lowercased().hasPrefix("steamcontroller") ? "\(t[0]) = \(t[1])" : nil
        }
    }

    static var enabled: Bool { EngineOptions.value("env.PORTHOLE_STEAM_PS") != "0" }

    /// Before Steam starts: logs the controller switches Steam's config files hold now and, when Steam's controller support is downloaded and a PlayStation pad is in use, turns
    /// the PlayStation switch on. Returns whether config.vdf was changed.
    @discardableResult
    static func apply(drive: URL, playStation: Bool, log: (String) -> Void = { _ in }) -> Bool {
        let steam = drive.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        let config = steam.appendingPathComponent("config/config.vdf")
        var changed = false
        if let data = try? Data(contentsOf: config), data.count < 8 << 20 {
            let text = String(decoding: data, as: UTF8.self)
            let have = controllerLines(in: text)
            log("[steam-input] config.vdf controller switches: " + (have.isEmpty ? "none set" : have.joined(separator: ", ")))
            if enabled, playStation, SteamSDL3.installed,
               let updated = setting("SteamController_PS4Support", "1", path: ["installconfigstore", "software", "valve", "steam"], in: text) {
                do { try Data(updated.utf8).write(to: config, options: .atomic); changed = true; log("[steam-input] SteamController_PS4Support = 1 written to config.vdf") }
                catch { log("[steam-input] config.vdf not written: \(ErrorText.plain(error))") }
            }
        } else { log("[steam-input] no config.vdf yet (Steam has not run)") }
        // Where else the switches might live: the account files. Looked at, not changed.
        let userdata = steam.appendingPathComponent("userdata", isDirectory: true)
        for account in ((try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? []) where account.allSatisfy({ $0.isNumber }) {
            let file = userdata.appendingPathComponent(account).appendingPathComponent("config/localconfig.vdf")
            if let data = try? Data(contentsOf: file), data.count < 8 << 20 {
                let have = controllerLines(in: String(decoding: data, as: UTF8.self))
                if !have.isEmpty { log("[steam-input] localconfig.vdf (\(account)) controller switches: " + have.joined(separator: ", ")) }
            }
        }
        return changed
    }
}
