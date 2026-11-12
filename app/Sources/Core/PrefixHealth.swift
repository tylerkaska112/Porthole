// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Looks at the Wine prefix's registry file before a game starts, for registrations a launcher cannot do without, and puts right the one that is known to go wrong.
///
/// 2026-11-08 (GTA V, Rockstar's launcher): `err:ole:apartment_add_dll couldn't load in-process dll L"\0238\f9acs"` / `no class object {317d06e8-...}` (CLSID_WICImagingFactory2):
/// the launcher asked for the Windows imaging component, got a garbled path and showed "The Rockstar Games Launcher failed to initialize!". The prefix template holds
/// `C:\windows\system32\windowscodecs.dll` for that class, so the garbage was written later; and the Dock's one-time `regsvr32 windowscodecs.dll` (patch 0101) wrote new garbage again
/// (the next log read `\0238\f778p`). The Dock no longer registers windowscodecs, and this puts the value right in the file before Wine starts.
enum PrefixHealth {
    /// The imaging component's class id, and the path its registration should hold.
    static let wicCLSID = "317d06e8-5f24-433d-bdf7-79ce68d8abc2"
    static let wicPath = "C:\\windows\\system32\\windowscodecs.dll"

    enum State: Equatable {
        case registered(String)       // the in-process server as the registry names it
        case unreadable(String)       // a value that is not a path to windowscodecs.dll
        case missing                  // no such key
    }

    /// The range of the lines that belong to the key "...\\CLSID\\{clsid}\\<sub>" in a Wine registry file's text, from after the header line to the next key.
    private static func section(clsid: String, sub: String, in text: String, from: String.Index) -> (header: Range<String.Index>, body: Range<String.Index>)? {
        let header = "\\\\clsid\\\\{\(clsid)}\\\\\(sub.lowercased())]"
        guard let r = text.range(of: header, options: .caseInsensitive, range: from..<text.endIndex) else { return nil }
        let bodyStart = text[r.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
        let bodyEnd = text[bodyStart...].range(of: "\n[")?.lowerBound ?? text.endIndex
        return (r, bodyStart..<bodyEnd)
    }

    /// The in-process server of `clsid` in a Wine registry file's text ("[Software\\Classes\\CLSID\\{...}\\InprocServer32] ..." followed by `@="..."`).
    static func inprocServer(clsid: String, in text: String) -> State {
        var from = text.startIndex
        while let s = section(clsid: clsid, sub: "InprocServer32", in: text, from: from) {
            for line in text[s.body].split(separator: "\n") where line.hasPrefix("@=") {
                let v = value(of: String(line))
                return v.lowercased().hasSuffix("windowscodecs.dll") ? .registered(v) : .unreadable(v)
            }
            from = s.header.upperBound
        }
        return .missing
    }

    private static func value(of line: String) -> String {
        var v = String(line.dropFirst(2))
        if v.hasPrefix("\"") { v.removeFirst() }
        if let q = v.lastIndex(of: "\"") { v = String(v[..<q]) }
        return v.replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// The file's text with the class's in-process server set to `path` (the key added when it is not there).
    static func setInprocServer(clsid: String, to path: String, in text: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
        let line = "@=\"\(escaped)\""
        guard let s = section(clsid: clsid, sub: "InprocServer32", in: text, from: text.startIndex) else {
            let key = "[Software\\\\Classes\\\\CLSID\\\\{\(clsid.uppercased())}\\\\InprocServer32] \(Int(Date().timeIntervalSince1970))\n\(line)\n\"ThreadingModel\"=\"Both\"\n"
            return text + (text.hasSuffix("\n") ? "\n" : "\n\n") + key
        }
        var out = text
        // the body's own @= line, else right after the header
        var lineStart = s.body.lowerBound
        while lineStart < s.body.upperBound {
            let lineEnd = out[lineStart...].firstIndex(of: "\n") ?? out.endIndex
            if out[lineStart..<lineEnd].hasPrefix("@=") {
                out.replaceSubrange(lineStart..<lineEnd, with: line)
                return out
            }
            if lineEnd >= out.endIndex { break }
            lineStart = out.index(after: lineEnd)
        }
        out.insert(contentsOf: line + "\n", at: s.body.lowerBound)
        return out
    }

    /// True for a value that names no program (garbage): not empty, and none of the usual program endings in it.
    static func isGarbage(_ v: String) -> Bool {
        let l = v.lowercased()
        return !v.isEmpty && ![".dll", ".exe", ".ocx", ".ax", ".cpl", ".drv", ".sys", ".tlb"].contains(where: { l.contains($0) })
    }

    /// Every in-process and local server key of the CLSID tree: its header line up to "]" (lower case), the range of its `@=` line and that line.
    static func servers(in text: String) -> [(key: String, line: Range<String.Index>, text: String)] {
        var out: [(String, Range<String.Index>, String)] = []
        var from = text.startIndex
        while let r = text.range(of: "\\\\clsid\\\\{", options: .caseInsensitive, range: from..<text.endIndex) {
            from = r.upperBound
            let headStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let headEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let head = text[headStart..<headEnd]
            guard let close = head.firstIndex(of: "]") else { continue }
            let key = head[head.startIndex...close].lowercased()
            guard key.hasSuffix("\\\\inprocserver32]") || key.hasSuffix("\\\\localserver32]"), key.hasPrefix("[") else { continue }
            let bodyStart = headEnd < text.endIndex ? text.index(after: headEnd) : headEnd
            let bodyEnd = text[bodyStart...].range(of: "\n[")?.lowerBound ?? text.endIndex
            var ls = bodyStart
            while ls < bodyEnd {
                let le = text[ls...].firstIndex(of: "\n") ?? text.endIndex
                if text[ls..<le].hasPrefix("@=") { out.append((key, ls..<le, String(text[ls..<le]))); break }
                if le >= text.endIndex { break }
                ls = text.index(after: le)
            }
        }
        return out
    }

    /// Garbled servers of the file, as "{clsid}: value" for the log. At most `limit`.
    static func unreadableServers(in text: String, limit: Int = 12) -> (count: Int, examples: [String]) {
        var count = 0
        var examples: [String] = []
        for s in servers(in: text) where isGarbage(value(of: s.text)) {
            count += 1
            if examples.count < limit {
                let id = s.key.components(separatedBy: "{").last?.components(separatedBy: "}").first ?? "?"
                examples.append("{\(id)}: \(show(value(of: s.text)))")
            }
        }
        return (count, examples)
    }

    static func show(_ v: String) -> String { v.unicodeScalars.map { $0.value < 32 || $0.value > 126 ? String(format: "\\x%x", $0.value) : String($0) }.joined() }

    /// The file's text with every garbled server value put back from the template's (the template is a fresh prefix, so its values are right). Servers the template does not have are
    /// returned in `unknown`.
    static func restoring(_ text: String, from template: String) -> (text: String, fixed: Int, unknown: [String]) {
        var good: [String: String] = [:]
        for s in servers(in: template) where !isGarbage(value(of: s.text)) { good[s.key] = s.text }
        var edits: [(Range<String.Index>, String)] = []
        var unknown: [String] = []
        for s in servers(in: text) where isGarbage(value(of: s.text)) {
            if let line = good[s.key] { edits.append((s.line, line)) } else { unknown.append(s.key) }
        }
        var out = text
        for (range, line) in edits.reversed() { out.replaceSubrange(range, with: line) }
        return (out, edits.count, unknown)
    }

    /// Before a game starts: puts right, in the prefix's registry file, every class registration whose program is garbage, from the template; the imaging component (the one a launcher
    /// stops at) is set by hand when the template is not at hand. Wine has not started yet, so the file is the truth. A copy of the file as it was is kept once
    /// (system.reg.porthole-before-repair). Logs what it found.
    static func checkAtLaunch(prefix: URL = AppModel.prefix, template: () -> String?, log: (String) -> Void) {
        let file = prefix.appendingPathComponent("system.reg")
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .isoLatin1) else { log("[prefix] the registry file could not be read"); return }
        // A garbled value is written as \x escapes: only then is the whole file looked through (it takes a second or two on a phone)
        let bad = text.range(of: "@=\"\\x") != nil ? unreadableServers(in: text) : (count: 0, examples: [])
        let wic = inprocServer(clsid: wicCLSID, in: text)
        if bad.count == 0, case .registered(let v) = wic { log("[prefix] imaging component registered: \(v); no class registration names a garbled program"); return }
        if bad.count > 0 { log("[prefix] \(bad.count) class registration(s) name no program: " + bad.examples.joined(separator: "; ")) }
        var fixed = text
        var restored = 0
        if bad.count > 0, let t = template() {
            let r = restoring(fixed, from: t)
            fixed = r.text; restored = r.fixed
            if !r.unknown.isEmpty { log("[prefix] \(r.unknown.count) are not in the template and stay as they are: " + r.unknown.prefix(5).joined(separator: "; ")) }
        } else if bad.count > 0 { log("[prefix] the prefix template could not be read; only the imaging component is repaired") }
        if case .registered = inprocServer(clsid: wicCLSID, in: fixed) {} else { fixed = setInprocServer(clsid: wicCLSID, to: wicPath, in: fixed) }
        guard fixed != text else { return }
        let backup = prefix.appendingPathComponent("system.reg.porthole-before-repair")
        if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        guard let out = fixed.data(using: .isoLatin1), (try? out.write(to: file, options: .atomic)) != nil else { log("[prefix] the registry file could not be repaired"); return }
        log("[prefix] repaired: \(restored) class registration(s) restored from the template, imaging component \(inprocServer(clsid: wicCLSID, in: fixed) == .registered(wicPath) ? "set" : "checked") (\(wicPath))")
    }
}
