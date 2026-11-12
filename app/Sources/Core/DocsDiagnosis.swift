// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Points a run's log at the website's documentation. The documentation has entries for log lines people ask about ("Queue::Wait: fence ... never reached"); each entry that a
/// log can show lists the line it looks for (tools/docs_curated.json, written into DocsDiagnosis.generated.swift by tools/build_docs.py). When a run ended badly and its log
/// holds that line, the game's page says so and links the entry. It only reads what the automatic fixes already scanned: no second pass over the log.
enum DocsDiagnosis {
    struct Entry: Equatable {
        /// The entry's id on /docs/errors.html.
        let id: String
        /// One plain line for the game's page.
        let short: String
        /// Lines that must all be in the log.
        let needles: [String]
    }

    /// Everything a scan has to count for these entries.
    static var needles: [String] { Array(Set(entries.flatMap(\.needles))) }

    /// The entries the run's log fits, in the order of the list.
    static func matches(_ evidence: AutoFix.Evidence) -> [Entry] {
        entries.filter { entry in entry.needles.allSatisfy { evidence.count($0) > 0 } }
    }

    static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    static func url(for entry: Entry) -> URL? { URL(string: DocsLink.base + "errors.html#" + entry.id) }
}
