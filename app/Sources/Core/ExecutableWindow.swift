// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The runtime keeps a 128 MB stretch of address space free at 0x140000000 for the one kind of program that cannot live anywhere else: a 64-bit .exe built to load at 0x140000000
/// with its relocation table stripped (Red Dead Redemption 2 is one). That reserved stretch sits in the middle of the only band of addresses the translator's code pool may use, and
/// cuts it into pieces: the pool is asked for 896 MB and gets 544 to 635 MB. Most programs can be moved, so for them the reservation is pointless and costs the game a third of its pool.
/// This decides, before the pool is allocated, whether a game's programs allow giving the stretch back. Any doubt keeps it (the previous behaviour).
enum ExecutableWindow {
    static let defaultsKey = "f4.releaseExeWindow"
    /// On unless the person turned it off (Settings > Advanced): the way back to the previous behaviour.
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    static let windowBase: UInt64 = 0x1_4000_0000
    static let windowSize: UInt64 = 0x800_0000

    struct Image: Equatable {
        var is64Bit: Bool
        var imageBase: UInt64
        var relocationsStripped: Bool     // the file says its relocations were removed, or its relocation table is empty
    }

    /// What a program's headers say, or nil when they are not a readable PE header.
    static func parse(header data: Data) -> Image? {
        func u16(_ o: Int) -> UInt64? { o >= 0 && o + 2 <= data.count ? UInt64(data[data.startIndex + o]) | UInt64(data[data.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt64? { guard let a = u16(o), let b = u16(o + 2) else { return nil }; return a | b << 16 }
        func u64(_ o: Int) -> UInt64? { guard let a = u32(o), let b = u32(o + 4) else { return nil }; return a | b << 32 }
        guard u16(0) == 0x5A4D, let peOffset = u32(0x3C).map(Int.init), peOffset > 0, peOffset < 4096, u32(peOffset) == 0x0000_4550 else { return nil }
        guard let characteristics = u16(peOffset + 22), let sizeOfOptional = u16(peOffset + 20), sizeOfOptional >= 96 else { return nil }
        let opt = peOffset + 24
        guard let magic = u16(opt) else { return nil }
        let is64 = magic == 0x20B
        guard is64 || magic == 0x10B else { return nil }
        guard let base = is64 ? u64(opt + 24) : u32(opt + 28) else { return nil }
        let directories = is64 ? opt + 112 : opt + 96
        let relocationSize = u32(directories + 5 * 8 + 4) ?? 0                    // data directory 5 = base relocations
        let stripped = characteristics & 0x0001 != 0 || relocationSize == 0
        return Image(is64Bit: is64, imageBase: base, relocationsStripped: stripped)
    }

    /// Whether this program can only run if it is loaded at its own address inside the reserved stretch.
    static func needsWindow(_ image: Image) -> Bool {
        image.relocationsStripped && image.imageBase >= windowBase && image.imageBase < windowBase + windowSize
    }

    /// Folders that hold installers and runtimes, not the game: their programs never run the game's code.
    private static let redistFolders: Set<String> = ["_commonredist", "redist", "redistributables", "__installer", "directx", "vcredist", "dotnetfx", "support"]

    /// The reason the stretch can be given back for the game whose main program is `exe`, or nil when it must be kept: every .exe in that folder is read, and every one in the folders
    /// below it (an Unreal game starts from a small program in its main folder and runs `<Game>/Binaries/Win64/<Game>-Win64-Shipping.exe`, which is the one that cannot move: FINAL FANTASY
    /// RESONANCE loads its 487 MB program at 0x140000000 with its relocations stripped, and failed with status c0000018 when the stretch was given back because only the launcher had been read).
    /// One that needs the stretch, or any that cannot be read at all, keeps it.
    static func releaseReason(forProgram exe: URL, fileManager fm: FileManager = .default) -> (release: Bool, text: String) {
        guard enabled else { return (false, "turned off in Settings") }
        guard let main = read(exe), let mainImage = parse(header: main) else { return (false, "\(exe.lastPathComponent) could not be read") }
        if needsWindow(mainImage) { return (false, "\(exe.lastPathComponent) cannot be moved (no relocations, loads at 0x\(String(mainImage.imageBase, radix: 16)))") }
        let folder = exe.deletingLastPathComponent()
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".exe") }.sorted().prefix(60)
        var checked = 1
        for name in names where name.caseInsensitiveCompare(exe.lastPathComponent) != .orderedSame {
            guard let data = read(folder.appendingPathComponent(name)), let image = parse(header: data) else { continue }     // data files named .exe are not programs
            if needsWindow(image) { return (false, "\(name) in the same folder cannot be moved (no relocations, loads at 0x\(String(image.imageBase, radix: 16)))") }
            checked += 1
        }
        for url in programs(below: folder, fileManager: fm) {
            guard let data = read(url), let image = parse(header: data) else { continue }
            let base = folder.resolvingSymlinksInPath().path, full = url.resolvingSymlinksInPath().path
            let shown = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            if needsWindow(image) { return (false, "\(shown) cannot be moved (no relocations, loads at 0x\(String(image.imageBase, radix: 16)))") }
            checked += 1
        }
        return (true, "\(checked) program\(checked == 1 ? "" : "s") in the game's folder can be moved in memory")
    }

    /// The .exe files in the folders below `folder`, down to four folders deep (`depth` counts the main folder too), nearest first, without installer and runtime folders. At most 80 programs are returned and 4000 entries looked at,
    /// so a big game folder is not walked for long.
    static func programs(below folder: URL, fileManager fm: FileManager = .default, depth: Int = 5, limit: Int = 80) -> [URL] {
        var found: [URL] = []
        var level = [folder]
        var visited = 0
        for _ in 0..<depth {
            var next: [URL] = []
            for dir in level {
                let entries = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for entry in entries {
                    visited += 1
                    if visited > 4000 || found.count >= limit { return found }
                    let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    if isDirectory {
                        if !redistFolders.contains(entry.lastPathComponent.lowercased()) { next.append(entry) }
                    } else if dir != folder, entry.pathExtension.lowercased() == "exe" {
                        found.append(entry)
                    }
                }
            }
            level = next
        }
        return found
    }

    private static func read(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 4096)
    }
}
