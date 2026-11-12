// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CryptoKit

// Steam Cloud, upload: a button on the game's page sends this person's own save files for the game to their Steam Cloud, so another device finds them. Written for Porthole
// from Steam's published service messages (Cloud.BeginAppUploadBatch, ClientBeginFileUpload, ClientCommitFileUpload, CompleteAppUploadBatchBlocking); nothing from another
// client's code. It only ever runs when the person asks, and never while a game is running (Valve's client then holds the account's one online sign-in).
//
// Safe by construction: a cloud file that changed since this device last synced is never overwritten (it is reported as a conflict and left alone), only files that really
// differ are sent, nothing is deleted on Steam's side, and each upload is checked against Steam's own list afterwards before it is written down as synced.

// MARK: - What Steam sends and wants

struct SteamCloudUploadBlock: Equatable {
    var host: String
    var path: String
    var https: Bool
    var method: Int                  // Steam's EHTTPMethod: 1 GET, 3 POST, 4 PUT (0 = PUT, the usual)
    var headers: [String: String]
    var offset: Int
    var length: Int
    var body: Data                   // when not empty it is sent as it is instead of a slice of the file

    var url: URL? {
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
        return URL(string: "https://" + host + (path.hasPrefix("/") ? path : "/" + path))       // always https, as for downloads
    }
    var httpMethod: String { switch method { case 1: "GET"; case 3: "POST"; default: "PUT" } }
}

struct SteamCloudBeginUpload: Equatable {
    var encrypt: Bool
    var blocks: [SteamCloudUploadBlock]
}

extension SteamCloudMessages {
    /// CCloud_BeginAppUploadBatch_Request: appid=1, machine_name=2, files_to_upload=3, files_to_delete=4.
    static func beginBatchRequest(appID: Int, machineName: String, upload: [String], delete: [String] = []) -> Data {
        var w = PBWriter(); w.varint(1, UInt64(appID)); w.string(2, machineName)
        for name in upload { w.string(3, name) }
        for name in delete { w.string(4, name) }
        return w.data
    }
    /// CCloud_BeginAppUploadBatch_Response: batch_id=1, app_change_number=4.
    static func parseBeginBatch(_ body: Data) -> UInt64? { PBFields(body)?.uint(1) }

    /// CCloud_ClientBeginFileUpload_Request: appid=1, file_size=2, raw_file_size=3, file_sha=4, time_stamp=5, filename=6, platforms_to_sync=7, can_encrypt=10, upload_batch_id=13.
    static func beginFileRequest(appID: Int, size: Int, sha1: Data, timestamp: UInt64, name: String, batchID: UInt64) -> Data {
        var w = PBWriter()
        w.varint(1, UInt64(appID)); w.varint(2, UInt64(size)); w.varint(3, UInt64(size)); w.bytes(4, sha1); w.varint(5, timestamp)
        w.string(6, name); w.varint(7, 0xFFFF_FFFF); w.bool(10, false); w.varint(13, batchID)
        return w.data
    }
    /// CCloud_ClientBeginFileUpload_Response: encrypt_file=1, block_requests=2 {url_host=1, url_path=2, use_https=3, http_method=4, request_headers=5 {name=1, value=2},
    /// block_offset=6, block_length=7, explicit_body_data=8}.
    static func parseBeginFile(_ body: Data) -> SteamCloudBeginUpload? {
        guard let fields = PBFields(body) else { return nil }
        let blocks: [SteamCloudUploadBlock] = fields.messages(2).compactMap { entry in
            guard let host = entry.string(1), let path = entry.string(2) else { return nil }
            var headers: [String: String] = [:]
            for header in entry.messages(5) { if let name = header.string(1), let value = header.string(2) { headers[name] = value } }
            return SteamCloudUploadBlock(host: host, path: path, https: entry.bool(3) ?? true, method: entry.int(4) ?? 0, headers: headers,
                                         offset: Int(entry.uint(6) ?? 0), length: Int(entry.uint(7) ?? 0), body: entry.data(8) ?? Data())
        }
        return SteamCloudBeginUpload(encrypt: fields.bool(1) ?? false, blocks: blocks)
    }

    /// CCloud_ClientCommitFileUpload_Request: transfer_succeeded=1, appid=2, file_sha=3, filename=4.
    static func commitRequest(appID: Int, name: String, sha1: Data, succeeded: Bool) -> Data {
        var w = PBWriter(); w.bool(1, succeeded); w.varint(2, UInt64(appID)); w.bytes(3, sha1); w.string(4, name); return w.data
    }
    /// CCloud_ClientCommitFileUpload_Response: file_committed=1.
    static func parseCommit(_ body: Data) -> Bool { PBFields(body)?.bool(1) ?? false }

    /// CCloud_CompleteAppUploadBatch_Request: appid=1, batch_id=2, batch_eresult=3 (1 = OK, 2 = failed).
    static func completeBatchRequest(appID: Int, batchID: UInt64, ok: Bool) -> Data {
        var w = PBWriter(); w.varint(1, UInt64(appID)); w.varint(2, batchID); w.varint(3, ok ? 1 : 2); return w.data
    }
}

// MARK: - What this device remembers

/// What was last in step with Steam for one game: Steam's change number and the SHA-1 of every file at that moment. It is how a change on this device is told from a change in
/// the cloud. Losing it is harmless: without it a file is judged by its date, and a file that differs and is older than the cloud's is left alone.
struct SteamCloudLedger: Codable, Equatable {
    var change: UInt64 = 0
    var files: [String: String] = [:]       // full cloud name -> SHA-1 in hex

    static func load(from url: URL?) -> SteamCloudLedger {
        guard let url, let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(SteamCloudLedger.self, from: data) else { return SteamCloudLedger() }
        return ledger
    }
    func save(to url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
    static func hex(_ sha1: Data) -> String { sha1.map { String(format: "%02x", $0) }.joined() }
}

// MARK: - What is here and what to do about it

struct SteamCloudLocalFile: Equatable {
    var full: String                 // the cloud name
    var url: URL
    var size: Int
    var modified: UInt64             // seconds since 1970
}

enum SteamCloudVerdict: Equatable {
    case inStep                      // the same on both sides
    case upload                      // changed here, the cloud has the last version this device saw (or has nothing)
    case cloudIsNewer                // changed in the cloud; Download brings it
    case conflict                    // changed on both sides since the last sync
    case deletedInCloud              // Steam's list says the file was deleted or is not kept: a copy left here is not sent back
}

enum SteamCloudUploadPlan {
    /// `baseline` is the SHA-1 (hex) this file had at the last sync, if any.
    static func decide(localSHA1: Data, localModified: UInt64, cloud: SteamCloudFile?, baseline: String?) -> SteamCloudVerdict {
        guard let cloud else { return .upload }
        if cloud.persistState != 0 { return .deletedInCloud }
        guard !cloud.sha1.isEmpty else { return .upload }
        if cloud.sha1 == localSHA1 { return .inStep }
        let local = SteamCloudLedger.hex(localSHA1), remote = SteamCloudLedger.hex(cloud.sha1)
        if let baseline {
            if baseline == local { return .cloudIsNewer }          // nothing changed here
            if baseline == remote { return .upload }                // nothing changed in the cloud
            return .conflict
        }
        // No record of a sync: the newer side wins, and an undated cloud file is not overwritten.
        return cloud.timestamp > 0 && localModified > cloud.timestamp + 2 ? .upload : .cloudIsNewer
    }

    /// The files of this game that exist here: those Steam lists (with a place on this device) and everything in Steam's own per-game folder, which is where a game saves
    /// through Steam's API. A save file a game has never put in the cloud and keeps somewhere else (Documents, AppData) is found once Steam lists it, or when it is in that folder.
    static func localFiles(list: SteamCloudChangelist, driveC: URL, windowsUser: String, installFolder: URL?, defaultRemote: URL?,
                           rules: [SteamCloudRule] = [], steamID64: UInt64? = nil,
                           maxFileBytes: Int, fileManager fm: FileManager = .default) -> [SteamCloudLocalFile] {
        var found: [String: SteamCloudLocalFile] = [:]
        func add(_ full: String, _ url: URL) {
            guard found[full] == nil, !url.lastPathComponent.hasSuffix(SteamCloudSync.backupSuffix), !url.lastPathComponent.hasSuffix(".porthole-part"), !url.lastPathComponent.hasPrefix("."),
                  let attributes = try? fm.attributesOfItem(atPath: url.path), (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= maxFileBytes else { return }
            let modified = ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970).map { UInt64(max(0, $0)) } ?? 0
            found[full] = SteamCloudLocalFile(full: full, url: url, size: size, modified: modified)
        }
        for file in list.files where file.persistState == 0 && (file.platforms == 0 || (file.platforms & 1) != 0) {
            let full = file.fullName(prefixes: list.pathPrefixes)
            if let url = SteamCloudLocation.localURL(for: full, driveC: driveC, windowsUser: windowsUser, installFolder: installFolder, defaultRemote: defaultRemote) { add(full, url) }
        }
        // The game's own save locations (Auto-Cloud rules): this is how a save Steam has never listed, like a new Factorio world, is found.
        for rule in rules {
            var path = rule.path
            if let steamID64 {
                path = path.replacingOccurrences(of: "{64BitSteamID}", with: String(steamID64))
                    .replacingOccurrences(of: "{Steam3AccountID}", with: String(steamID64 & 0xFFFFFFFF))
            }
            let trimmed = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).joined(separator: "/")
            guard !path.contains("{"), !trimmed.isEmpty,
                  let folder = SteamCloudLocation.localURL(for: "%\(rule.root)%\(trimmed)", driveC: driveC, windowsUser: windowsUser, installFolder: installFolder, defaultRemote: defaultRemote),
                  let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: rule.recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
            let base = folder.standardizedFileURL.path
            for case let url as URL in walker {
                let file = url.standardizedFileURL.path
                guard file.hasPrefix(base + "/") else { continue }
                let relative = String(file.dropFirst(base.count + 1))
                let name = url.lastPathComponent
                guard SteamCloudLocation.isSafe(relative: relative), fnmatch(rule.pattern, name, FNM_CASEFOLD) == 0,
                      rule.exclude.isEmpty || fnmatch(rule.exclude, name, FNM_CASEFOLD) != 0 else { continue }
                add("%\(rule.root)%\(trimmed)/\(relative)", url)
            }
        }
        if let defaultRemote, let walker = fm.enumerator(at: defaultRemote, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let base = defaultRemote.standardizedFileURL.path
            for case let url as URL in walker {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                let relative = String(path.dropFirst(base.count + 1))
                if SteamCloudLocation.isSafe(relative: relative), !relative.hasPrefix("%") { add(relative, url) }
            }
        }
        return found.values.sorted { $0.full < $1.full }
    }
}

// MARK: - The upload itself

protocol SteamCloudUploadTransport: SteamCloudTransport {
    func beginBatch(appID: Int, upload: [String]) async throws -> UInt64
    func beginFile(appID: Int, batch: UInt64, name: String, size: Int, sha1: Data, timestamp: UInt64) async throws -> SteamCloudBeginUpload
    func send(_ block: SteamCloudUploadBlock, data: Data) async throws
    func commit(appID: Int, name: String, sha1: Data, succeeded: Bool) async throws -> Bool
    func completeBatch(appID: Int, batch: UInt64, ok: Bool) async throws
}

struct SteamCloudUploadReport: Equatable {
    var uploaded: [String] = []
    var inStep = 0
    var cloudNewer: [String] = []
    var conflicts: [String] = []
    var deletedInCloud: [String] = []
    var failed: [String] = []
    var bytes = 0
    var summary: String {
        "\(uploaded.count) uploaded (\(bytes / 1024) KB), \(inStep) already the same, \(cloudNewer.count) newer in the cloud (left), \(conflicts.count) changed on both sides (left), \(failed.count) failed"
    }
}

extension SteamCloudSync {
    /// Sends the files of `appID` that changed on this device. Stops cleanly on the first server error; a file that did not go through is counted as failed and never marked as synced.
    static func uploadChanged(appID: Int, transport: SteamCloudUploadTransport, driveC: URL, installFolder: URL? = nil, defaultRemote: URL? = nil, ledgerURL: URL? = nil,
                              rules: [SteamCloudRule] = [], steamID64: UInt64? = nil, machineName: String = "Porthole", maxFileBytes: Int = 100 << 20, fileManager fm: FileManager = .default,
                              progress: ((Int, Int, String) -> Void)? = nil) async throws -> SteamCloudUploadReport {
        var report = SteamCloudUploadReport()
        let list = try await transport.changelist(appID: appID)
        guard let user = SteamCloudLocation.windowsUser(in: driveC) else { SteamLog.event("[cloud-up] app=\(appID) no Windows user folder in the prefix"); return report }
        var ledger = SteamCloudLedger.load(from: ledgerURL)
        let cloudByName = Dictionary(list.files.map { ($0.fullName(prefixes: list.pathPrefixes), $0) }, uniquingKeysWith: { _, last in last })
        let local = SteamCloudUploadPlan.localFiles(list: list, driveC: driveC, windowsUser: user, installFolder: installFolder, defaultRemote: defaultRemote, rules: rules, steamID64: steamID64, maxFileBytes: maxFileBytes, fileManager: fm)
        SteamLog.event("[cloud-up] app=\(appID) rules: \(rules.map { "\($0.root)/\($0.path)\($0.pattern)" })")
        SteamLog.event("[cloud-up] app=\(appID) list: change \(list.currentChange), \(list.files.count) cloud file(s), \(local.count) file(s) here")

        struct Job { var file: SteamCloudLocalFile; var sha1: Data; var data: Data }
        var jobs: [Job] = []
        for file in local {
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe), data.count == file.size else { report.failed.append(file.full); continue }
            let sha1 = Data(Insecure.SHA1.hash(data: data))
            switch SteamCloudUploadPlan.decide(localSHA1: sha1, localModified: file.modified, cloud: cloudByName[file.full], baseline: ledger.files[file.full]) {
            case .inStep: report.inStep += 1; ledger.files[file.full] = SteamCloudLedger.hex(sha1)
            case .cloudIsNewer: report.cloudNewer.append(file.full)
            case .conflict: report.conflicts.append(file.full)
            case .deletedInCloud: report.deletedInCloud.append(file.full)
            case .upload: jobs.append(Job(file: file, sha1: sha1, data: data))
            }
        }
        for name in report.conflicts { SteamLog.event("[cloud-up]   \(name): changed here and in the cloud since the last sync; left alone") }
        guard !jobs.isEmpty else { ledger.save(to: ledgerURL); SteamLog.event("[cloud-up] app=\(appID): \(report.summary)"); return report }

        let batch = try await transport.beginBatch(appID: appID, upload: jobs.map(\.file.full))
        var sent: [Job] = []
        var done = 0
        for job in jobs {
            do {
                let begin = try await transport.beginFile(appID: appID, batch: batch, name: job.file.full, size: job.data.count, sha1: job.sha1, timestamp: job.file.modified)
                if begin.encrypt { throw SteamContentError(message: "Steam asked for an encrypted upload; not supported") }
                var ok = true
                for block in begin.blocks {
                    let slice: Data
                    if !block.body.isEmpty { slice = block.body }
                    else if block.offset >= 0, block.length >= 0, block.offset + block.length <= job.data.count { slice = job.data.subdata(in: block.offset..<(block.offset + block.length)) }
                    else { ok = false; break }
                    do { try await transport.send(block, data: slice) } catch { ok = false; break }
                }
                let committed = try await transport.commit(appID: appID, name: job.file.full, sha1: job.sha1, succeeded: ok)
                if ok && committed { sent.append(job) } else { report.failed.append(job.file.full) }
            } catch {
                report.failed.append(job.file.full)
                SteamLog.event("[cloud-up]   \(job.file.full): failed (\((error as? SteamContentError)?.message ?? error.localizedDescription))")
            }
            done += 1
            progress?(done, jobs.count, (job.file.full as NSString).lastPathComponent)
        }
        try? await transport.completeBatch(appID: appID, batch: batch, ok: report.failed.isEmpty)

        // Written down as synced only what Steam's own list now shows with the same checksum.
        let after = try? await transport.changelist(appID: appID)
        let afterByName = Dictionary((after?.files ?? []).map { ($0.fullName(prefixes: after?.pathPrefixes ?? []), $0) }, uniquingKeysWith: { _, last in last })
        for job in sent {
            if afterByName[job.file.full]?.sha1 == job.sha1 {
                report.uploaded.append(job.file.full); report.bytes += job.data.count; ledger.files[job.file.full] = SteamCloudLedger.hex(job.sha1)
            } else {
                report.failed.append(job.file.full)
                SteamLog.event("[cloud-up]   \(job.file.full): sent, but Steam's list does not show it")
            }
        }
        if let after { ledger.change = after.currentChange }
        ledger.save(to: ledgerURL)
        SteamLog.event("[cloud-up] app=\(appID): \(report.summary)")
        return report
    }
}

// MARK: - Over Steam's connection

extension SteamCMCloudTransport: SteamCloudUploadTransport {
    func beginBatch(appID: Int, upload: [String]) async throws -> UInt64 {
        let reply = try await call("Cloud.BeginAppUploadBatch#1", SteamCloudMessages.beginBatchRequest(appID: appID, machineName: machineName, upload: upload))
        guard let batch = SteamCloudMessages.parseBeginBatch(reply) else { throw SteamContentError(message: "Steam did not open an upload.") }
        return batch
    }

    func beginFile(appID: Int, batch: UInt64, name: String, size: Int, sha1: Data, timestamp: UInt64) async throws -> SteamCloudBeginUpload {
        let reply = try await call("Cloud.ClientBeginFileUpload#1", SteamCloudMessages.beginFileRequest(appID: appID, size: size, sha1: sha1, timestamp: timestamp, name: name, batchID: batch))
        guard let begin = SteamCloudMessages.parseBeginFile(reply) else { throw SteamContentError(message: "Steam's upload answer could not be read.") }
        return begin
    }

    func send(_ block: SteamCloudUploadBlock, data: Data) async throws {
        guard let url = block.url else { throw SteamContentError(message: "Steam's upload link was not usable.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = block.httpMethod
        for (name, value) in block.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await StoreNetwork.session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SteamContentError(message: "The upload answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
    }

    func commit(appID: Int, name: String, sha1: Data, succeeded: Bool) async throws -> Bool {
        SteamCloudMessages.parseCommit(try await call("Cloud.ClientCommitFileUpload#1", SteamCloudMessages.commitRequest(appID: appID, name: name, sha1: sha1, succeeded: succeeded)))
    }

    func completeBatch(appID: Int, batch: UInt64, ok: Bool) async throws {
        _ = try await call("Cloud.CompleteAppUploadBatchBlocking#1", SteamCloudMessages.completeBatchRequest(appID: appID, batchID: batch, ok: ok))
    }
}

// MARK: - What a sync would do

struct SteamCloudPreviewItem: Equatable, Identifiable {
    var full: String
    var size: Int
    var id: String { full }
    /// "%WinAppDataRoaming%Factorio/saves/test.zip" -> "Factorio/saves/test.zip".
    var display: String { SteamCloudLocation.split(full).relative }
}

/// Everything that differs between this device and Steam's cloud for one game, worked out without changing anything on either side.
struct SteamCloudPreview: Equatable {
    var toUpload: [SteamCloudPreviewItem] = []
    var toDownload: [SteamCloudPreviewItem] = []
    /// Changed here and in the cloud since the last sync: neither button touches these.
    var conflicts: [SteamCloudPreviewItem] = []
    var inStep = 0
    var isInStep: Bool { toUpload.isEmpty && toDownload.isEmpty && conflicts.isEmpty }

    var summary: String {
        if isInStep { return inStep == 0 ? "No saves found yet" : "Up to date with Steam Cloud" }
        var parts: [String] = []
        if !toUpload.isEmpty { parts.append("\(toUpload.count) to upload") }
        if !toDownload.isEmpty { parts.append("\(toDownload.count) to download") }
        if !conflicts.isEmpty { parts.append("\(conflicts.count) changed on both sides") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension SteamCloudSync {
    /// The same decisions Upload and Download make, as a list. Reads Steam's list and this device's files; sends and writes nothing.
    static func preview(appID: Int, transport: SteamCloudTransport, driveC: URL, installFolder: URL? = nil, defaultRemote: URL? = nil, ledgerURL: URL? = nil,
                        rules: [SteamCloudRule] = [], steamID64: UInt64? = nil, maxFileBytes: Int = 100 << 20, fileManager fm: FileManager = .default) async throws -> SteamCloudPreview {
        var preview = SteamCloudPreview()
        let list = try await transport.changelist(appID: appID)
        guard let user = SteamCloudLocation.windowsUser(in: driveC) else { return preview }
        let ledger = SteamCloudLedger.load(from: ledgerURL)
        let cloudByName = Dictionary(list.files.map { ($0.fullName(prefixes: list.pathPrefixes), $0) }, uniquingKeysWith: { _, last in last })
        var decided = Set<String>()
        for file in SteamCloudUploadPlan.localFiles(list: list, driveC: driveC, windowsUser: user, installFolder: installFolder, defaultRemote: defaultRemote,
                                                    rules: rules, steamID64: steamID64, maxFileBytes: maxFileBytes, fileManager: fm) {
            guard let sha = sha1(of: file.url) else { continue }
            switch SteamCloudUploadPlan.decide(localSHA1: sha, localModified: file.modified, cloud: cloudByName[file.full], baseline: ledger.files[file.full]) {
            case .inStep: preview.inStep += 1; decided.insert(file.full)
            case .upload: preview.toUpload.append(SteamCloudPreviewItem(full: file.full, size: file.size)); decided.insert(file.full)
            case .conflict: preview.conflicts.append(SteamCloudPreviewItem(full: file.full, size: file.size)); decided.insert(file.full)
            case .deletedInCloud: decided.insert(file.full)       // deleted on Steam: neither button brings it back
            case .cloudIsNewer: break                    // the download pass below lists it
            }
        }
        for (name, file) in cloudByName.sorted(by: { $0.key < $1.key }) where file.isWanted && !decided.contains(name) && file.size <= maxFileBytes {
            guard let dest = SteamCloudLocation.localURL(for: name, driveC: driveC, windowsUser: user, installFolder: installFolder, defaultRemote: defaultRemote) else { continue }
            if fm.fileExists(atPath: dest.path) {
                let have = sha1(of: dest)
                if let have, have == file.sha1 { preview.inStep += 1; continue }
                let modified = ((try? fm.attributesOfItem(atPath: dest.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
                // The same decisions as Download makes (downloadMissing): the record of the last sync first, the dates when there is none.
                if let baseline = ledger.files[name], let have {
                    if baseline == SteamCloudLedger.hex(file.sha1) { continue }                  // changed here only: Download keeps it
                    if baseline != SteamCloudLedger.hex(have) { preview.conflicts.append(SteamCloudPreviewItem(full: name, size: file.size)); continue }
                } else if file.timestamp > 0, modified > Double(file.timestamp) + 2 { continue }          // newer here: Download keeps it
            }
            preview.toDownload.append(SteamCloudPreviewItem(full: name, size: file.size))
        }
        return preview
    }
}
