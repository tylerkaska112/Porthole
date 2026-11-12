// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// At the top of a game's Performance section: how people who say this game works great have it set up, set against this game now, with one button to use it.
struct RecommendedSettingsGroup: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @ObservedObject private var compat = CompatStore.shared
    @State private var state: Load = .idle
    @State private var confirm = false

    private enum Load: Equatable {
        case idle, loading, none, failed(String)
        case ready(Plan)
    }
    private typealias Plan = CommunitySettings.Plan

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        if let g = game, compat.showBadges {
            SettingsGroup(title: "What works for others") {
                content(g)
                if g.settingsUndo != nil {
                    ActionRow(id: "rec-undo", symbol: "arrow.uturn.backward", title: "Undo the last applied suggestions", subtitle: "Puts this game's settings back as they were", chevron: false) { model.update(g) { RecommendedSettings.undo(&$0) }; state = .idle; Task { await load(g, force: true) } }
                }
            }
            .task { await load(g) }
            .confirm("Use these settings?", message: "Changes only this game's own settings. You can undo it.", confirmTitle: "Apply", isPresented: $confirm) {
                if case .ready(let plan) = state { model.update(g) { RecommendedSettings.apply(plan.changes, recommended: plan.recommended, to: &$0) }; state = .idle; Task { await load(g, force: true) } }
            }
        }
    }

    @ViewBuilder private func content(_ g: Game) -> some View {
        switch state {
        case .idle, .loading:
            HStack { ProgressView(); Text("Looking at what others use\u{2026}").foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
        case .none:
            Text("Nobody who says this game works great has shared their settings yet. Share yours when you report on it and it will help the next person.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        case .failed(let why):
            Text(why).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6)
        case .ready(let plan):
            if plan.changes.isEmpty {
                Text("This game's settings already match what most of the \(plan.reports) people who say it works great use.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            } else {
                Text("Most of \(plan.reports) people who say it works great\(plan.earlierEngine ? " (on earlier versions of the engine)" : "") use:").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                ForEach(plan.changes) { c in
                    ValueRow(id: "rec-\(c.key)", symbol: "arrow.right.circle.fill", title: c.title, value: "\(c.from) \u{2192} \(c.to)  (\(c.count) of \(plan.reports))")
                }
                ActionRow(id: "rec-apply", symbol: "checkmark.circle.fill", title: "Use these \(plan.changes.count) setting\(plan.changes.count == 1 ? "" : "s")", subtitle: "Only for this game; you can undo it", chevron: false, prominent: true) { confirm = true }
            }
        }
    }

    private func load(_ g: Game, force: Bool = false) async {
        if !force, state != .idle { return }
        state = .loading
        do { state = try await CommunitySettings.load(for: g).map { .ready($0) } ?? .none } catch { state = .failed(ErrorText.plain(error)) }
    }
}
