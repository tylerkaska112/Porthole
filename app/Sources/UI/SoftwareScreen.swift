// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The Stores tab's Software section: Windows programs that are not games (Blender for now). Each is a row that opens its own page (SoftwareDetailScreen), where it is
/// downloaded, started, updated and removed, with its add-ons and what is known to be limited or wrong with it.
struct SoftwareScreen: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var store = SoftwareStore.shared

    private func back() { router.storesSelection = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PillButton(id: "sw-back", title: "Stores", symbol: "chevron.left", action: back)
                Spacer()
                PillButton(id: "sw-refresh", title: store.loading ? "Checking" : "Check for updates", symbol: "arrow.clockwise", enabled: !store.loading) { Task { await store.refresh() } }
            }
            .padding(.horizontal, 24).padding(.top, 8)
            FocusScroll {
                PageScaffold(title: "Software", symbol: "shippingbox.fill",
                             subtitle: "Programs that run in Porthole. They are not part of the app: you download the ones you want, and they update here.") {
                    if let error = store.listError { Text(error).font(.footnote).foregroundStyle(Theme.warn) }
                    ForEach(store.programs) { item in row(item) }
                    if store.programs.isEmpty && !store.loading && store.listError == nil {
                        Text("Nothing is on offer right now.").font(.system(size: 15, design: .rounded)).foregroundStyle(Theme.textDim)
                    }
                    losslessRow
                    Text("More programs will show up here as Porthole learns them.").font(.footnote).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
        }
        .onNavBack { back(); return true }
        .task { await store.refresh() }
    }

    /// Lossless Scaling: not a download from Porthole's own server but the licence check and the file from the user's Steam account (LosslessScalingPage).
    private var losslessRow: some View {
        Button { router.storesSelection = .softwareItem("lossless-scaling") } label: {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.rays").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.accentGradient).frame(width: 54, height: 54)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Lossless Scaling").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Text("Needs your own copy from Steam").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim)
                    Text("Frame generation for Direct3D 11 and 12 games. Checks your Steam purchase and downloads your copy.").font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.textDim)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A program: its name and state, and the way to its page. Nothing is downloaded from here.
    private func row(_ item: SoftwareItem) -> some View {
        let state = store.state(item)
        let installed = store.installed[item.id]
        let update = store.updateAvailable(item)
        let addonUpdate = store.addons(of: item.id).contains { store.updateAvailable($0) }
        return Button { router.storesSelection = .softwareItem(item.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: item.symbol ?? "shippingbox.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.accentGradient).frame(width: 54, height: 54)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Text(SoftwareFormat.statusLine(item, installed: installed, update: update)).font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(update ? Theme.accent : Theme.textDim)
                    Text(item.summary).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2)
                    SoftwareProgress(state: state)
                    if addonUpdate && !update { Text("An update for its GPU kernels is available").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.textDim)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(update || addonUpdate ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .focusTarget("sw-open-\(item.id)", radius: 22, scale: 1.01) { router.storesSelection = .softwareItem(item.id) }
        .accessibilityElement(children: .combine)
    }
}

/// Words and small views the list and the program pages share.
enum SoftwareFormat {
    static func statusLine(_ item: SoftwareItem, installed: SoftwareInstalled?, update: Bool) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)
        guard let installed else { return "Version \(item.version) \u{00B7} \(size) to download" }
        return update ? "Installed \(installed.version) \u{00B7} \(item.version) available (\(size))" : "Installed \u{00B7} version \(installed.version)"
    }
}

/// The bar and the words while something is downloading, being checked or unpacked.
struct SoftwareProgress: View {
    let state: SoftwareStore.State
    var body: some View {
        switch state {
        case .downloading(let f): bar(f, "Downloading \(Int(f * 100))%")
        case .verifying: bar(1, "Checking the download")
        case .unpacking(let f): bar(f, "Unpacking \(Int(f * 100))%")
        default: EmptyView()
        }
    }

    private func bar(_ fraction: Double, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(.white.opacity(0.1)).frame(height: 6)
                .overlay(alignment: .leading) { GeometryReader { geo in Capsule().fill(Theme.accentGradient).frame(width: max(6, geo.size.width * fraction)) } }
            Text(text).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
        }
    }
}

/// The buttons of one downloadable thing: Download, or Start / Update / Remove once it is installed, Cancel while it comes down.
struct SoftwareButtons: View {
    let item: SoftwareItem
    var startable = true
    @ObservedObject private var store = SoftwareStore.shared
    @EnvironmentObject private var session: SessionController

    var body: some View {
        let state = store.state(item)
        let installed = store.isInstalled(item)
        let update = store.updateAvailable(item)
        FlowLayout(spacing: 10) {
            if state.busy {
                if case .downloading = state { PillButton(id: "sw-cancel-\(item.id)", title: "Cancel", symbol: "xmark") { store.cancel(item) } }
            } else if !installed {
                PillButton(id: "sw-get-\(item.id)", title: "Download", symbol: "arrow.down.circle.fill", style: .primary) { store.install(item) }
            } else {
                if startable, let game = store.game(for: item) {
                    PillButton(id: "sw-open-\(item.id)", title: session.isActive ? "Busy" : "Start", symbol: "play.fill", style: update ? .glass : .primary, enabled: !session.isActive) { session.start(game) }
                }
                if update { PillButton(id: "sw-update-\(item.id)", title: "Update", symbol: "arrow.triangle.2.circlepath", style: .primary, enabled: !session.isActive) { store.install(item) } }
                PillButton(id: "sw-remove-\(item.id)", title: "Remove", symbol: "trash", style: .danger, enabled: !session.isActive) { store.remove(item) }
            }
        }
    }
}
