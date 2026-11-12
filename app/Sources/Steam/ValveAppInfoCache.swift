// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What Valve's OWN client has cached about an app (Steam/appcache/appinfo.vdf, format versions 40 and 41). When a Dock launch asks that client for "launch option N" it
/// looks N up in THIS copy, which can be older than the product information Porthole's own Steam connection just fetched: content_log.txt then says
/// "Failed running app … (entry for launch option N not found)" and the launch never starts. Reading the client's list tells us which numbers it actually has.
enum ValveAppInfoCache {
    struct Entry { let key: Int; let executable: String; let type: String; let oslist: String; let osarch: String }

    /// The app's launch entries in Valve's cache, or nil when the file or the app is not there (or the format is not one this reads).
    static func launches(appID: Int, steamFolder: URL) -> [Entry]? {
        let url = steamFolder.appendingPathComponent("appcache/appinfo.vdf")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else { return nil }
        func u32(_ at: Int) -> Int? { at + 4 <= data.count ? Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 : nil }
        func u64(_ at: Int) -> Int? { at + 8 <= data.count ? (0..<8).reduce(0) { $0 | Int(data[at + $1]) << (8 * $1) } : nil }
        guard let magic = u32(0), magic & 0xFFFFFF00 == 0x07564400 else { return nil }
        let version = magic & 0xFF
        guard version == 0x28 || version == 0x29 else { return nil }
        var strings: [String] = []
        var at = 8
        if version == 0x29 {
            guard let tableOffset = u64(8), tableOffset > 16, tableOffset + 4 <= data.count, let count = u32(tableOffset) else { return nil }
            var p = tableOffset + 4
            for _ in 0..<min(count, 200_000) {
                var end = p
                while end < data.count, data[end] != 0 { end += 1 }
                guard end < data.count else { break }
                strings.append(String(decoding: data[p..<end], as: UTF8.self)); p = end + 1
            }
            at = 16
        }
        // Entries: appid, size, then size bytes (info state 4, updated 4, token 8, sha1 20, change number 4, binary sha1 20, then the keyvalues).
        while let appid = u32(at), appid != 0, let size = u32(at + 4), size > 68, at + 8 + size <= data.count {
            if appid == appID {
                let body = at + 8 + 4 + 4 + 8 + 20 + 4 + 20
                return parseLaunch(data, from: body, to: at + 8 + size, strings: strings, withStringTable: version == 0x29)
            }
            at += 8 + size
        }
        return nil
    }

    private static func parseLaunch(_ data: Data, from start: Int, to end: Int, strings: [String], withStringTable: Bool) -> [Entry]? {
        var at = start
        func u32() -> Int? { guard at + 4 <= end else { return nil }; defer { at += 4 }; return Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        func cString() -> String? {
            var e = at
            while e < end, data[e] != 0 { e += 1 }
            guard e < end else { return nil }
            defer { at = e + 1 }
            return String(decoding: data[at..<e], as: UTF8.self)
        }
        func name() -> String? {
            if withStringTable { guard let i = u32(), i >= 0, i < strings.count else { return nil }; return strings[i] }
            return cString()
        }
        func skipValue(_ type: UInt8) -> Bool {
            switch type {
            case 1: return cString() != nil
            case 2, 3, 4, 6: return u32() != nil
            case 7, 10: at += 8; return at <= end
            case 5: while at + 1 < end { let w = data[at] | data[at + 1]; at += 2; if w == 0 { return true } }; return false
            default: return false
            }
        }
        // Reads one object into a tree of [String: Any]; only strings are kept (what the launch entries need).
        func object(depth: Int) -> [String: Any]? {
            guard depth < 24 else { return nil }
            var result: [String: Any] = [:]
            while at < end {
                let type = data[at]; at += 1
                if type == 8 { return result }
                guard let key = name() else { return nil }
                if type == 0 { guard let child = object(depth: depth + 1) else { return nil }; result[key] = child }
                else if type == 1 { guard let text = cString() else { return nil }; result[key] = text }
                else if !skipValue(type) { return nil }
            }
            return result
        }
        guard let root = object(depth: 0) else { return nil }
        let app = (root["appinfo"] as? [String: Any]) ?? root
        guard let config = app["config"] as? [String: Any], let launch = config["launch"] as? [String: Any] else { return [] }
        return launch.keys.compactMap { key -> Entry? in
            guard let n = Int(key), let node = launch[key] as? [String: Any], let exe = node["executable"] as? String, !exe.isEmpty else { return nil }
            let cfg = node["config"] as? [String: Any]
            return Entry(key: n, executable: exe, type: (node["type"] as? String) ?? "", oslist: ((cfg?["oslist"] as? String) ?? "").lowercased(), osarch: (cfg?["osarch"] as? String) ?? "")
        }.sorted { $0.key < $1.key }
    }

    /// The number to ask Valve's client for, picked from ITS list the way SteamLaunchOption.dockDefaultKey picks from ours; nil when its list has no usable entry.
    static func defaultKey(in entries: [Entry]) -> Int? {
        func pick(_ list: [Entry]) -> Int? {
            let windows = list.filter { $0.oslist.isEmpty || $0.oslist.contains("windows") }
            let suitable = windows.filter { $0.osarch.isEmpty || $0.osarch == "64" }
            return (suitable.isEmpty ? (windows.isEmpty ? list : windows) : suitable).map(\.key).min()
        }
        // No ordinary entry (PAYDAY 3: entries 1 and 11, both of a numbered kind): the lowest-numbered Windows entry of any kind.
        return pick(entries.filter { ["", "default"].contains($0.type.lowercased()) }) ?? pick(entries)
    }
}
