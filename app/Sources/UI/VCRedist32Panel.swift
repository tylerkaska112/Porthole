// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The 32-bit Visual C++ runtime (Microsoft's own x86 installer, taken apart on the device and checked), as kit rows. Used in the setup guide beside the other runtimes.
struct VCRedist32Panel: View {
    @ObservedObject private var vc = VCRedistModel.shared

    var body: some View {
        SettingsGroup(title: "32-bit programs (optional)", note: "Older games and many launchers are 32-bit programs. They run on Wine's own C++ runtime unless you add Microsoft's. You can also do this later in Settings \u{203A} Advanced \u{203A} Windows components.") {
            ValueRow(id: "vc32-state", symbol: vc.complete ? "checkmark.seal.fill" : "shippingbox.fill", title: "32-bit Visual C++ runtime",
                     value: vc.complete ? "Installed" : (vc.busy ? "Working\u{2026}" : "Not installed"), statusColor: vc.complete ? Theme.good : Theme.textDim)
            switch vc.phase {
            case .downloading(let fraction):
                HStack(spacing: 10) { ProgressView(value: fraction).tint(Theme.accent); Text("\(Int(fraction * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
            case .installing(let fraction):
                HStack(spacing: 10) { ProgressView(value: fraction).tint(Theme.accent); Text("Checking \(Int(fraction * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
            case .idle: EmptyView()
            }
            if let error = vc.error { Text(error).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            if !vc.complete && !vc.busy {
                ActionRow(id: "vc32-main", symbol: "arrow.down.circle.fill", title: "Download", subtitle: "About \(VCRedistPin.totalMegabytes) MB, from Microsoft", chevron: false) { vc.install() }
            } else if vc.complete && !vc.busy {
                ActionRow(id: "vc32-remove", symbol: "trash.fill", title: "Remove the downloaded copy", destructive: true, chevron: false) { vc.remove() }
            }
        }
        .onAppear { vc.refresh() }
    }
}
