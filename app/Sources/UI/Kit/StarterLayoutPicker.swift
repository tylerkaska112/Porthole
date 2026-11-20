// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Chooses the layout to start a game's touch controls from: the ones Porthole ships, each drawn, and an empty screen. `onPick` gets the layout and its name ("Action", "Empty screen"); the
/// caller decides what it replaces or adds.
struct StarterLayoutPicker: View {
    var title = "Start from a layout"
    var onPick: (TouchLayout, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "sl-close", title: "Cancel", symbol: "xmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Each one is a starting point you can change afterwards with the pencil. Choosing one replaces the controls you have now (Undo in the editor brings them back).")
                            .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(ShippedLayouts.all) { l in card(id: l.id, title: l.title, detail: l.detail, layout: l.layout) }
                            card(id: "empty", title: "Empty screen", detail: "No controls: put each one where you want it.", layout: TouchLayout())
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 30)
                }
            }
        }
        .navScope(scope)
    }

    private func card(id: String, title: String, detail: String, layout: TouchLayout) -> some View {
        Button { onPick(layout, title); dismiss() } label: {
            VStack(alignment: .leading, spacing: 10) {
                LayoutPreview(layout: layout)
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textDim).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text("\(layout.controls.count) control\(layout.controls.count == 1 ? "" : "s")").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim.opacity(0.8))
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(TilePress())
        .focusTarget("sl-\(id)", radius: 16, scale: 1.02) { onPick(layout, title); dismiss() }
    }
}
