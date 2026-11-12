// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CryptoKit

// Steam Cloud, download only: before a game is started through Steam, bring this person's own cloud files for it onto the device, the way Valve's client does before
// it launches a game. Written for Porthole from Steam's published service messages (Cloud.GetAppFileChangelist and Cloud.ClientFileDownload); nothing from another
// client's code. Nothing is ever uploaded or changed on Steam's side: this reads the person's files and writes them next to the game.
//
// Safe by construction: a file is written only after its SHA-1 matches the one Steam lists, a newer local file is never replaced, an older one is kept as ".porthole-backup",
// and a path that would leave the Windows user's folders is refused.

// MARK: - What Steam sends

struct SteamCloudFile: Equatable {
    var name: String                 // as Steam lists it: "%WinAppDataRoaming%Factorio/saves/main.zip"
    var sha1: Data
    var timestamp: UInt64            // seconds since 1970
    var size: Int
    var persistState: Int            // 0 = kept, 1 = forgotten, 2 = deleted
    var platforms: UInt32            // bit 0 = Windows; all bits when Steam does not say
    var pathPrefixIndex: Int?

    /// A file this device should have: kept (not deleted or forgotten) and meant for Windows. Steam does not always say which platforms (0 or all bits mean any).
    var isWanted: Bool { persistState == 0 && (platforms == 0 || (platforms & 1) != 0) }

    /// The full name. Steam lists names relative to one of a short table of prefixes (the folder every file of a game shares), so a name like "main.zip"
    /// with prefix "%WinAppDataRoaming%Factorio/saves/" is the file "%WinAppDataRoaming%Factorio/saves/main.zip". A name that already starts with a root is used as it is.
    func fullName(prefixes: [String]) -> String {
        if name.hasPrefix("%") { return name }
        guard let index = pathPrefixIndex, index >= 0, index < prefixes.count else { return name }
        return prefixes[index] + name
    }
}

struct SteamCloudChangelist: Equatable {
    var currentChange: UInt64
    var files: [SteamCloudFile]
    var pathPrefixes: [String]
}

struct SteamCloudDownloadInfo: Equatable {
    var host: String
    var path: String
    var https: Bool
    var headers: [String: String]
    var fileSize: Int                // what is served
    var rawSize: Int                 // what the file is once unpacked
    var sha1: Data
    var timestamp: UInt64
    var explicitDelete: Bool
    var encrypted: Bool

    var url: URL? {
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
        // Always https, whatever Steam's answer says: the request can carry cookies or tokens in its headers, and the file is a person's save.
        return URL(string: "https://" + host + (path.hasPrefix("/") ? path : "/" + path))
    }
}

enum SteamCloudMessages {
    /// CCloud_GetAppFileChangelist_Request: appid=1, synced_change_number=2 (0 = the whole list).
    static func changelistRequest(appID: Int, syncedChange: UInt64 = 0) -> Data {
        var w = PBWriter(); w.varint(1, UInt64(appID)); w.varint(2, syncedChange); return w.data
    }

    /// CCloud_GetAppFileChangelist_Response: current_change_number=1, files=2 {file_name=1, sha_file=2, time_stamp=3, raw_file_size=4, persist_state=5, platforms_to_sync=6,
    /// path_prefix_index=7}, path_prefixes=4.
    static func parseChangelist(_ body: Data) -> SteamCloudChangelist? {
        guard let fields = PBFields(body) else { return nil }
        let files: [SteamCloudFile] = fields.messages(2).compactMap { entry in
            guard let name = entry.string(1), !name.isEmpty else { return nil }
            return SteamCloudFile(name: name, sha1: entry.data(2) ?? Data(), timestamp: entry.uint(3) ?? 0, size: Int(entry.uint(4) ?? 0),
                                  persistState: Int(entry.uint(5) ?? 0), platforms: UInt32(truncatingIfNeeded: entry.uint(6) ?? 0xFFFF_FFFF),
                                  pathPrefixIndex: entry.uint(7).map { Int($0) })
        }
        let prefixes = (fields.values[4] ?? []).compactMap { value -> String? in if case .bytes(let d) = value { return String(data: d, encoding: .utf8) } else { return nil } }
        return SteamCloudChangelist(currentChange: fields.uint(1) ?? 0, files: files, pathPrefixes: prefixes)
    }

    /// CCloud_ClientFileDownload_Request: appid=1, filename=2.
    static func downloadRequest(appID: Int, fileName: String) -> Data {
        var w = PBWriter(); w.varint(1, UInt64(appID)); w.string(2, fileName); return w.data
    }

    /// CCloud_ClientFileDownload_Response: file_size=2, raw_file_size=3, sha_file=4, time_stamp=5, is_explicit_delete=6, url_host=7, url_path=8, use_https=9,
    /// request_headers=10 {name=1, value=2}, encrypted=11.
    static func parseDownload(_ body: Data) -> SteamCloudDownloadInfo? {
        guard let fields = PBFields(body), let host = fields.string(7), let path = fields.string(8) else { return nil }
        var headers: [String: String] = [:]
        for header in fields.messages(10) { if let name = header.string(1), let value = header.string(2) { headers[name] = value } }
        return SteamCloudDownloadInfo(host: host, path: path, https: fields.bool(9) ?? true, headers: headers, fileSize: Int(fields.uint(2) ?? 0),
                                      rawSize: Int(fields.uint(3) ?? 0), sha1: fields.data(4) ?? Data(), timestamp: fields.uint(5) ?? 0,
                                      explicitDelete: fields.bool(6) ?? false, encrypted: fields.bool(11) ?? false)
    }
}

// MARK: - Where a cloud file belongs on this device

enum SteamCloudLocation {
    /// "%WinAppDataRoaming%Factorio/saves/main.zip" -> ("WinAppDataRoaming", "Factorio/saves/main.zip"). A name without a root belongs to Steam's own per-game folder (root "").
    static func split(_ name: String) -> (root: String, relative: String) {
        guard name.hasPrefix("%"), let end = name.dropFirst().firstIndex(of: "%") else { return ("", name) }
        return (String(name[name.index(after: name.startIndex)..<end]), String(name[name.index(after: end)...]))
    }

    /// Plain, relative and staying inside the folder it is joined to.
    static func isSafe(relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("\\"), !relative.contains("\0"), !relative.contains(":") else { return false }
        let parts = relative.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !parts.isEmpty && !parts.contains("..") && !parts.contains(".")
    }

    /// The name Wine runs games as, worked out the way the runtime does it (loader_ios.c set_home_dir): $USER if set, else the system account's name ("mobile" on iOS),
    /// without any folder part. The prefix template also contains a "mythic" user folder that nothing runs as, so the folder names cannot be trusted to say which one is used.
    static func runtimeUserName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var name = environment["USER"] ?? ""
        if name.isEmpty, let entry = getpwuid(getuid()), let raw = entry.pointee.pw_name { name = String(cString: raw) }
        if name.isEmpty { name = "wine" }
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        return name
    }

    /// The Windows user folder games use inside the prefix. nil while the prefix has no users folder yet (it is made on the first start of Wine; nothing is created here).
    static func windowsUser(in driveC: URL, runtimeUser: String = runtimeUserName(), fileManager fm: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: driveC.appendingPathComponent("users").path, isDirectory: &isDirectory), isDirectory.boolValue, !runtimeUser.isEmpty,
              runtimeUser.caseInsensitiveCompare("Public") != .orderedSame, isSafe(relative: runtimeUser) else { return nil }
        return runtimeUser
    }

    /// Where Steam keeps the files a game saves through its own API (no root in the name): `Steam/userdata/<account>/<app>/remote`, which Valve's client reads and writes inside the prefix.
    static func defaultRemoteFolder(driveC: URL, account: String, appID: Int) -> URL? {
        guard !account.isEmpty, account != "0", account.allSatisfy({ $0.isNumber }) else { return nil }
        return driveC.appendingPathComponent("Program Files (x86)/Steam/userdata/\(account)/\(appID)/remote", isDirectory: true)
    }

    /// nil for a root this device has no place for (Mac and Linux folders, or Steam's own folder when `defaultRemote` is not known) or an unsafe name.
    static func localURL(for name: String, driveC: URL, windowsUser: String, installFolder: URL?, defaultRemote: URL? = nil) -> URL? {
        let (root, relative) = split(name)
        guard isSafe(relative: relative) else { return nil }
        let user = driveC.appendingPathComponent("users").appendingPathComponent(windowsUser)
        let base: URL
        switch root {
        case "WinAppDataRoaming": base = user.appendingPathComponent("AppData/Roaming")
        case "WinAppDataLocal": base = user.appendingPathComponent("AppData/Local")
        case "WinAppDataLocalLow": base = user.appendingPathComponent("AppData/LocalLow")
        case "WinMyDocuments": base = user.appendingPathComponent("Documents")
        case "WinSavedGames": base = user.appendingPathComponent("Saved Games")
        case "WinProgramData": base = driveC.appendingPathComponent("ProgramData")
        case "GameInstall": guard let installFolder else { return nil }; base = installFolder
        case "": guard let defaultRemote else { return nil }; base = defaultRemote
        default: return nil
        }
        return relative.split(whereSeparator: { $0 == "/" || $0 == "\\" }).reduce(base) { $0.appendingPathComponent(String($1)) }
    }
}

// MARK: - The download itself

protocol SteamCloudTransport {
    func changelist(appID: Int) async throws -> SteamCloudChangelist
    func downloadInfo(appID: Int, fileName: String) async throws -> SteamCloudDownloadInfo
    /// The bytes behind the link, as served.
    func fetch(_ info: SteamCloudDownloadInfo) async throws -> Data
}

struct SteamCloudReport: Equatable {
    var downloaded: [String] = []
    var upToDate = 0
    var keptNewerLocal: [String] = []
    /// Changed on this device AND in the cloud since the last sync: neither side is touched.
    var conflicts: [String] = []
    var skipped: [String] = []       // roots with no place here, other platforms, deleted
    var failed: [String] = []
    var bytes = 0
    var summary: String {
        "\(downloaded.count) downloaded (\(bytes / 1024) KB), \(upToDate) already current, \(keptNewerLocal.count) newer here (kept), \(skipped.count) skipped, \(failed.count) failed" + (conflicts.isEmpty ? "" : ", \(conflicts.count) changed on both sides (left)")
    }
}

enum SteamCloudSync {
    static let backupSuffix = ".porthole-backup"

    /// A backup that is already there is not thrown away for the new one: it is renamed `<file>.1.porthole-backup` (up to 5 older ones; the oldest is reused when all are taken), so
    /// two overwrites in a row never destroy the only copy of what was on this device.
    static func keepOlderBackup(_ backup: URL, fileManager fm: FileManager = .default) {
        guard fm.fileExists(atPath: backup.path) else { return }
        let stem = String(backup.path.dropLast(backupSuffix.count))
        let target = (1...5).map { URL(fileURLWithPath: "\(stem).\($0)\(backupSuffix)") }.first { !fm.fileExists(atPath: $0.path) } ?? URL(fileURLWithPath: "\(stem).1\(backupSuffix)")
        try? fm.removeItem(at: target)
        try? fm.moveItem(at: backup, to: target)
    }

    static func sha1(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    /// The file's final bytes, or nil if what arrived is not the file Steam listed. Served bytes are used as they are when their SHA-1 matches; when Steam says the served form is
    /// smaller than the file, the zlib-packed form is unpacked and checked the same way. Nothing unverified is ever returned.
    static func verified(_ served: Data, expecting info: SteamCloudDownloadInfo, listed: SteamCloudFile) -> Data? {
        let want = listed.sha1.isEmpty ? info.sha1 : listed.sha1
        guard want.count == 20 else { return nil }
        func matches(_ d: Data) -> Bool { Data(Insecure.SHA1.hash(data: d)) == want }
        if matches(served) { return served }
        let rawSize = info.rawSize > 0 ? info.rawSize : listed.size
        if rawSize > 0, served.count >= 6, served[served.startIndex] & 0x0F == 8 {          // a zlib header (78 xx): the packed form
            if let unpacked = Deflate.inflate(served.dropFirst(2).dropLast(4), expectedSize: rawSize), matches(unpacked) { return unpacked }
        }
        if rawSize > 0, let unpacked = Deflate.inflate(served, expectedSize: rawSize), matches(unpacked) { return unpacked }
        return nil
    }

    /// Brings the person's cloud files for `appID` onto this device. Never throws for one bad file: it is counted in the report and the rest go on.
    static func downloadMissing(appID: Int, transport: SteamCloudTransport, driveC: URL, installFolder: URL? = nil, defaultRemote: URL? = nil, ledgerURL: URL? = nil, maxFileBytes: Int = 600 << 20, parallel: Int = 6,
                                fileManager fm: FileManager = .default, progress: ((Int, Int, String) -> Void)? = nil) async throws -> SteamCloudReport {
        var report = SteamCloudReport()
        let list = try await transport.changelist(appID: appID)
        var ledger = SteamCloudLedger.load(from: ledgerURL)
        SteamLog.event("[cloud] app=\(appID) list: change \(list.currentChange), \(list.files.count) file(s), prefixes \(list.pathPrefixes.prefix(8).map { "'\($0)'" })")
        guard let user = SteamCloudLocation.windowsUser(in: driveC) else { SteamLog.event("[cloud] app=\(appID) no Windows user folder in the prefix"); return report }
        var shown = 0
        func note(_ file: SteamCloudFile, _ full: String, _ what: String) {
            shown += 1
            if shown <= 40 { SteamLog.event("[cloud]   \(full) [listed '\(file.name)', prefix \(file.pathPrefixIndex.map(String.init) ?? "-"), persist \(file.persistState), platforms \(file.platforms), \(file.size) B]: \(what)") }
        }
        let entries = list.files.map { (file: $0, full: $0.fullName(prefixes: list.pathPrefixes)) }
        let wanted = entries.filter { $0.file.isWanted }
        for entry in entries where !entry.file.isWanted { report.skipped.append(entry.full); note(entry.file, entry.full, "skipped (not kept, or not for Windows)") }
        // What has to be fetched is worked out first (cheap checks on the device, in order); the fetches then run several at a time, since each file is small.
        struct Job { var file: SteamCloudFile; var full: String; var dest: URL; var backup: URL? }
        var jobs: [Job] = []
        for (file, full) in wanted.map({ (file: $0.file, full: $0.full) }) {
            guard let dest = SteamCloudLocation.localURL(for: full, driveC: driveC, windowsUser: user, installFolder: installFolder, defaultRemote: defaultRemote) else {
                report.skipped.append(full); note(file, full, "skipped (no place for it on this device)"); continue
            }
            if file.size > maxFileBytes { report.skipped.append(full); note(file, full, "skipped (over the size limit)"); continue }
            var backup: URL?
            if fm.fileExists(atPath: dest.path) {
                let have = sha1(of: dest)
                if let have, have == file.sha1 { report.upToDate += 1; ledger.files[full] = SteamCloudLedger.hex(have); note(file, full, "already current"); continue }
                // The record of the last sync tells a change made here from a change made in the cloud: only a file that is unchanged here is replaced. Without a record
                // (or when this file cannot be read) the dates decide, as they always did.
                let modified = ((try? fm.attributesOfItem(atPath: dest.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
                if let baseline = ledger.files[full], let have {
                    if baseline == SteamCloudLedger.hex(file.sha1) { report.keptNewerLocal.append(full); note(file, full, "changed here since the last sync, the cloud has not changed; kept"); continue }
                    if baseline != SteamCloudLedger.hex(have) { report.conflicts.append(full); note(file, full, "changed here and in the cloud since the last sync; left alone"); continue }
                } else if file.timestamp > 0, modified > Double(file.timestamp) + 2 { report.keptNewerLocal.append(full); note(file, full, "a newer copy is here; kept"); continue }
                backup = URL(fileURLWithPath: dest.path + backupSuffix)
            }
            jobs.append(Job(file: file, full: full, dest: dest, backup: backup))
        }

        enum Result { case downloaded(Int), skipped(String), failed(String) }
        func fetchOne(_ job: Job) async -> Result {
            do {
                let info = try await transport.downloadInfo(appID: appID, fileName: job.full)
                if info.explicitDelete { return .skipped("skipped (deleted on Steam)") }
                if info.encrypted { return .failed("failed (Steam sent it encrypted; not supported)") }
                let served = try await transport.fetch(info)
                guard let data = verified(served, expecting: info, listed: job.file) else {
                    return .failed("failed (the download did not match Steam's checksum: \(served.count) bytes served, \(job.file.size) listed; not saved)")
                }
                try fm.createDirectory(at: job.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let part = URL(fileURLWithPath: job.dest.path + ".porthole-part")
                try data.write(to: part, options: .atomic)
                if let backup = job.backup { Self.keepOlderBackup(backup); try fm.moveItem(at: job.dest, to: backup) }
                try fm.moveItem(at: part, to: job.dest)
                if job.file.timestamp > 0 { try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(job.file.timestamp))], ofItemAtPath: job.dest.path) }
                return .downloaded(data.count)
            } catch {
                return .failed("failed (\((error as? SteamContentError)?.message ?? error.localizedDescription))")
            }
        }

        var results = [Result?](repeating: nil, count: jobs.count)
        var finished = 0
        await withTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            func startNext() { if next < jobs.count { let i = next; next += 1; group.addTask { (i, await fetchOne(jobs[i])) } } }
            for _ in 0..<min(max(1, parallel), jobs.count) { startNext() }
            while let (i, result) = await group.next() {
                results[i] = result; finished += 1
                progress?(finished, jobs.count, (jobs[i].full as NSString).lastPathComponent)
                startNext()
            }
        }
        for (i, job) in jobs.enumerated() {
            switch results[i] {
            case .downloaded(let n)?: report.downloaded.append(job.full); report.bytes += n; ledger.files[job.full] = SteamCloudLedger.hex(job.file.sha1); note(job.file, job.full, "downloaded \(n) B")
            case .skipped(let why)?: report.skipped.append(job.full); note(job.file, job.full, why)
            case .failed(let why)?: report.failed.append(job.full); note(job.file, job.full, why)
            case .none: report.failed.append(job.full)
            }
        }
        if report.failed.isEmpty { ledger.change = list.currentChange }
        ledger.save(to: ledgerURL)
        SteamLog.event("[cloud] app=\(appID) change=\(list.currentChange): \(report.summary)")
        return report
    }
}

// MARK: - Over Steam's connection

/// Steam's own answers over the signed-in connection, and the file links over HTTPS.
struct SteamCMCloudTransport: SteamCloudTransport {
    let cm: SteamCM
    var machineName = "Porthole"

    func call(_ name: String, _ body: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                cm.call(name, body: body, timeout: 25) { result in
                    switch result {
                    case .success(let data): continuation.resume(returning: data)
                    case .failure(let error): continuation.resume(throwing: SteamContentError(message: "\(error)"))
                    }
                }
            }
        }
    }

    func changelist(appID: Int) async throws -> SteamCloudChangelist {
        let reply = try await call("Cloud.GetAppFileChangelist#1", SteamCloudMessages.changelistRequest(appID: appID))
        guard let list = SteamCloudMessages.parseChangelist(reply) else { throw SteamContentError(message: "Steam's cloud file list could not be read.") }
        return list
    }

    func downloadInfo(appID: Int, fileName: String) async throws -> SteamCloudDownloadInfo {
        let reply = try await call("Cloud.ClientFileDownload#1", SteamCloudMessages.downloadRequest(appID: appID, fileName: fileName))
        guard let info = SteamCloudMessages.parseDownload(reply) else { throw SteamContentError(message: "Steam gave no download link for the file.") }
        return info
    }

    func fetch(_ info: SteamCloudDownloadInfo) async throws -> Data {
        guard let url = info.url else { throw SteamContentError(message: "Steam's download link was not usable.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        for (name, value) in info.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await StoreNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SteamContentError(message: "The download answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }
}
