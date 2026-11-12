// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// On the Performance page of a game Madeira has a tested setup for: what it contains, and one button to use it. Nothing changes until the person chooses; Undo brings the
/// previous engine lines and settings back.
struct TestedSetupGroup: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @State private var confirm = false

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        if let g = game, let rec = GameTestedSetup.recommendation(for: g) {
            let plan = GameTestedSetup.plan(rec)
            let mine = GameTestedSetup.ownSetup(for: rec)
            SettingsGroup(title: mine == nil ? "Madeira\u{2019}s tested setup" : "Porthole\u{2019}s tested setup") {
                Text(mine.map { "Found to work for \(rec.title) on Porthole\u{2019}s own engine, on \($0.tested) Use it if the game does not start or runs badly, and undo it if it does not help." }
                     ?? "The Madeira project found these settings to work for \(rec.title) on its own builds. They have not been tested on Porthole\u{2019}s engine: use them if the game does not start or runs badly, and undo them if it gets worse.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                ValueRow(id: "ts-lines", symbol: "text.alignleft", title: "Engine lines", value: "\(plan.lines)")
                if !plan.applied.isEmpty {
                    ValueRow(id: "ts-switches", symbol: "slider.horizontal.3", title: "Also sets", value: plan.applied.joined(separator: ", "))
                }
                if !plan.skipped.isEmpty {
                    Text("Not applied (Porthole keeps these elsewhere): " + plan.skipped.joined(separator: "; ") + ".").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
                ActionRow(id: "ts-apply", symbol: "checkmark.circle.fill", title: "Use this setup",
                          subtitle: (g.engine?.config ?? "").isEmpty ? "Only for this game; you can undo it" : "Replaces this game\u{2019}s engine lines; you can undo it", chevron: false, prominent: true) { confirm = true }
                if g.testedSetupUndo != nil {
                    ActionRow(id: "ts-undo", symbol: "arrow.uturn.backward", title: "Undo \(mine == nil ? "Madeira" : "Porthole")\u{2019}s tested setup", subtitle: "Puts this game\u{2019}s engine lines and settings back as they were", chevron: false) {
                        model.update(g) { game in
                            guard let undo = game.testedSetupUndo else { return }
                            game.engine = undo.engine; game.settings = undo.settings; game.testedSetupUndo = nil
                        }
                    }
                }
            }
            .confirm("Use \(mine == nil ? "Madeira" : "Porthole")\u{2019}s tested setup?", message: (g.engine?.config ?? "").isEmpty ? "Writes \(plan.lines) engine lines and the switches above for this game only. You can undo it."
                     : "Replaces this game\u{2019}s engine lines with \(plan.lines) lines and sets the switches above. Your current lines are kept for Undo.", confirmTitle: "Use it", isPresented: $confirm) {
                model.update(g) { game in game.testedSetupUndo = GameTestedSetup.apply(rec, to: &game) }
            }
        }
    }
}
