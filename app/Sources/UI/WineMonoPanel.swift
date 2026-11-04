// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The .NET download (Wine Mono, from WineHQ, checked and unpacked on the device), as kit rows. Used in the setup guide beside the Visual C++ runtime.
struct WineMonoPanel: View {
    @ObservedObject private var mono = WineMonoModel.shared

    var body: some View {
        SettingsGroup(title: ".NET (optional)", note: "Only for games built on Microsoft's .NET Framework, such as Celeste. You can also download it later in Settings \u{203A} Advanced \u{203A} Windows components.") {
            ValueRow(id: "wm-state", symbol: WineMonoModel.available ? "checkmark.seal.fill" : "shippingbox.fill", title: ".NET support (Wine Mono)",
                     value: WineMonoModel.bundled ? "Included" : (mono.installed ? "Installed" : (mono.busy ? "Working\u{2026}" : "Not installed")),
                     statusColor: WineMonoModel.available ? Theme.good : Theme.textDim)
            switch mono.phase {
            case .downloading(let fraction):
                HStack(spacing: 10) { ProgressView(value: fraction).tint(Theme.accent); Text("\(Int(fraction * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
            case .installing(let fraction):
                HStack(spacing: 10) { ProgressView(value: fraction).tint(Theme.accent); Text("Unpacking \(Int(fraction * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
            case .idle: EmptyView()
            }
            if let error = mono.error { Text(error).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            if !WineMonoModel.available && !mono.busy {
                ActionRow(id: "wm-main", symbol: "arrow.down.circle.fill", title: "Download", subtitle: "About 42 MB, from WineHQ", chevron: false) { mono.install() }
            } else if mono.installed && !mono.busy {
                ActionRow(id: "wm-remove", symbol: "trash.fill", title: "Remove the downloaded copy", destructive: true, chevron: false) { mono.remove() }
            }
        }
    }
}
