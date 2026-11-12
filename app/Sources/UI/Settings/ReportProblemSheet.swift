// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Settings > Report a problem: describe it in a sentence, review what would be shared, and send the file where you choose (Files, AirDrop, Discord, mail) or open the
/// issue page. Nothing leaves the device unless the person shares it.
struct ReportProblemPage: View {
    @ObservedObject private var tracker = ProblemTracker.shared
    @State private var confirmSend = false
    @State private var sending = false
    @State private var sentNote: String?
    @State private var viewing: ProblemEntry?
    @State private var entryScope = FocusScope()
    @State private var readerScope = FocusScope()
    @State private var note = ""
    @State private var includeLog = true
    @State private var building = false
    @State private var crash: CrashEvidence.Found?
    @State private var includeCrash = true
    @State private var shareFile: ShareFile?
    @State private var preview: String?
    private struct ShareFile: Identifiable { let url: URL; var id: String { url.path } }

    /// Opened from a game's page: the sentence starts with the game's name, so the report says which game it is about.
    init(game: String? = nil) {
        if let game { _note = State(initialValue: "[Problem: \(game)] ") }
    }

    private static let issues = URL(string: "https://github.com/tylerkaska112/PortHole/issues/new/choose")!
    private static let discord = URL(string: "https://discord.gg/N7PkdptTFn")!

    var body: some View {
        PageScaffold(title: "Report a problem", symbol: "exclamationmark.bubble.fill", subtitle: "Send the developer what went wrong") {
            if ProblemClient.available, !tracker.entries.isEmpty || tracker.loading || tracker.error != nil {
                SettingsGroup(title: "My reports") {
                    ForEach(tracker.entries) { entry in
                        RowBase(id: "rp-e-\(entry.id)", symbol: symbol(entry), tint: tint(entry), title: entry.description.isEmpty ? "(no description)" : entry.description,
                                subtitle: subtitle(entry), action: { viewing = entry }) {
                            Text(statusText(entry)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(tint(entry))
                                .padding(.horizontal, 10).padding(.vertical, 5).background(tint(entry).opacity(0.15), in: Capsule())
                        }
                    }
                    if tracker.loading && tracker.entries.isEmpty { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding() }
                    if let error = tracker.error { Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                    ActionRow(id: "rp-refresh", symbol: "arrow.clockwise", title: "Check for answers", chevron: false) { Task { await tracker.refresh(); tracker.markSeen() } }
                    Text("Tap a report to read the whole answer, or to withdraw it.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
            }
            Text("Porthole makes a small text file with what a person fixing this needs. It is not sent anywhere: you choose where it goes.")
                .font(.subheadline).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            if let crash {
                SettingsGroup(title: "A game ended unexpectedly") {
                    ToggleRow(id: "rp-crash", symbol: "exclamationmark.triangle.fill", tint: Theme.warn, title: "Include the crash of \(crash.record.game)",
                              subtitle: "Found when Porthole opened again, \(crash.record.started.formatted(date: .abbreviated, time: .shortened)). Its log was kept, so the report has the run that ended and not the launch that followed.",
                              isOn: $includeCrash)
                }
            }
            SettingsGroup(title: "What went wrong") {
                TextFieldRow(id: "rp-note", symbol: "text.bubble.fill", title: "In a sentence", placeholder: "For example: the game closes after the logo", text: $note)
            }
            SettingsGroup(title: "What is in the file") {
                ToggleRow(id: "rp-log", symbol: "doc.text.fill", title: "The whole log of the run (recommended)",
                          subtitle: "Without it a problem usually cannot be found. The whole run is needed: the cause is often far from the last line.",
                          info: "The log says what the app and the engine did, from the start of the run to its end. It is a few megabytes and is sent packed. Folder names inside the app, your account names, e-mail addresses and public IP addresses are replaced before it is written or sent. Fingerprints and technical lines stay, because they are what is looked at.",
                          isOn: $includeLog)
                ActionRow(id: "rp-preview", symbol: "eye.fill", title: "Look at exactly what would be shared", chevron: true) {
                    Task { preview = await ProblemReport.preview(description: note, includeLog: includeLog, crash: includeCrash ? crash : nil) }
                }
            }
            SettingsGroup(title: "Send it") {
                ActionRow(id: "rp-share", symbol: "square.and.arrow.up", title: building ? "Preparing\u{2026}" : "Save or share the file", prominent: true) {
                    guard !building else { return }
                    building = true
                    Task {
                        if let url = await ProblemReport.file(description: note, includeLog: includeLog, crash: includeCrash ? crash : nil) {
                            shareFile = ShareFile(url: url)
                            if includeCrash, let crash { CrashEvidence.markReported(crash); self.crash = nil }
                        }
                        building = false
                    }
                }
                if ProblemClient.available {
                    ActionRow(id: "rp-send", symbol: "paperplane.fill", title: sending ? "Sending\u{2026}" : "Send it to Porthole's server", subtitle: "Private: only the maintainer can read it", chevron: false) {
                        if !sending { confirmSend = true }
                    }
                }
                ActionRow(id: "rp-github", symbol: "arrow.up.right.square", title: "Open an issue on GitHub", subtitle: "Attach the file to it", chevron: false) { UIApplication.shared.open(Self.issues) }
                ActionRow(id: "rp-discord", symbol: "bubble.left.and.bubble.right.fill", title: "Ask on Discord", subtitle: "There are support channels", chevron: false) { UIApplication.shared.open(Self.discord) }
                if let sentNote { Text(sentNote).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
        }
        .task {
            crash = CrashEvidence.latestUnreported()
            guard ProblemClient.available else { return }
            await tracker.refresh()
            try? await Task.sleep(for: .seconds(2))
            tracker.markSeen()
        }
        .confirm("Send this report?", message: "It goes to Porthole's server and is private: only the maintainer can read it, and you can follow what happens to it here. What is in it is what \u{201C}Look at exactly what would be shared\u{201D} shows.",
                 confirmTitle: "Send", isPresented: $confirmSend) { send() }
        .sheet(item: $viewing) { entry in
            ProblemEntrySheet(entry: tracker.entries.first { $0.id == entry.id } ?? entry, scope: entryScope,
                              withdraw: { Task { await tracker.withdraw(entry) }; viewing = nil }, close: { viewing = nil })
        }
        .sheet(item: $shareFile) { ActivityView(items: [$0.url]) }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            TextReaderSheet(title: "The report", text: preview ?? "", monospaced: true, scope: readerScope) { preview = nil }
        }
    }

    // MARK: Sending and showing

    private func send() {
        sending = true; sentNote = nil
        Task {
            // The whole run: cleaned, then packed (a text log shrinks about ten to one) before it travels.
            let built = await ProblemReport.build(description: note, includeLog: includeLog, crash: includeCrash ? crash : nil)
            let packed = await Task.detached(priority: .utility) { ProblemReport.packed(built.log) ?? "" }.value
            do {
                try await ProblemClient.send(description: built.note, facts: built.facts, logPacked: packed)
                if includeCrash, let crash { CrashEvidence.markReported(crash); self.crash = nil }
                UserDefaults.standard.set(true, forKey: "f4.problemsSent")
                sentNote = "Sent. Its status shows under My reports; the maintainer may add a note."
                note = ""
                await tracker.refresh()
            } catch { sentNote = "Could not send it: \(ErrorText.plain(error))" }
            sending = false
        }
    }

    private func statusText(_ e: ProblemEntry) -> String {
        switch e.status {
        case "fixed": e.fixedIn.isEmpty ? "Fixed" : "Fixed in \(e.fixedIn)"
        case "reviewed": "Reviewed"
        default: "Open"
        }
    }
    private func tint(_ e: ProblemEntry) -> Color { e.status == "fixed" ? Theme.good : e.status == "reviewed" ? .blue : Theme.warn }
    private func symbol(_ e: ProblemEntry) -> String { e.status == "fixed" ? "checkmark.seal.fill" : e.status == "reviewed" ? "eye.fill" : "hourglass" }
    private func subtitle(_ e: ProblemEntry) -> String {
        let date = e.created.formatted(date: .abbreviated, time: .omitted)
        let base = e.status == "open" ? "Waiting to be looked at" : e.status == "reviewed" ? "Looked at" : "Fixed"
        return e.note.isEmpty ? "\(base) \u{00B7} sent \(date)" : "\(e.note)  \u{00B7} sent \(date)"
    }
}

/// One report this install sent: what it said, where it stands, and in full what the maintainer answered. A withdrawal is asked for here, not by a tap on the list.
struct ProblemEntrySheet: View {
    let entry: ProblemEntry
    let scope: FocusScope
    let withdraw: () -> Void
    let close: () -> Void
    @State private var confirm = false

    private var tint: Color { entry.status == "fixed" ? Theme.good : entry.status == "reviewed" ? .blue : Theme.warn }
    private var statusText: String {
        switch entry.status {
        case "fixed": entry.fixedIn.isEmpty ? "Fixed" : "Fixed in \(entry.fixedIn)"
        case "reviewed": "Reviewed"
        default: "Open: waiting to be looked at"
        }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Your report").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "pe-close", title: "Close", symbol: "xmark", action: close)
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: entry.status == "fixed" ? "checkmark.seal.fill" : entry.status == "reviewed" ? "eye.fill" : "hourglass")
                            Text(statusText).font(.system(size: 16, weight: .heavy, design: .rounded))
                        }
                        .foregroundStyle(tint).padding(.horizontal, 14).padding(.vertical, 9).background(tint.opacity(0.15), in: Capsule())
                        .padding(.horizontal, 6)
                        if !entry.note.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("From the maintainer", systemImage: "text.bubble.fill").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
                                Text(entry.note).font(.system(size: 17)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                            .focusTarget("pe-note", radius: 16, scale: 1.01, action: {})
                        } else {
                            Text(entry.status == "open" ? "Nobody has answered yet. When the maintainer looks at it, the status and a note appear here."
                                                        : "The maintainer marked it without a note.")
                                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                        }
                        SettingsGroup(title: "What you sent") {
                            Text(entry.description.isEmpty ? "(no description, only the log)" : entry.description)
                                .font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                            ValueRow(id: "pe-ver", symbol: "app.badge.fill", title: "Porthole", value: "\(entry.version) (\(entry.build))")
                            ValueRow(id: "pe-sent", symbol: "paperplane.fill", title: "Sent", value: entry.created.formatted(date: .abbreviated, time: .shortened))
                            if entry.status != "open" { ValueRow(id: "pe-upd", symbol: "clock.fill", title: "Answered", value: entry.updated.formatted(date: .abbreviated, time: .shortened)) }
                        }
                        SettingsGroup {
                            ActionRow(id: "pe-withdraw", symbol: "trash", title: "Withdraw this report", destructive: true, chevron: false) { confirm = true }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = close; scope.defaultFocus = entry.note.isEmpty ? "pe-close" : "pe-note"; scope.focused = scope.defaultFocus }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
        .confirm("Withdraw this report?", message: "It is deleted from the server.", confirmTitle: "Withdraw", destructive: true, isPresented: $confirm) { withdraw() }
    }
}
