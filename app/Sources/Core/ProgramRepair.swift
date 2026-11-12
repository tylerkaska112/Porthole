// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A game whose stored program is not where it says it is, found again inside the game's own folder.
///
/// This happened for real: Steam downloads that took their program from the fallback search were stored with a damaged path
/// ("...\Ranch Simulator\mulator\Ranch_Simulator.exe": eight characters of the folder name ended up in the path), so the game could never start.
/// The cause is fixed in SteamStore; this repairs the games that already have the damaged path, and also a program that was moved inside its folder.
/// It only ever looks inside the nearest folder of the stored path that still exists, for a file with exactly the same name, and only takes a single clear answer.
enum ProgramRepair {
    /// Folders that hold many games or programs: a missing program is never searched for in there (a different game could have a file with the same name).
    static let shared: Set<String> = ["common", "steamapps", "steam", "program files", "program files (x86)", "users", "windows", "programdata", "common files"]

    /// The Windows path of the program that stands for `exe` now, or nil when there is no clear answer.
    /// `unix` and `windows` turn a Windows path into its file inside drive_c and back (a path relative to drive_c with "/" into a Windows path).
    static func find(missing exe: String, root: URL, unix: (String) -> URL?, windows: (String) -> String) -> String? {
        let fm = FileManager.default
        guard let missing = unix(exe) else { return nil }
        let name = missing.lastPathComponent.lowercased()
        guard name.hasSuffix(".exe") else { return nil }
        let base = root.resolvingSymlinksInPath().path
        // The nearest folder of the stored path that is really there.
        var dir = missing.deletingLastPathComponent()
        var isDir: ObjCBool = false
        var steps = 0
        while !(fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue) {
            let parent = dir.deletingLastPathComponent()
            steps += 1
            if parent.path == dir.path || steps > 24 { return nil }
            dir = parent
        }
        let top = dir.resolvingSymlinksInPath().path
        guard top.hasPrefix(base + "/") else { return nil }
        let depth = top.dropFirst(base.count + 1).split(separator: "/").count
        guard depth >= 2, !shared.contains(dir.lastPathComponent.lowercased()) else { return nil }
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var hits: [(rel: String, depth: Int)] = []
        for case let url as URL in walker {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(top + "/") else { continue }
            let below = full.dropFirst(top.count + 1).split(separator: "/").count
            if below > 4 { walker.skipDescendants(); continue }
            guard url.lastPathComponent.lowercased() == name else { continue }
            hits.append((String(full.dropFirst(base.count + 1)), below))
        }
        hits.sort { $0.depth < $1.depth }
        guard let first = hits.first else { return nil }
        // Two files of that name at the same depth: no way to tell which one was meant.
        if hits.count > 1, hits[1].depth == first.depth { return nil }
        return windows(first.rel)
    }
}
