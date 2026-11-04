// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Game details > Share this game's setup / Apply a shared setup (Core/GameSetupShare.swift).
struct SharedSetupSheet: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var found: SharedSetup?
    @State private var message: String?
    @State private var picking = false

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        GameSubSheet(title: "Apply a shared setup", scope: scope, close: { dismiss() }) {
            if let found {
                SettingsGroup(title: "Made for \(found.name)") {
                    ForEach(Array(GameSetupShare.summary(found).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                    }
                    if let game, !match(found, game) {
                        Text("This setup was made for a different game (\(found.programName)). Settings that suit one game can break another.").font(.footnote).foregroundStyle(Theme.warn)
                    }
                    Text("Applying replaces this game's launch options, per-game settings, engine choices and saved controls. Its program, art and play time stay.").font(.footnote).foregroundStyle(Theme.textDim)
                }
                PillButton(id: "ss-apply", title: "Apply to \(game?.name ?? "this game")", symbol: "checkmark", style: .primary) {
                    if let game { model.update(game) { $0 = GameSetupShare.applied(found, to: $0) } }
                    dismiss()
                }
                PillButton(id: "ss-other", title: "Use a different setup", symbol: "arrow.uturn.backward") { self.found = nil; message = nil }
            } else {
                SettingsGroup(title: "Where is the setup?") {
                    PillButton(id: "ss-clip", title: "Read it from the clipboard", symbol: "doc.on.clipboard") { fromClipboard() }
                    PillButton(id: "ss-file", title: "Choose a file", symbol: "folder") { picking = true }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
                Text("A setup is a \u{201C}.\(GameSetupShare.fileExtension)\u{201D} file or one line of text that starts with \u{201C}porthole-setup1:\u{201D}, made with Share this game's setup.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
        }
        .sheet(isPresented: $picking) {
            FilePickerSheet(onPick: { urls in
                picking = false
                guard let url = urls.first else { return }
                if let setup = GameSetupShare.parse(file: url) { found = setup; message = nil } else { message = "That file is not a Porthole setup." }
            }, onCancel: { picking = false })
        }
    }

    private func fromClipboard() {
        if let text = UIPasteboard.general.string, let setup = GameSetupShare.parse(text) { found = setup; message = nil }
        else { message = "The clipboard does not hold a Porthole setup." }
    }

    private func match(_ setup: SharedSetup, _ game: Game) -> Bool {
        if let a = setup.steamAppID, let b = game.steamAppID, a > 0, b > 0 { return a == b }
        return game.exe.split(separator: "\\").last.map(String.init)?.caseInsensitiveCompare(setup.programName) == .orderedSame
    }
}
