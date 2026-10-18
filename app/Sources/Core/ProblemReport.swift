// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// Builds the report a person shares or sends: the app and device facts that matter, their words, and the WHOLE log of the run that is being reported, with
/// the personal parts taken out. Nothing is sent anywhere by this: the person chooses where it goes.
///
/// A log is the only way to see why something crashed, and the cause is often far from the last lines, so nothing is cut off the end or the start: the run's
/// log goes in whole (a log over `perSourceCap` keeps its first and last parts and says what it left out), and an upload packs it before it travels.
enum ProblemReport {
    /// The most of one log that is taken. Real logs are 3 to 25 MB; this is for a runaway one.
    private static let perSourceCap = 60 * 1024 * 1024
    private static let headKept = 2 * 1024 * 1024

    // MARK: Reading

    /// A log file as it is, or, when it is huge, its first and last parts with a line saying what is between.
    private static func read(_ url: URL, cap: Int = perSourceCap) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)
        if size <= cap { return try? handle.readToEnd() }
        guard let head = try? handle.read(upToCount: headKept) else { return nil }
        try? handle.seek(toOffset: UInt64(size - (cap - headKept)))
        guard let tail = try? handle.readToEnd() else { return nil }
        var out = head
        out.append(Data("\n[... \((size - cap) / 1_048_576) MB from the middle of this log are left out here: it was \(size / 1_048_576) MB ...]\n".utf8))
        out.append(tail)
        return out
    }

    /// The last `bytes` of a file, starting on a whole line.
    private static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data.suffix(from: newline + 1) }
        return data
    }

    // MARK: Facts

    @MainActor static func facts() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?", build = info?["CFBundleVersion"] as? String ?? "?"
        let device = CompatDeviceInfo.current
        let gigabytes = String(format: "%.0f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        var lines: [String] = []
        lines.append("Porthole \(version) (\(build))")
        lines.append("Engine: \(CompatEngine.label)")
        lines.append("Device: \(device?.name ?? "unknown") [\(device?.id ?? "?")], iOS \(UIDevice.current.systemVersion), \(gigabytes) GB memory, \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
        lines.append("Install: \(InstallCheck.layoutTitle); JIT helper \(InstallCheck.hasJITHelper ? "yes" : "no"), tunnel \(InstallCheck.hasTunnel ? "yes" : "no"), download card \(InstallCheck.hasActivityExtension ? "yes" : "no")")
        lines.append("Bundle id: \(Bundle.main.bundleIdentifier == "site.portholehq.app" ? "the default" : "custom")")
        lines.append("JIT: \(JITMethod.current.rawValue), pairing file \(BuiltinJIT.hasPairing ? "yes" : "no"), LocalDevVPN \(TunnelManager.useLocalDevVPN ? "on" : "off")")
        lines.append("Games in the library: \(AppModel.shared.games.count)")
        for finding in InstallCheck.findings() where finding.level != .good { lines.append("Install check (\(finding.level)): \(finding.title)") }
        lines.append("Made: \(ISO8601DateFormatter().string(from: Date())) (\(TimeZone.current.identifier))")
        return lines.joined(separator: "\n")
    }

    // MARK: Building

    struct Built {
        var note: String
        var facts: String
        /// The cleaned log, with a heading before each part. Empty when the log is left out.
        var log: Data
        /// What the log is made of, for the person to read: "this run, 8.2 MB".
        var parts: [String]
    }

    private static func megabytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// Reads the logs off the main thread, cleans them, and puts the parts together. With `crash`, the run that ended comes first, then the game's own log when it
    /// is a different file, then the end of the launch that followed.
    @MainActor static func build(description: String, includeLog: Bool, crash: CrashEvidence.Found? = nil) async -> Built {
        let names = [EpicAuth.shared.accountName, SteamStore.shared.accountName, GogAuth.shared.accountName, ItchAuth.shared.accountName, AmazonAuth.shared.accountName].compactMap { $0 }.filter { !$0.isEmpty }
        var note = LogCleaner.clean(description.trimmingCharacters(in: .whitespacesAndNewlines), accountNames: names)
        var facts = facts()
        if let crash {
            facts += "\nEnded unexpectedly: \(crash.record.game), started \(ISO8601DateFormatter().string(from: crash.record.started)) (found when Porthole opened again; the crashed run's log is first below)"
            note = "[Crash: \(crash.record.game)] " + note
        }
        guard includeLog else { return Built(note: note, facts: facts, log: Data(), parts: []) }
        let current = LogStore.shared.logFileURL
        let previous = current.deletingLastPathComponent().appendingPathComponent("madeira-log.prev.txt")
        let result: (Data, [String]) = await Task.detached(priority: .utility) {
            var out = Data()
            var parts: [String] = []
            func add(_ title: String, _ raw: Data?, label: String) {
                guard let raw, !raw.isEmpty else { return }
                let cleaned = LogCleaner.cleanData(raw, accountNames: names)
                out.append(Data("## \(title)\n".utf8)); out.append(cleaned); out.append(Data("\n\n".utf8))
                parts.append("\(label), \(megabytes(cleaned.count))")
            }
            if let crash {
                add("Log of the run that ended unexpectedly: \(crash.record.game)", crash.runLog.flatMap { read($0) }, label: "the run that ended")
                add("The game's own log", crash.gameLog.flatMap { read($0, cap: 40 * 1024 * 1024) }, label: "the game's own log")
                add("Log of the launch after it (the end of it)", tail(of: current, bytes: 1_000_000), label: "the launch after it")
            } else {
                add("Log of this run", read(current), label: "this run")
                add("Log of the run before", read(previous), label: "the run before")
            }
            return (out, parts)
        }.value
        return Built(note: note, facts: facts, log: result.0, parts: result.1)
    }

    /// The report as text for the person to look at before it goes anywhere: everything but the middle of the log, with its size said plainly.
    @MainActor static func preview(description: String, includeLog: Bool, crash: CrashEvidence.Found? = nil) async -> String {
        let b = await build(description: description, includeLog: includeLog, crash: crash)
        var out = "# Porthole problem report\n\n## What went wrong\n\(b.note.isEmpty ? "(not described)" : b.note)\n\n## About this install\n\(b.facts)\n"
        guard includeLog else { return out + "\n(The log is left out.)\n" }
        out += "\n## The log that goes with it\n\(b.parts.isEmpty ? "(no log found)" : b.parts.joined(separator: "\n"))\nAltogether \(megabytes(b.log.count)) of text, which is sent packed (about a tenth of that). Below are its first and last parts; everything in between is sent too, cleaned in the same way.\n\n"
        let head = 30_000, tail = 60_000
        if b.log.count <= head + tail { out += String(decoding: b.log, as: UTF8.self) }
        else {
            out += String(decoding: b.log.prefix(head), as: UTF8.self)
            out += "\n\n[... \(megabytes(b.log.count - head - tail)) not shown here, but sent ...]\n\n"
            out += String(decoding: b.log.suffix(tail), as: UTF8.self)
        }
        return out
    }

    /// Writes the report to a file the share sheet can hand to Files, AirDrop, Discord or a mail.
    @MainActor static func file(description: String, includeLog: Bool, crash: CrashEvidence.Found? = nil) async -> URL? {
        let b = await build(description: description, includeLog: includeLog, crash: crash)
        let info = Bundle.main.infoDictionary
        let name = "Porthole-report-\(info?["CFBundleShortVersionString"] as? String ?? "x")-\(info?["CFBundleVersion"] as? String ?? "x").txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var data = Data("# Porthole problem report\n\n## What went wrong\n\(b.note.isEmpty ? "(not described)" : b.note)\n\n## About this install\n\(b.facts)\n\n".utf8)
        data.append(b.log)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// The log packed for an upload: raw deflate, as base64 (the server unpacks it and keeps it packed). Nil when there is no log.
    static func packed(_ log: Data) -> String? {
        guard !log.isEmpty, let packed = try? (log as NSData).compressed(using: .zlib) else { return nil }
        return (packed as Data).base64EncodedString()
    }
}
