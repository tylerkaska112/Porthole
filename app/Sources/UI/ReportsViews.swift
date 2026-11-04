// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The Reports section's sheets: a game's reports from its own page, and writing a report. The tab itself is in UI/Reports.

/// A game's reports in a sheet (from a game's own page).
struct CompatGameSheet: View {
    let gameID: String
    let title: String
    let game: Game?
    let scope: FocusScope
    let done: () -> Void

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack { Spacer(); PillButton(id: "cgs-close", title: "Close", symbol: "xmark", action: done) }.padding(.horizontal, 24).padding(.top, 16)
                CompatGameView(gameID: gameID, fallbackTitle: title, libraryGame: game)
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = done; scope.defaultFocus = "cgs-close"; scope.focused = "cgs-close" }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}

// MARK: - Write a report

struct ReportSheet: View {
    let game: Game
    var crashed = false
    /// The running session's numbers so far (when the form is opened from inside a game); otherwise the last finished session's.
    var liveStats: CompatSessionStats?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var compat = CompatStore.shared
    @State private var scope = FocusScope()
    @State private var rating: CompatVerdict?
    @State private var stability: CompatStability
    @State private var tags: Set<CompatTag> = []
    @State private var source: CompatSource?
    @State private var includeMeasured = true
    @State private var shareSettings = true
    @State private var comment = ""
    @State private var sending = false
    @State private var error: String?
    @State private var outcome: CompatStore.SubmitResult?
    @State private var log: CompatLog.Gathered?
    @State private var logLoading = true

    init(game: Game, crashed: Bool = false, liveStats: CompatSessionStats? = nil) {
        self.game = game; self.crashed = crashed; self.liveStats = liveStats
        _stability = State(initialValue: crashed ? .sometimes : .never)
    }

    private var stats: CompatSessionStats? { liveStats ?? compat.lastStats(for: game) }
    private var minutes: Int { stats?.minutes ?? Int((game.playSeconds ?? 0) / 60) }
    private var fromSteam: Bool { game.dockAppID != nil }
    private var enoughPlay: Bool { minutes >= CompatRules.minMinutesForWorking }
    private var problem: String? {
        guard let rating else { return "Choose how it ran." }
        if !fromSteam && source == nil { return "Say where the game's files came from." }
        if stability == .wont_launch && rating != .broken { return "A game that won't start can only be reported as \"Doesn't work\"." }
        if stability == .constantly && rating == .great { return "A game that crashes all the time can't be \"Works great\"." }
        if rating != .broken && !enoughPlay { return "Play for at least \(CompatRules.minMinutesForWorking) minutes before reporting that it works." }
        return nil
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Report").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "rp-close", title: outcome == nil ? "Cancel" : "Done", symbol: "xmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    Group { if let outcome { done(outcome) } else { form } }
                        .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "rp-v-\(CompatVerdict.allCases.first?.rawValue ?? "")"; scope.focused = scope.defaultFocus }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
        .interactiveDismissDisabled(sending)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "How did \(game.name) run?") {
                ForEach(CompatVerdict.allCases) { verdict in
                    let blocked = verdict != .broken && !enoughPlay
                    RowBase(id: "rp-v-\(verdict.rawValue)", symbol: verdict.symbol, tint: verdict.color, title: verdict.title, subtitle: verdict.detail, action: { if !blocked { rating = verdict } }) {
                        if rating == verdict { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }
                    .opacity(blocked ? 0.45 : 1)
                }
                if !enoughPlay { Text("You've played \(minutes) min. Play for at least \(CompatRules.minMinutesForWorking) minutes to report that it works; a game that won't start can be reported at any time.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
            SettingsGroup(title: "Did it crash?") {
                ChoiceRow(id: "rp-crash", symbol: "bolt.trianglebadge.exclamationmark.fill", title: "Crashes",
                          info: crashed ? "The app closed on its own while you were playing, so this starts on \"Crashes sometimes\". Change it if that's wrong." : nil,
                          options: CompatStability.allCases.map { ($0, $0.title) }, selection: $stability)
            }
            SettingsGroup(title: "Anything else?") {
                AdaptiveGrid(minWidth: 150, spacing: 8) {
                    ForEach(CompatTag.allCases) { tag in
                        let on = tags.contains(tag)
                        Button { if on { tags.remove(tag) } else { tags.insert(tag) } } label: {
                            Text(tag.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 40).foregroundStyle(on ? Theme.onAccent : Theme.text)
                                .background { if on { Capsule().fill(Theme.accentGradient) } else { Capsule().fill(Theme.panelHigh) } }
                        }
                        .buttonStyle(.plain)
                        .focusTarget("rp-tag-\(tag.rawValue)", radius: 20, scale: 1.05) { if on { tags.remove(tag) } else { tags.insert(tag) } }
                    }
                }
            }
            SettingsGroup(title: "Where did the game come from?") {
                if fromSteam { ValueRow(id: "rp-src", symbol: "shippingbox.fill", title: "Files from", value: "Steam") }
                else {
                    ChoiceRow(id: "rp-src", symbol: "shippingbox.fill", title: "Files from",
                              info: "Different stores can ship different builds of the same game, so this matters. Pick from the list.",
                              options: [(CompatSource?.none, "Choose\u{2026}")] + CompatSource.allCases.map { (Optional($0), $0.title) }, selection: $source)
                }
            }
            SettingsGroup(title: "What to include") {
                ToggleRow(id: "rp-measured", symbol: "chart.bar.fill", title: "Include what the app measured",
                          subtitle: stats.map { "\(liveStats != nil ? "This session" : "Last session"): \($0.summary)" } ?? "No measurements from a recent session. The report will only say how long you've played.",
                          isOn: Binding(get: { includeMeasured && stats != nil }, set: { includeMeasured = $0 }))
                ValueRow(id: "rp-log", symbol: "doc.text.fill", title: "The game's log", value: logLoading ? "Reading\u{2026}" : (log == nil ? "None found" : "Sent with it"))
                Text(logLoading ? "Looking for the log of the last run." : (log.map { "\($0.summary). Private: only the developer reads it, to see what happened; it is never shown in Reports. Personal paths and account names are taken out first." }
                     ?? "No log was found, so the report goes without one. A report without a log is checked with less to go on."))
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                ToggleRow(id: "rp-settings", symbol: "slider.horizontal.3", title: "Share my settings for this game", subtitle: compat.currentSettings(for: game).summary,
                          info: "How the game was started and the performance settings it used. This helps people get the same result. Launch options you typed are never shared.", isOn: $shareSettings)
            }
            SettingsGroup(title: "Your note") {
                TextFieldRow(id: "rp-note", symbol: "text.bubble.fill", title: "Optional note", placeholder: "settings that helped, glitches\u{2026}",
                             info: "A person checks notes before they appear, so yours won't show straight away. Please don't mention where to get game files.", text: Binding(get: { comment }, set: { comment = String($0.prefix(400)) }))
            }
            SettingsGroup {
                if let error { if NetworkStatus.shared.isOnline { Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                        else { OfflineChip(detail: "this list needs a connection").padding(.horizontal, 6) } }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                PillButton(id: "rp-send", title: sending ? "Sending\u{2026}" : "Send report", symbol: "paperplane.fill", style: .primary, enabled: problem == nil && !sending) { Task { await send() } }
                Text("Sent: your device model, iOS and app version, the version of the game engine (\(CompatEngine.label)), the answers above, and the game's log (private: only the developer reads it, and it is cleaned of personal paths and account names). Not sent: your name or any account. Every report is checked before it appears in Reports.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .task { log = await CompatLog.gather(for: game); logLoading = false }
    }

    private func done(_ outcome: CompatStore.SubmitResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Theme.good).shadow(color: Theme.good.opacity(0.6), radius: 14)
            Text("Thank you").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
            switch outcome {
            case .sent(let logSent): Text(logSent ? "Your report and the game's log are in. Every report is checked before it appears in Reports, so yours will show once it has been approved."
                                                  : "Your report is in, without a log. Every report is checked before it appears in Reports, so yours will show once it has been approved.")
            case .queued: Text("The compatibility server couldn't be reached, so your report is saved and will be sent when it can.")
            }
            PillButton(id: "rp-done", title: "Done", style: .primary) { dismiss() }
        }
        .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity)
        .onAppear { scope.focused = "rp-done" }
    }

    private func send() async {
        guard let rating else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            var attached = log
            if attached == nil { attached = await CompatLog.gather(for: game) }
            outcome = try await compat.submit(game: game, rating: rating, stability: stability, tags: tags.sorted { $0.rawValue < $1.rawValue },
                                              source: fromSteam ? .steam : (source ?? .other), stats: stats, shareNumbers: includeMeasured, shareSettings: shareSettings, comment: comment, log: attached)
        } catch { self.error = error.localizedDescription }
    }
}
