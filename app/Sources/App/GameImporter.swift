// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Copies a game folder picked in the Files app into drive_c/Games/<name>, with progress, and finds the programs inside it.
/// (iOS only lets the app read a folder the person picked, and Wine only sees drive_c, so the folder has to be copied.)
final class GameImporter: @unchecked Sendable {
    struct Progress: Sendable { var copied: Int64; var total: Int64; var file: String }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case notEnoughSpace(need: Int64, free: Int64)
        case cancelled
        case copyFailed(String, String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let n): "Could not read “\(n)”. If the folder is in iCloud Drive, open it in Files and download it first (tap the cloud icon), then try again."
            case .notEnoughSpace(let need, let free): "Not enough free space: the game needs \(Self.size(need)) and the phone has \(Self.size(free)) free."
            case .cancelled: "Cancelled."
            case .copyFailed(let f, let why): "Copying “\(f)” failed: \(why)"
            }
        }
        static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    }

    private let lock = NSLock()
    private var cancelFlag = false
    func cancel() { lock.lock(); cancelFlag = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }

    /// Destination folder for a game called `name` (never overwrites an existing one).
    static func destination(for name: String) -> URL {
        let games = AppModel.driveC.appendingPathComponent("Games")
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        var url = games.appendingPathComponent(clean.isEmpty ? "Game" : clean)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = games.appendingPathComponent("\(clean) \(n)"); n += 1 }
        return url
    }

    /// Runs on a background thread. Returns the new folder. `progress` is called often; the caller throttles what it shows.
    func run(from source: URL, progress: @escaping @Sendable (Progress) -> Void) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let name = source.lastPathComponent

        var files: [(src: URL, rel: String, size: Int64)] = []
        var dirs: [String] = []
        var total: Int64 = 0
        var coordError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordError) { root in
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else {
                failure = ImportError.unreadable(name); return
            }
            let base = root.resolvingSymlinksInPath().path
            for case let url as URL in walker {
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(base + "/") else { continue }
                let rel = String(full.dropFirst(base.count + 1))
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true { dirs.append(rel) } else { let s = Int64(v?.fileSize ?? 0); files.append((url, rel, s)); total += s }
            }
        }
        if let coordError { throw coordError }
        if let failure { throw failure }
        LogStore.shared.log("[import] \(name): \(files.count) file(s), \(dirs.count) folder(s), \(ImportError.size(total)); access to the folder: \(scoped ? "granted" : "not needed or refused")")
        if files.isEmpty && dirs.isEmpty { throw ImportError.unreadable(name) }

        let free = (try? AppModel.driveC.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if free < total + 512_000_000 { throw ImportError.notEnoughSpace(need: total, free: free) }

        let dest = Self.destination(for: name)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            for d in dirs { try fm.createDirectory(at: dest.appendingPathComponent(d), withIntermediateDirectories: true) }
            var copied: Int64 = 0
            var lastReport = Date.distantPast
            let chunk = 8 * 1024 * 1024
            for f in files {
                if isCancelled { throw ImportError.cancelled }
                let out = dest.appendingPathComponent(f.rel)
                guard let input = try? FileHandle(forReadingFrom: f.src) else { throw ImportError.unreadable(f.rel) }
                defer { try? input.close() }
                fm.createFile(atPath: out.path, contents: nil)
                guard let output = try? FileHandle(forWritingTo: out) else { throw ImportError.copyFailed(f.rel, "cannot create the file") }
                defer { try? output.close() }
                while true {
                    if isCancelled { throw ImportError.cancelled }
                    let data: Data?
                    do { data = try autoreleasepool { try input.read(upToCount: chunk) } } catch { throw ImportError.unreadable(f.rel) }
                    guard let data, !data.isEmpty else { break }
                    do { try output.write(contentsOf: data) } catch { throw ImportError.copyFailed(f.rel, error.localizedDescription) }
                    copied += Int64(data.count)
                    if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(Progress(copied: copied, total: total, file: f.rel)) }
                }
            }
            progress(Progress(copied: total, total: total, file: ""))
        } catch {
            try? fm.removeItem(at: dest)   // never leave a half-copied game behind
            throw error
        }
        return dest
    }

    /// Programs (.exe) inside an imported folder, as Windows paths, most likely main program first.
    static func programs(in folder: URL) -> [String] {
        let root = folder.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let driveRoot = AppModel.driveC.resolvingSymlinksInPath().path
        var out: [(path: String, depth: Int)] = []
        for case let url as URL in walker {
            let full = url.resolvingSymlinksInPath().path
            let comps = full.dropFirst(root.path.count).split(separator: "/")
            if comps.count > 5 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe", full.hasPrefix(driveRoot + "/") else { continue }
            let file = url.lastPathComponent.lowercased()
            if file.hasPrefix("unins") || file.contains("crashpad") || file.contains("crashreport") || file.contains("setup") || file.hasPrefix("vc_redist") || file.hasPrefix("dxsetup") || file.contains("redist") || file.hasPrefix("dotnet") { continue }
            let rel = String(full.dropFirst(driveRoot.count + 1))
            out.append((AppModel.windowsPath(forRelative: rel), comps.count))
        }
        // Shallow programs first, then alphabetical.
        return out.sorted { $0.depth != $1.depth ? $0.depth < $1.depth : $0.path.lowercased() < $1.path.lowercased() }.map(\.path)
    }
}
