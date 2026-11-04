// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Unpacking a .7z from itch.io, and archives inside an unpacked download. The 7z reader (itch_7z.c) is Madeira's, from willfaust/Madeira (app/Madeira/SwiftItch,
// GPL-3.0-or-later, Madeira Converter Exception); this file is the Swift side written for Porthole after Madeira's ItchArchive.swift. The archive is read from its file a piece at a
// time and every folder is decoded as a stream, so a solid archive of several GB never sits in memory. Zip files go through ItchZip as before.

import Foundation

enum ItchSevenZip {
    /// Whether a file starts with the 7z signature.
    static func is7z(_ url: URL) -> Bool { i7z_is_7z(url.path) != 0 }

    /// Whether a file starts like a zip.
    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4b, 0x03, 0x04])
    }

    private static func error(_ code: Int32, _ reason: String) -> ItchZipError {
        switch Int(code) {
        case I7Z_NOT_7Z: return .invalid("This is not a .7z file.")
        case I7Z_UNSUPPORTED:
            return .invalid(reason == "encrypted" ? "This .7z is password-protected." : "Porthole cannot unpack this .7z yet (\(reason)).")
        case I7Z_MEMORY: return .invalid("This .7z needs more memory to unpack than this device gives it.")
        case I7Z_IO: return .invalid("The .7z could not be read from the device.")
        default: return .invalid("This .7z is damaged (\(reason)). Download it again.")
        }
    }

    /// The C reader's output, written under the destination folder.
    private final class Output {
        let root: URL
        let names: [String?]
        let progress: @Sendable (UInt64) -> Void
        var file: FileHandle?
        var done: UInt64 = 0
        var reported: UInt64 = 0
        var failure: Error?

        init(root: URL, names: [String?], progress: @escaping @Sendable (UInt64) -> Void) {
            self.root = root; self.names = names; self.progress = progress
        }

        func handle(_ event: Int32, _ item: UInt32, _ data: UnsafePointer<UInt8>?, _ length: Int) -> Int32 {
            do {
                switch Int(event) {
                case I7Z_BEGIN:
                    try Task.checkCancellation()
                    guard Int(item) < names.count, let name = names[Int(item)] else { throw ItchZipError.invalid("This .7z is damaged (item).") }
                    let target = root.appendingPathComponent(name)
                    let fm = FileManager.default
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard fm.createFile(atPath: target.path, contents: nil) else { throw ItchZipError.invalid("A file from the .7z could not be written.") }
                    file = try FileHandle(forWritingTo: target)
                case I7Z_DATA:
                    guard let file, let data else { throw ItchZipError.invalid("This .7z is damaged (order).") }
                    try file.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: length, deallocator: .none))
                    done += UInt64(length)
                    if done - reported >= 8 << 20 {
                        reported = done
                        progress(done)
                        try Task.checkCancellation()
                    }
                default:
                    try file?.close()
                    file = nil
                }
                return 0
            } catch {
                failure = error
                try? file?.close()
                file = nil
                return 1
            }
        }
    }

    private static let sink: i7z_sink = { context, event, item, data, length in
        guard let context else { return 1 }
        return Unmanaged<Output>.fromOpaque(context).takeUnretainedValue().handle(event, item, data, length)
    }

    /// Unpacks the .7z `url` under `root` (made if needed). A single wrapping folder is left out of the paths when `stripCommonFolder` is set. Names that leave the folder, links,
    /// and two names Windows would see as one (drive_c is case-insensitive) stop the unpack. The caller removes `root` again on failure.
    static func extract(_ url: URL, to root: URL, stripCommonFolder: Bool, progress: @escaping @Sendable (UInt64) -> Void) throws {
        var opened: OpaquePointer?
        let reasonSize = 64
        var reason = [CChar](repeating: 0, count: reasonSize)
        let status = i7z_open(url.path, &opened, &reason, reasonSize)
        guard status == Int32(I7Z_OK), let z = opened else { throw error(status, String(cString: reason)) }
        defer { i7z_close(z) }

        var paths: [String?] = []
        for item in 0..<i7z_count(z) {
            let flags = Int(i7z_flags(z, item))
            let raw = String(cString: i7z_name(z, item))
            if flags & I7Z_ITEM_ANTI != 0 { paths.append(nil); continue }
            if flags & I7Z_ITEM_LINK != 0 { throw ItchZipError.invalid("This .7z holds a link (\(raw.prefix(40))), which Porthole will not unpack.") }
            guard let safe = GogContent.safePath(raw.replacingOccurrences(of: "\\", with: "/")) else {
                throw ItchZipError.invalid("This .7z holds an unsafe path (\(raw.prefix(40))).")
            }
            paths.append(safe)
        }
        guard paths.contains(where: { $0 != nil }) else { throw ItchZipError.invalid("The .7z file is empty.") }

        var prefix = ""
        if stripCommonFolder {
            let live = paths.compactMap { $0 }
            let firsts = Set(live.map { $0.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "" })
            var everyPathHasFolder = true
            for (item, path) in paths.enumerated() {
                guard let path else { continue }
                let directory = Int(i7z_flags(z, UInt32(item))) & I7Z_ITEM_DIR != 0
                if !(path.contains("/") || directory) { everyPathHasFolder = false }
            }
            if firsts.count == 1, let only = firsts.first, !only.isEmpty, everyPathHasFolder { prefix = only + "/" }
        }

        var names: [String?] = []
        var seen = Set<String>()
        for (item, path) in paths.enumerated() {
            guard var relative = path else { names.append(nil); continue }
            let directory = Int(i7z_flags(z, UInt32(item))) & I7Z_ITEM_DIR != 0
            if !prefix.isEmpty {
                if relative + (directory ? "/" : "") == prefix { names.append(nil); continue }   // the wrapping folder itself
                guard relative.hasPrefix(prefix) else { names.append(nil); continue }
                relative = String(relative.dropFirst(prefix.count))
            }
            if relative.isEmpty { names.append(nil); continue }
            if !seen.insert(relative.lowercased()).inserted, !directory { throw ItchZipError.invalid("This .7z holds two files with the same name (\(relative.prefix(40))).") }
            names.append(relative)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Folders and empty files first: they have no data in the archive.
        for (item, name) in names.enumerated() {
            guard let name else { continue }
            let flags = Int(i7z_flags(z, UInt32(item)))
            let target = root.appendingPathComponent(name)
            if flags & I7Z_ITEM_DIR != 0 {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if flags & I7Z_ITEM_STREAM == 0 {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil) else { throw ItchZipError.invalid("A file from the .7z could not be written.") }
            }
        }
        let output = Output(root: root, names: names, progress: progress)
        let result = withExtendedLifetime(output) {
            i7z_extract(z, sink, Unmanaged.passUnretained(output).toOpaque(), &reason, reasonSize)
        }
        if let failure = output.failure { throw failure }
        guard result == Int32(I7Z_OK) else { throw error(result, String(cString: reason)) }
        progress(output.done)
    }

    /// Archives inside an unpacked download: some itch.io builds are a .zip that holds the game's real archive (a .7z and a README, say). Every .zip, .7z and .rar within two levels of
    /// `folder` unpacks where it lies, its files beside it, and then goes. Returns how many were unpacked.
    static func unpackInner(in folder: URL) throws -> Int {
        let fm = FileManager.default
        var archives: [URL] = []
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
                if relative.split(separator: "/").count > 2 { walker.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                guard ext == "7z" || ext == "zip" || ext == "rar" else { continue }
                if isZip(url) || is7z(url) || ItchRar.isRar(url) { archives.append(url) }
            }
        }
        var unpacked = 0
        for archive in archives {
            try Task.checkCancellation()
            let parent = archive.deletingLastPathComponent()
            let inner = parent.appendingPathComponent(".porthole-inner", isDirectory: true)
            try? fm.removeItem(at: inner)
            do {
                if ItchRar.isRar(archive) { try ItchRar.extract(archive, to: inner, stripCommonFolder: false) { _ in } }
                else if is7z(archive) { try extract(archive, to: inner, stripCommonFolder: false) { _ in } }
                else { try ItchZip.extract(archive, to: inner, stripCommonFolder: false) { _ in } }
                // The archive's files join its folder; one already there is replaced.
                let existing = Dictionary(((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                for name in try fm.contentsOfDirectory(atPath: inner.path) {
                    if let old = existing[name.lowercased()], old != inner.lastPathComponent { try fm.removeItem(at: parent.appendingPathComponent(old)) }
                    try fm.moveItem(at: inner.appendingPathComponent(name), to: parent.appendingPathComponent(name))
                }
                try fm.removeItem(at: inner)
            } catch {
                try? fm.removeItem(at: inner)
                throw error
            }
            try? fm.removeItem(at: archive)
            unpacked += 1
        }
        return unpacked
    }
}
