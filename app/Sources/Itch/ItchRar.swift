// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// .rar archives from itch.io: RAR 4 and RAR 5, read by the libarchive that comes with iOS (itch_rar.c). Folders, links and paths are checked the way ItchSevenZip checks them:
/// nothing is written outside the destination, links are refused, and a single wrapping folder can be dropped.
enum ItchRar {
    /// Whether a file starts with a RAR signature.
    static func isRar(_ url: URL) -> Bool { irar_is_rar(url.path) != 0 }

    private static func error(_ code: Int32, _ reason: String) -> ItchZipError {
        switch Int(code) {
        case IRAR_NOT_RAR: return .invalid("This is not a .rar file.")
        case IRAR_UNSUPPORTED:
            if reason == "encrypted" { return .invalid("This .rar is password-protected.") }
            if reason == "volumes" { return .invalid("This .rar is one part of a set. Porthole can only unpack a .rar that is a single file.") }
            return .invalid("Porthole cannot unpack this .rar on this device (\(reason)).")
        case IRAR_IO: return .invalid("The .rar could not be read from the device.")
        default: return .invalid("This .rar is damaged (\(reason)). Download it again.")
        }
    }

    private final class Items {
        var names: [String] = []
        var flags: [Int32] = []
    }

    /// What the unpack writes, item by item, to the names worked out from the listing.
    private final class Output {
        let root: URL
        let names: [String?]
        let progress: @Sendable (UInt64) -> Void
        var file: FileHandle?
        var done: UInt64 = 0
        var reported: UInt64 = 0
        var failure: Error?
        init(root: URL, names: [String?], progress: @escaping @Sendable (UInt64) -> Void) { self.root = root; self.names = names; self.progress = progress }
    }

    private static let list: @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UnsafePointer<CChar>?, Int32, UInt64, UnsafeRawPointer?, Int) -> Int32 = { context, event, _, name, flags, _, _, _ in
        guard event == Int32(IRAR_BEGIN), let context else { return 0 }
        let items = Unmanaged<Items>.fromOpaque(context).takeUnretainedValue()
        items.names.append(name.map { String(cString: $0) } ?? "")
        items.flags.append(flags)
        return 0
    }

    private static let sink: @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UnsafePointer<CChar>?, Int32, UInt64, UnsafeRawPointer?, Int) -> Int32 = { context, event, item, _, _, _, data, length in
        guard let context else { return 1 }
        let output = Unmanaged<Output>.fromOpaque(context).takeUnretainedValue()
        let index = Int(item)
        if Task.isCancelled { return 1 }
        do {
            switch Int32(event) {
            case Int32(IRAR_BEGIN):
                try output.file?.close(); output.file = nil
                guard index < output.names.count, let name = output.names[index] else { return 0 }
                let target = output.root.appendingPathComponent(name)
                let fm = FileManager.default
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue { return 0 }      // the folder entry itself
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil) else { throw ItchZipError.invalid("A file from the .rar could not be written.") }
                output.file = try FileHandle(forWritingTo: target)
            case Int32(IRAR_DATA):
                if let file = output.file, let data { try file.write(contentsOf: Data(bytes: data, count: length)) }
                output.done += UInt64(length)
                if output.done - output.reported >= 4 << 20 { output.reported = output.done; output.progress(output.done) }
            default:
                try output.file?.close(); output.file = nil
            }
            return 0
        } catch {
            output.failure = error
            return 1
        }
    }

    static func extract(_ url: URL, to root: URL, stripCommonFolder: Bool, progress: @escaping @Sendable (UInt64) -> Void) throws {
        let reasonSize = 160
        var reason = [CChar](repeating: 0, count: reasonSize)
        let items = Items()
        let listed = withExtendedLifetime(items) { irar_list(url.path, list, Unmanaged.passUnretained(items).toOpaque(), &reason, reasonSize) }
        guard listed == Int32(IRAR_OK) else { throw error(listed, String(cString: reason)) }

        var paths: [String?] = []
        for (index, raw) in items.names.enumerated() {
            let flags = Int(items.flags[index])
            if flags & Int(IRAR_ITEM_OTHER) != 0 { paths.append(nil); continue }
            if flags & Int(IRAR_ITEM_LINK) != 0 { throw ItchZipError.invalid("This .rar holds a link (\(raw.prefix(40))), which Porthole will not unpack.") }
            guard let safe = GogContent.safePath(raw.replacingOccurrences(of: "\\", with: "/")) else {
                throw ItchZipError.invalid("This .rar holds an unsafe path (\(raw.prefix(40))).")
            }
            paths.append(safe)
        }
        guard paths.contains(where: { $0 != nil }) else { throw ItchZipError.invalid("The .rar file is empty.") }

        var prefix = ""
        if stripCommonFolder {
            let live = paths.compactMap { $0 }
            let firsts = Set(live.map { $0.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "" })
            var everyPathHasFolder = true
            for (index, path) in paths.enumerated() {
                guard let path else { continue }
                let directory = Int(items.flags[index]) & Int(IRAR_ITEM_DIR) != 0
                if !(path.contains("/") || directory) { everyPathHasFolder = false }
            }
            if firsts.count == 1, let only = firsts.first, !only.isEmpty, everyPathHasFolder { prefix = only + "/" }
        }

        var names: [String?] = []
        var seen = Set<String>()
        for (index, path) in paths.enumerated() {
            guard var relative = path else { names.append(nil); continue }
            let directory = Int(items.flags[index]) & Int(IRAR_ITEM_DIR) != 0
            if !prefix.isEmpty {
                if relative + (directory ? "/" : "") == prefix { names.append(nil); continue }      // the wrapping folder itself
                guard relative.hasPrefix(prefix) else { names.append(nil); continue }
                relative = String(relative.dropFirst(prefix.count))
            }
            if relative.isEmpty { names.append(nil); continue }
            if !seen.insert(relative.lowercased()).inserted, !directory { throw ItchZipError.invalid("This .rar holds two files with the same name (\(relative.prefix(40))).") }
            names.append(relative)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (index, name) in names.enumerated() {
            guard let name, Int(items.flags[index]) & Int(IRAR_ITEM_DIR) != 0 else { continue }
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let output = Output(root: root, names: names, progress: progress)
        let result = withExtendedLifetime(output) {
            irar_extract(url.path, sink, Unmanaged.passUnretained(output).toOpaque(), &reason, reasonSize)
        }
        try? output.file?.close()
        if let failure = output.failure { throw failure }
        if result == Int32(IRAR_ABORTED), Task.isCancelled { throw CancellationError() }
        guard result == Int32(IRAR_OK) else { throw error(result, String(cString: reason)) }
        progress(output.done)
    }
}
