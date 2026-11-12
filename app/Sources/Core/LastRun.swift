// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What a game's last run says about itself, in plain words: the same log reading the automatic fixes do (AutoFix.scan), turned into a sentence or two for the game's page.
/// Foundation only; app/Tests/AutoFix runs it. The words are only ever about what the log shows: a cause is named when a known rule matches or the log says so, never guessed.
enum LastRun {
    /// How the run ended.
    enum End: String, Codable { case crashed, stopped, early, normal }

    struct Summary: Codable, Equatable {
        var gameID: UUID
        var gameName: String
        var at: Date
        var minutes: Int
        var end: End
        var headline: String
        var details: [String]
        var bestFPS: Int
        /// Entries of the website's documentation the run's log points to (DocsDiagnosis ids). Absent in summaries saved before this existed.
        var docs: [String]? = nil
    }

    /// The line the launch screen writes when a game could not start; its text is the reason.
    static let launchFailedLine = "[launch-screen] shown: state=failed("
    /// Lines the summary needs on top of the rules' own (AutoFix.RuleSet adds these to what a scan looks for).
    /// The memory line the run's end writes (Telemetry.stop): the app's, the graphics part's and the least free memory over the run.
    static let memorySummaryLine = "[mem-summary]"
    static let needles = [launchFailedLine, memorySummaryLine] + DocsDiagnosis.needles
    static let captureNeedles: Set<String> = [launchFailedLine, memorySummaryLine]

    struct MemorySummary: Equatable { var appMB: Int; var gpuMB: Int; var freeMB: Int }

    /// `[mem-summary] 12 min: peak app 5900 MB, peak gpu 1800 MB, least free 120 MB; ...` -> 5900, 1800, 120.
    static func memorySummary(in evidence: AutoFix.Evidence) -> MemorySummary? {
        guard let line = evidence.captures[memorySummaryLine],
              let m = line.range(of: #"peak app (\d+) MB, peak gpu (\d+) MB, least free (\d+) MB"#, options: .regularExpression) else { return nil }
        let numbers = line[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return MemorySummary(appMB: numbers[0], gpuMB: numbers[1], freeMB: numbers[2])
    }

    static func gigabytes(_ mb: Int) -> String { mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB" }

    /// `[...] [INFO] [launch-screen] shown: state=failed("File not found: C:\\x\\y.exe. ...") gameUp=false ...` -> `File not found: C:\x\y.exe. ...`
    static func launchFailure(in evidence: AutoFix.Evidence) -> String? {
        guard let line = evidence.captures[launchFailedLine], let start = line.range(of: launchFailedLine + "\"") else { return nil }
        var text = String(line[start.upperBound...])
        if let end = text.range(of: "\") gameUp=") ?? text.range(of: "\")") { text = String(text[..<end.lowerBound]) }
        text = text.replacingOccurrences(of: "\\\\", with: "\u{1}").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\u{1}", with: "\\")
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// How long, in the words a person uses.
    static func duration(minutes: Int) -> String { minutes < 1 ? "less than a minute" : minutes == 1 ? "1 minute" : "\(minutes) minutes" }

    /// The sentence and the lines under it. `matched` are the rules the log fits (AutoFix.matches); their reasons are already plain.
    /// `installNote` says something about how this copy of the app was installed that bears on a bad end (no extra memory); it is told only when memory is the likely cause.
    static func words(evidence: AutoFix.Evidence, end: End, minutes: Int, matched: [AutoFix.Rule], swapMB: Int, swapCoverage: String, installNote: String? = nil) -> (headline: String, details: [String]) {
        var details: [String] = []
        let headline: String
        if let failure = launchFailure(in: evidence) {
            headline = "It could not start."
            details.append(failure)
        } else {
            switch end {
            case .crashed: headline = "Porthole was closed while the game ran, \(duration(minutes: minutes)) in."
            case .stopped: headline = "The game was stopped while it was starting."
            case .early: headline = "It ended after \(duration(minutes: minutes)), before it got going."
            case .normal: headline = "It ended after \(duration(minutes: minutes))."
            }
        }
        for rule in matched where !details.contains(rule.reason) { details.append(rule.reason) }
        let warnings = evidence.count("[mem-pressure] CRITICAL")
        if warnings > 0, end != .normal, !matched.contains(where: { $0.id.hasPrefix("memory") }) {
            var line = "iOS warned \(warnings == 1 ? "once" : "\(warnings) times") that memory was almost full."
            if swapMB == 0 { line += " Swap is off for this game (More options > Memory)." }
            else { line += " Swap is \(swapMB >= 1024 ? "\(swapMB / 1024) GB" : "\(swapMB) MB")\(swapCoverage.isEmpty ? "" : " (coverage \(swapCoverage))")." }
            details.append(line)
        }
        if let mem = memorySummary(in: evidence), mem.appMB >= 1500 {
            var line = "The game used up to \(gigabytes(mem.appMB)) of memory (graphics up to \(gigabytes(mem.gpuMB)))."
            if end != .normal, warnings > 0 || end == .crashed { line += " Close other apps before starting, keep swap on for this game (More options > Memory), and lower the game's own texture quality or resolution to give it room." }
            details.append(line)
        }
        if let note = installNote, end != .normal, warnings > 0 || end == .crashed, !details.contains(note) { details.append(note) }
        if end == .normal, evidence.maxFPS > 0 { details.append("The best frame rate it showed was \(evidence.maxFPS).") }
        if details.isEmpty, end != .normal { details.append("The log shows no known cause. Share it from here, or send a report from the game's page.") }
        return (headline, details)
    }
}
