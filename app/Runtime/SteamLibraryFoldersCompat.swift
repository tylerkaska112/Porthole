// Porthole: the SSD library's Steam registration (PR #235 model), kept beside upstream's multi-drive code. Foundation only.
import Foundation

extension SteamInstallPaths {
    static func isManaged(library: String, storageID: String) -> Bool {
        library.caseInsensitiveCompare(storageID == "internal" ? libraryRelative : "steamapps") == .orderedSame
    }
}

/// Register the one external root with Valve's client while no Wine session is
/// running. Preserve existing libraries and unknown fields; refuse malformed
/// metadata instead of replacing it with an empty document.
enum SteamLibraryFolders {
    /// verifiedAliasOwnerID comes from Madeira's private prefix record, after the
    /// caller validates the SSD marker and both filesystem mappings. Steam can
    /// rewrite libraryfolders.vdf without preserving our custom ownership field.
    static func register(externalID: String, name: String, apps: [Int: Int64], drive: URL,
                         verifiedAliasOwnerID: String? = nil) throws {
        guard UUID(uuidString: externalID) != nil else { throw SteamStorageError.invalidRecord }
        let file = try SteamStoragePath.native(SteamInstallPaths.libraryRelative + "/libraryfolders.vdf", root: drive)
        var root: [String: SteamValue] = [:]
        do {
            let data = try Data(contentsOf: file)
            var parser = try SteamKeyValues(data)
            root = try parser.read().fields
            guard root["libraryfolders"] != nil else { throw SteamStorageError.invalidRecord }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
        var folders = root["libraryfolders"]?.fields ?? [:]
        if folders.isEmpty {
            folders["0"] = .object(["path": .text("C:\\Program Files (x86)\\Steam"), "apps": .object([:])])
        }
        let owned = folders.first { $0.value["madeira_library_id"]?.string == externalID }?.key
        let existingAlias = folders.first {
            let path = $0.value["path"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "\\/")).lowercased()
            return path == SteamStoragePath.externalWindowsRoot.lowercased()
        }?.key
        // Recover a Steam-rewritten entry only with independent, verified
        // ownership. An explicit different ID or an unrelated E: stays untouched.
        if let existingAlias, owned != existingAlias {
            guard owned == nil,
                  folders[existingAlias]?["madeira_library_id"] == nil,
                  verifiedAliasOwnerID == externalID else {
                throw SteamStorageError.mappingConflict
            }
        }
        let key = owned ?? existingAlias ?? String((folders.keys.compactMap(Int.init).max() ?? 0) + 1)
        var entry = folders[key]?.fields ?? [:]
        entry["path"] = .text(SteamStoragePath.externalWindowsRoot)
        entry["label"] = .text(name)
        entry["madeira_library_id"] = .text(externalID)
        entry["apps"] = .object(Dictionary(uniqueKeysWithValues: apps.map { (String($0.key), .text(String(max(0, $0.value)))) }))
        folders[key] = .object(entry)
        root["libraryfolders"] = .object(folders)
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func encode(_ fields: [String: SteamValue], indent: String = "") -> String {
            fields.keys.sorted().map { key in
                switch fields[key]! {
                case .text(let value): return indent + quote(key) + "\t" + quote(value) + "\n"
                case .object(let nested): return indent + quote(key) + "\n" + indent + "{\n" + encode(nested, indent: indent + "\t") + indent + "}\n"
                }
            }.joined()
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(encode(root).utf8).write(to: file, options: .atomic)
    }
}
