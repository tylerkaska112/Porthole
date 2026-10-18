// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Whether the person has read the Workshop beta notice.
enum WorkshopBeta {
    private static let key = "steam.workshopBetaNoticeSeen.v1"
    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let headline = "Workshop is in beta"
    static let text = "It is mostly untested: only a few games have been tried. Portal 2 (maps) and American Truck Simulator (mods) are known to work. Other games, especially older ones, may not pick up their items yet, and some Workshop items can only be downloaded when the game is closed."
}

/// The notice shown the first time the Workshop is opened, until it is dismissed.
struct WorkshopBetaNotice: View {
    var compact = false
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text(WorkshopBeta.headline).font(.system(size: compact ? 14 : 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                BetaBadge()
            }
            Text(WorkshopBeta.text).font(.system(size: compact ? 12 : 14)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Text("I understand").font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 20).padding(.vertical, 8).background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .focusTarget("ws-beta-ok", radius: 16) { dismiss() }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warn.opacity(0.6), lineWidth: 1))
    }
}

/// A game's Steam Workshop: what the account is subscribed to, and the game's community items to browse, search and subscribe to.
/// Subscribing is done on Steam (so it shows in Steam's own client too) and the files are saved where the game looks for them.
struct SteamWorkshopContent: View {
    let appID: Int
    let name: String
    @ObservedObject var store: SteamStore
    @ObservedObject private var workshop = SteamWorkshopStore.shared

    enum Mode: String, CaseIterable { case subscribed, browse }

    @State private var mode = Mode.subscribed
    @AppStorage("f4.workshopAutoUpdate") private var autoUpdate = true
    @State private var sort = SteamWorkshopSort.trending
    @State private var search = ""
    @State private var searched = ""
    @State private var subscribedItems: [SteamWorkshopItem] = []
    @State private var subscribedLoaded = false
    @State private var browseItems: [SteamWorkshopItem] = []
    @State private var browseTotal = 0
    @State private var page = 0
    @State private var installed: [UInt64: SteamWorkshopFiles.Installed] = [:]
    @State private var loading = false
    @State private var failure: String?
    @State private var note: String?
    @State private var removing: SteamWorkshopItem?
    @State private var confirmRemove = false
    @State private var showNotice = !WorkshopBeta.seen

    private var subscribedIDs: Set<UInt64> { Set(subscribedItems.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showNotice { WorkshopBetaNotice { WorkshopBeta.seen = true; withAnimation { showNotice = false } } }
            SettingsGroup {
                ChoiceRow(id: "sw-mode", symbol: "square.stack.3d.down.right.fill", title: "Show",
                          options: [(Mode.subscribed, "Subscribed"), (Mode.browse, "Browse and search")], selection: $mode)
                if mode == .browse {
                    ChoiceRow(id: "sw-sort", symbol: "arrow.up.arrow.down", title: "Order", options: SteamWorkshopSort.allCases.map { ($0, $0.title) }, selection: $sort)
                    TextFieldRow(id: "sw-search", symbol: "magnifyingglass", title: "Search", placeholder: "Name of an item", info: nil, secure: false, text: $search)
                    ActionRow(id: "sw-go", symbol: "arrow.right.circle.fill", title: "Search", chevron: false) { Task { await startBrowse() } }
                }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6)
                ActionRow(id: "sw-retry", symbol: "arrow.clockwise", title: "Try again", chevron: false) { Task { await reload() } }
            }
            switch mode {
            case .subscribed: subscribedList
            case .browse: browseList
            }
            Text("Items are saved with the game's other Steam files, where the game and Steam look for them. Subscribing and unsubscribing happen on your Steam account.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        }
        .task { await loadSubscribed(sync: autoUpdate) }
        .onChange(of: mode) { _, new in
            if new == .browse, browseItems.isEmpty { Task { await startBrowse() } }
        }
        .onChange(of: workshop.changes) { _, _ in Task { installed = await workshop.installed(appID: appID) } }
        .confirm("Remove \(removing?.title ?? "this item")?", message: "This unsubscribes you on Steam and deletes its files from this device.", confirmTitle: "Remove", destructive: true, isPresented: $confirmRemove) {
            if let item = removing { Task { await unsubscribe(item) } }
        }
    }

    // MARK: Lists

    @ViewBuilder private var subscribedList: some View {
        if loading && !subscribedLoaded {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
        } else if subscribedLoaded && subscribedItems.isEmpty && failure == nil {
            Text("You are not subscribed to any \(name) Workshop items. Choose \u{201C}Browse and search\u{201D} to find some.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        } else if !subscribedItems.isEmpty {
            SettingsGroup(title: "Subscribed") { ForEach(subscribedItems) { row($0) } }
            ToggleRow(id: "sw-auto", symbol: "arrow.down.circle", title: "Update mods automatically", subtitle: "Checks when this game's page opens",
                      info: "When a mod you are subscribed to has a newer version on Steam, Porthole downloads it when you open the game's page. Turn this off to update only with the button below.",
                      isOn: $autoUpdate)
            ActionRow(id: "sw-sync", symbol: "arrow.triangle.2.circlepath", title: "Download missing and updated items", chevron: false) { Task { await loadSubscribed(sync: true, force: true) } }
        }
    }

    @ViewBuilder private var browseList: some View {
        if loading && browseItems.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
        } else if browseItems.isEmpty && failure == nil && page > 0 {
            Text(searched.isEmpty ? "\(name) has no Workshop items." : "Nothing found for \u{201C}\(searched)\u{201D}.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        } else if !browseItems.isEmpty {
            SettingsGroup(title: searched.isEmpty ? sort.title : "Results") { ForEach(browseItems) { row($0) } }
            if browseItems.count < browseTotal {
                ActionRow(id: "sw-more", symbol: "ellipsis.circle", title: loading ? "Loading\u{2026}" : "Show more", subtitle: "\(browseItems.count) of \(browseTotal)", chevron: false) { Task { await loadMore() } }
            }
        }
    }

    // MARK: A row

    private func row(_ item: SteamWorkshopItem) -> some View {
        let key = SteamWorkshopStore.key(appID, item.id)
        let state = workshop.progress[key]
        let isSubscribed = subscribedIDs.contains(item.id)
        let present = installed[item.id]
        return Button { primary(item, subscribed: isSubscribed, busy: state != nil) } label: {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: item.previewURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Theme.panelHigh.overlay { Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.textDim) } }
                }
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    if !item.summary.isEmpty { Text(item.summary).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(2).multilineTextAlignment(.leading) }
                    Text(stats(item)).font(.caption).foregroundStyle(Theme.textDim)
                    status(state: state, subscribed: isSubscribed, present: present, item: item)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .focusTarget("sw-\(item.id)", radius: 16, scale: 1.012, action: { primary(item, subscribed: isSubscribed, busy: state != nil) })
    }

    @ViewBuilder private func status(state: SteamWorkshopStore.Progress?, subscribed: Bool, present: SteamWorkshopFiles.Installed?, item: SteamWorkshopItem) -> some View {
        switch state?.state {
        case .active?:
            ProgressView(value: state?.fraction ?? 0).tint(Theme.accent)
            Text("Downloading\u{2026}").font(.caption).foregroundStyle(Theme.accent)
        case .queued?:
            Text("Waiting\u{2026}").font(.caption).foregroundStyle(Theme.textDim)
        case .waiting?:
            Text("Subscribed \u{00B7} downloads when the game closes").font(.caption).foregroundStyle(Theme.accent)
        case .failed(let why)?:
            Text(why).font(.caption).foregroundStyle(Theme.bad).multilineTextAlignment(.leading)
            Text("Tap to try again").font(.caption).foregroundStyle(Theme.accent)
        case nil:
            if subscribed {
                if present != nil { Text("Subscribed \u{00B7} on this device \u{00B7} tap to remove").font(.caption).foregroundStyle(Theme.good) }
                else if item.canDownload { Text("Subscribed \u{00B7} tap to download").font(.caption).foregroundStyle(Theme.accent) }
                else { Text("Subscribed").font(.caption).foregroundStyle(Theme.textDim) }
            } else {
                Text(item.canDownload ? "Tap to subscribe and download" : "Tap to subscribe").font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }

    private func stats(_ item: SteamWorkshopItem) -> String {
        var parts: [String] = []
        if let rating = item.rating { parts.append("\(Int((rating * 100).rounded()))% liked") }
        if item.subscriptions > 0 { parts.append("\(item.subscriptions.formatted(.number.notation(.compactName))) subscribers") }
        if item.fileSize > 0 { parts.append(SteamGameTile.size(item.fileSize)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Actions

    private func primary(_ item: SteamWorkshopItem, subscribed: Bool, busy: Bool) {
        note = nil
        if let state = workshop.progress[SteamWorkshopStore.key(appID, item.id)]?.state {
            if case .failed = state { workshop.retry(appID: appID, item: item.id, gameName: name, title: item.title) }
            return
        }
        if subscribed {
            if installed[item.id] == nil, item.canDownload { workshop.retry(appID: appID, item: item.id, gameName: name, title: item.title) }
            else { removing = item; confirmRemove = true }
            return
        }
        Task {
            do {
                try await workshop.subscribe(item, gameName: name)
                if !subscribedItems.contains(where: { $0.id == item.id }) { subscribedItems.insert(item, at: 0) }
            } catch { note = SteamSignIn.message(error) }
        }
    }

    private func unsubscribe(_ item: SteamWorkshopItem) async {
        do {
            try await workshop.unsubscribe(id: item.id, appID: appID)
            subscribedItems.removeAll { $0.id == item.id }
            installed[item.id] = nil
        } catch { note = SteamSignIn.message(error) }
    }

    private func reload() async {
        failure = nil
        if mode == .subscribed { await loadSubscribed(sync: true, force: true) } else { await startBrowse() }
    }

    private func loadSubscribed(sync: Bool, force: Bool = false) async {
        guard force || !subscribedLoaded else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            subscribedItems = try await workshop.subscribed(appID: appID)
            subscribedLoaded = true
            installed = await workshop.installed(appID: appID)
            if sync {
                let queued = try await workshop.sync(appID: appID, gameName: name)
                note = queued > 0 ? "Downloading \(queued) item\(queued == 1 ? "" : "s")\u{2026}" : nil
            }
        } catch { failure = SteamSignIn.message(error) }
    }

    private func startBrowse() async {
        searched = search.trimmingCharacters(in: .whitespacesAndNewlines)
        browseItems = []; browseTotal = 0; page = 0
        await loadMore()
        if !subscribedLoaded { await loadSubscribed(sync: false) }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let result = try await workshop.browse(appID: appID, sort: sort, search: searched, page: page + 1)
            page += 1
            browseTotal = result.total
            let known = Set(browseItems.map(\.id))
            browseItems += result.items.filter { !known.contains($0.id) }
        } catch { failure = SteamSignIn.message(error) }
    }
}
