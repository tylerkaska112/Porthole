// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// On a game's page, only when the game's folder holds files of a modified release: an honest note. The game starts like any other; nothing is blocked.
struct CopyNoteCard: View {
    let game: Game
    @ObservedObject private var check = CopyCheck.shared

    var body: some View {
        Group {
            if !check.marks(for: game).isEmpty {
                SettingsGroup(title: "About this copy") {
                    Text(CopyMarkers.note).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: game.id) { check.refresh(for: game) }
    }
}
