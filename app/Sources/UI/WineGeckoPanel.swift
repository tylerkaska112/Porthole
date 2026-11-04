// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The web-page engine download (Wine Gecko, from WineHQ, checked before use), as kit rows. Used in the setup guide beside the Visual C++ runtime and .NET.
struct WineGeckoPanel: View {
    @ObservedObject private var gecko = WineGeckoModel.shared

    var body: some View {
        SettingsGroup(title: "Web pages in programs (optional)", note: "Launchers and installers that show a web page need Wine's web engine. Without it Wine stops on its own download window, which can hang. You can also do this later in Settings \u{203A} Advanced \u{203A} Windows components.") {
            ValueRow(id: "wg-state", symbol: WineGeckoModel.available ? "checkmark.seal.fill" : "globe", title: "Web engine (Wine Gecko)",
                     value: gecko.installed ? "Installed" : (gecko.busy ? "Working\u{2026}" : "Not installed"),
                     statusColor: gecko.installed ? Theme.good : Theme.textDim)
            if let progress = gecko.progress {
                HStack(spacing: 10) { ProgressView(value: progress).tint(Theme.accent); Text("\(Int(progress * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
            }
            if let error = gecko.error { Text(error).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            if !gecko.installed && !gecko.busy {
                ActionRow(id: "wg-main", symbol: "arrow.down.circle.fill", title: "Download", subtitle: "About 110 MB, from WineHQ", chevron: false) { gecko.install() }
            } else if gecko.installed && !gecko.busy {
                ActionRow(id: "wg-remove", symbol: "trash.fill", title: "Remove the downloaded copy", destructive: true, chevron: false) { gecko.remove() }
            }
        }
        .onAppear { gecko.refresh() }
    }
}
