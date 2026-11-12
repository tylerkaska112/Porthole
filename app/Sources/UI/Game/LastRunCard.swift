// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// On a game's page: what its last run says about itself (LastRun: the log read the way the automatic fixes read it), and a button that hands the game's own log, cleaned of
/// personal data, to the share sheet.
struct LastRunCard: View {
    let game: Game
    @ObservedObject private var store = LastRunStore.shared
    @State private var hasLog = false
    @State private var preparing = false
    @State private var failed = false
    @State private var shared: SharedGameLog?

    private struct SharedGameLog: Identifiable { let url: URL; var id: String { url.path } }

    var body: some View {
        let summary = store.summary(for: game.id)
        Group {
            if summary != nil || hasLog {
                SettingsGroup(title: "Last time", note: summary.map(when)) {
                    if let summary {
                        Text(summary.headline).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text).padding(.horizontal, 6)
                        ForEach(Array(summary.details.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach((summary.docs ?? []).compactMap { DocsDiagnosis.entry(id: $0) }, id: \.id) { entry in
                            ActionRow(id: "gp-docs-\(entry.id)", symbol: "book", title: "Looks like: " + entry.short, subtitle: "Read what it means and what to try on the website",
                                      info: "The log of this run holds a line the website\u{2019}s documentation explains. This is a pointer, not a diagnosis: the page says how sure it is and what is worth trying.",
                                      chevron: false) { if let url = DocsDiagnosis.url(for: entry) { UIApplication.shared.open(url) } }
                        }
                    }
                    if hasLog {
                        ActionRow(id: "gp-share-log", symbol: "square.and.arrow.up", title: preparing ? "Preparing the log\u{2026}" : "Share this game\u{2019}s log",
                                  subtitle: failed ? "The log could not be read." : "Cleaned of your name and file paths first",
                                  info: "Hands the game\u{2019}s newest log to the share sheet (AirDrop, Files, a message). The install facts are at the top of the file. Your name, account names, e-mail and public IP addresses are taken out first.",
                                  chevron: false) { share() }
                    }
                }
            }
        }
        .task(id: game.id) { hasLog = GameLogShare.latestLog(for: game) != nil }
        .sheet(item: $shared, onDismiss: nil) { file in ActivityView(items: [file.url]).onDisappear { try? FileManager.default.removeItem(at: file.url) } }
    }

    private func when(_ s: LastRun.Summary) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return "Ended \(f.localizedString(for: s.at, relativeTo: Date()))"
    }

    private func share() {
        guard !preparing else { return }
        preparing = true; failed = false
        Task {
            let url = await GameLogShare.prepare(for: game)
            preparing = false
            if let url { shared = SharedGameLog(url: url) } else { failed = true }
        }
    }
}
