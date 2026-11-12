// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// One program's page in Software: the program itself (download, start, update, remove), its add-ons (Blender's GPU kernels: the one built for this device if there is one, else
/// the one that works anywhere), and what is known to be limited or wrong with it. The known list is part of the Software list the app reads, so it changes without an app update.
struct SoftwareDetailScreen: View {
    let id: String
    @Environment(AppRouter.self) private var router
    @ObservedObject private var store = SoftwareStore.shared

    private func back() { router.storesSelection = .software }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PillButton(id: "swd-back", title: "Software", symbol: "chevron.left", action: back)
                Spacer()
                PillButton(id: "swd-refresh", title: store.loading ? "Checking" : "Check for updates", symbol: "arrow.clockwise", enabled: !store.loading) { Task { await store.refresh() } }
            }
            .padding(.horizontal, 24).padding(.top, 8)
            FocusScroll {
                if let item = store.item(id) {
                    PageScaffold(title: item.title, symbol: item.symbol ?? "shippingbox.fill", subtitle: item.summary) {
                        programCard(item)
                        addons(of: item)
                        known(item)
                    }
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                } else {
                    PageScaffold(title: "Software", symbol: "shippingbox.fill") {
                        Text(store.loading ? "Loading the list" : "This program is not on offer for this device right now.").font(.system(size: 15, design: .rounded)).foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
            }
        }
        .onNavBack { back(); return true }
        .task { await store.refresh() }
    }

    // MARK: The program

    private func panel<Content: View>(update: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(update ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
    }

    private func programCard(_ item: SoftwareItem) -> some View {
        let installed = store.installed[item.id]
        let update = store.updateAvailable(item)
        return SettingsGroup(title: "Program", note: nil) {
            panel(update: update) {
                Text(SoftwareFormat.statusLine(item, installed: installed, update: update)).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(update ? Theme.accent : Theme.text)
                if update, let notes = item.notes { Text("New: " + notes).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) }
                SoftwareProgress(state: store.state(item))
                failure(item)
                SoftwareButtons(item: item)
            }
        }
    }

    @ViewBuilder private func failure(_ item: SoftwareItem) -> some View {
        if case .failed(let why) = store.state(item) { Text(why).font(.footnote).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true) }
    }

    // MARK: Add-ons (the GPU kernels)

    /// The pack to offer: built for this device's GPU and system version if there is one, else the one that works anywhere.
    private func recommended(_ list: [SoftwareItem]) -> SoftwareItem? { list.first { $0.arch != nil } ?? list.first }

    @ViewBuilder private func addons(of program: SoftwareItem) -> some View {
        let list = store.addons(of: program.id)
        if let pack = recommended(list) {
            let exact = pack.arch != nil
            let now = store.installedAddon(of: program.id)
            let update = store.updateAvailable(pack)
            SettingsGroup(title: "GPU rendering", note: "Rendering on the GPU needs its render kernels. A pack made for your device starts at once and renders everything; one that works anywhere has to build part of them on the device.") {
                panel(update: update || (exact && now != nil && now?.id != pack.id)) {
                    HStack(spacing: 10) {
                        Image(systemName: exact ? "checkmark.seal.fill" : "bolt.horizontal.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(exact ? Theme.good : Theme.accent)
                        Text(pack.title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    }
                    Text(exact
                         ? "Made for this device's GPU on iOS \(pack.os ?? SoftwareStore.systemVersion): shadows of see-through surfaces (leaves, glass) render as they should."
                         : "Works on any GPU and system version. Shadows of see-through surfaces (leaves, glass) come out solid, and the first render builds part of the kernels on the device.")
                        .font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    if let now, now.id != pack.id {
                        Text(exact ? "Installed now: the pack that works anywhere. This one is made for your device and adds those shadows." : "Installed now: \(now.title).")
                            .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(SoftwareFormat.statusLine(pack, installed: store.installed[pack.id], update: update)).font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(update ? Theme.accent : Theme.textDim)
                    SoftwareProgress(state: store.state(pack))
                    failure(pack)
                    SoftwareButtons(item: pack, startable: false)
                    if !exact {
                        Text("A pack made for your exact GPU and system version is not published yet. When it is, it shows here instead.").font(.footnote).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Known limitations and problems

    @ViewBuilder private func known(_ item: SoftwareItem) -> some View {
        let all = item.known ?? []
        let limits = all.filter { $0.kind != "problem" }, problems = all.filter { $0.kind == "problem" }
        if !limits.isEmpty { issues(title: "Known limitations", note: "How it is meant to work here, or what cannot be helped for now.", symbol: "info.circle.fill", tint: Theme.accent, limits) }
        if !problems.isEmpty { issues(title: "Known problems", note: "Things that are wrong and are being looked at.", symbol: "exclamationmark.triangle.fill", tint: Theme.warn, problems) }
        if all.isEmpty { SettingsGroup(title: "Known limitations and problems") { Text("Nothing is listed yet.").font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim) } }
        SettingsGroup(title: "Found something else?") {
            ActionRow(id: "swd-report", symbol: "paperplane.fill", title: "Report a problem", subtitle: "Send what happened, with the log, from Settings") { router.openSettings(.report) }
        }
    }

    private func issues(title: String, note: String, symbol: String, tint: Color, _ list: [KnownIssue]) -> some View {
        SettingsGroup(title: title, note: note) {
            panel {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 { Divider().overlay(Theme.line) }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(tint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            Text(issue.detail).font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                            if let found = issue.found { Text(found).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim.opacity(0.8)) }
                        }
                    }
                }
            }
        }
    }
}
