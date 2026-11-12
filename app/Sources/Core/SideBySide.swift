// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Gets a program's libraries to where Windows' loader looks for them, for programs that keep them somewhere else.
///
/// Blender (and a few others) install their libraries in a `blender.shared` folder and name them in a side-by-side manifest (`blender.shared/blender.shared.manifest`). The runtime
/// does not read that manifest, so the program stops at start with "tbb12.dll not found" and 30 more. The libraries listed in such a manifest are linked into the program's own folder,
/// which Windows always searches first. Blender's video-device library also imports `avicap32.dll`, which the Windows layer does not have: the app carries one (Extras/) and puts it there.
///
/// Only files are created: nothing is moved or deleted except links and copies this code made earlier (kept in a list in the folder), and a file that was already there is never replaced.
enum SideBySide {
    static let ledgerName = ".porthole-sidebyside.json"

    private struct Ledger: Codable { var made: [String] = [] }

    /// The file names a side-by-side manifest lists (`<file name="tbb12.dll" .../>`). Names with a path in them are dropped.
    static func manifestFiles(_ xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<file\s[^>]*?name\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        var names: [String] = []
        for match in regex.matches(in: xml, range: range) {
            guard let r = Range(match.range(at: 1), in: xml) else { continue }
            let name = String(xml[r])
            if name.isEmpty || name.contains("/") || name.contains("\\") || name.hasPrefix(".") { continue }
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        return names
    }

    /// The machine field of a PE file (0x8664 for x64 and ARM64EC, 0xAA64 for native Arm), or nil when it is not one.
    static func machine(of url: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count == 64 else { return nil }
        let peOffset = UInt64(head[60]) | UInt64(head[61]) << 8 | UInt64(head[62]) << 16 | UInt64(head[63]) << 24
        guard peOffset < 4096, (try? handle.seek(toOffset: peOffset)) != nil, let pe = try? handle.read(upToCount: 6), pe.count == 6,
              pe[0] == 0x50, pe[1] == 0x45, pe[2] == 0, pe[3] == 0 else { return nil }
        return UInt16(pe[4]) | UInt16(pe[5]) << 8
    }

    /// Prepares `folder` (the folder of the program about to start). `extras` is the app's Extras folder (nil in tests that do not need it). Returns one line for the log per thing done.
    @discardableResult
    static func prepare(folder: URL, extras: URL?, fileManager fm: FileManager = .default) -> [String] {
        var lines: [String] = []
        guard let entries = try? fm.contentsOfDirectory(atPath: folder.path) else { return lines }
        let ledgerURL = folder.appendingPathComponent(ledgerName)
        var ledger = (try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))) ?? Ledger()
        let startLedger = ledger.made
        func present(_ name: String) -> String? { (try? fm.contentsOfDirectory(atPath: folder.path))?.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
        func ours(_ name: String) -> Bool { ledger.made.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        func attributes(_ url: URL) -> (size: UInt64, modified: Date?, inode: UInt64?)? {
            guard let a = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return ((a[.size] as? NSNumber)?.uint64Value ?? 0, a[.modificationDate] as? Date, (a[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
        /// True when the file at `target` already is `source` (the same file, or a copy of the same size and date).
        func sameFile(_ source: URL, _ target: URL) -> Bool {
            guard let s = attributes(source), let t = attributes(target) else { return false }
            if let a = s.inode, let b = t.inode, a == b { return true }
            return s.size == t.size && s.modified == t.modified
        }
        /// Puts `source` at `target`: a hard link (no second copy on the disk), or a copy where the system refuses a link.
        func place(_ source: URL, _ target: URL) -> Bool {
            if (try? fm.linkItem(at: source, to: target)) != nil { return true }
            return (try? fm.copyItem(at: source, to: target)) != nil
        }

        // 1. Libraries a side-by-side manifest lists: `<name>/<name>.manifest` next to the program (Blender: blender.shared).
        for dirName in entries.sorted() {
            let dir = folder.appendingPathComponent(dirName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let manifestName = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.caseInsensitiveCompare(dirName + ".manifest") == .orderedSame }),
                  let xml = (try? String(contentsOf: dir.appendingPathComponent(manifestName), encoding: .utf8)) ?? (try? String(contentsOf: dir.appendingPathComponent(manifestName), encoding: .isoLatin1))
            else { continue }
            let inside = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            var linked = 0, current = 0, refreshed = 0, kept = 0
            for name in manifestFiles(xml) {
                guard let real = inside.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                let source = dir.appendingPathComponent(real)
                if let there = present(name) {
                    let target = folder.appendingPathComponent(there)
                    if !ours(there) { kept += 1; continue }                 // the person's own file (or one from before this code): never replaced
                    if sameFile(source, target) { current += 1; continue }
                    guard (try? fm.removeItem(at: target)) != nil, place(source, folder.appendingPathComponent(real)) else { continue }
                    refreshed += 1
                } else {
                    guard place(source, folder.appendingPathComponent(real)) else { continue }
                    ledger.made.append(real); linked += 1
                }
            }
            if linked + refreshed > 0 || kept > 0 {
                lines.append("\(dirName): \(linked) librar\(linked == 1 ? "y" : "ies") put next to the program\(refreshed > 0 ? ", \(refreshed) refreshed" : "")\(current > 0 ? ", \(current) already there" : "")\(kept > 0 ? ", \(kept) left alone (not made here)" : "")")
            }
        }

        // 2. avicap32.dll for FFmpeg's avdevice-*.dll (the Windows layer has none): the x64 build for x64 programs, the Arm one for native Arm programs.
        if let extras,
           let device = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().first(where: { $0.lowercased().hasPrefix("avdevice-") && $0.lowercased().hasSuffix(".dll") }),
           let kind = machine(of: folder.appendingPathComponent(device)) {
            let variant = kind == 0xAA64 ? "aarch64" : "arm64ec"
            let source = extras.appendingPathComponent(variant).appendingPathComponent("avicap32.dll")
            if fm.fileExists(atPath: source.path) {
                if let there = present("avicap32.dll") {
                    let target = folder.appendingPathComponent(there)
                    if ours(there), !fm.contentsEqual(atPath: source.path, andPath: target.path) {
                        if (try? fm.removeItem(at: target)) != nil, (try? fm.copyItem(at: source, to: folder.appendingPathComponent("avicap32.dll"))) != nil { lines.append("avicap32.dll replaced by the \(variant) one (\(device) needs it)") }
                    }
                } else if (try? fm.copyItem(at: source, to: folder.appendingPathComponent("avicap32.dll"))) != nil {
                    ledger.made.append("avicap32.dll"); lines.append("avicap32.dll (\(variant)) added: \(device) imports it and the Windows layer has none")
                }
            }
        }

        if ledger.made != startLedger, let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL) }
        return lines
    }
}
