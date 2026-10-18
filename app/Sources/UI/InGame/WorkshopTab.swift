// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The Steam tab of the in-game menu. Today it holds the Workshop; friends, chat and the rest of Steam's features join it here as sections.
struct SteamTab: View {
    @ObservedObject var model: GameMenuModel

    /// The parts of Steam available in the game. With one part there is nothing to choose, so no picker is shown.
    enum Section: String, CaseIterable, Identifiable {
        case achievements, friends, workshop, news
        var id: String { rawValue }
        var title: String { switch self { case .achievements: "Achievements"; case .friends: "Friends"; case .workshop: "Workshop"; case .news: "News" } }
    }

    @State private var section = Section.achievements
    @State private var overlayOpens = AchievementToastCenter.overlayOpensMenu

    var body: some View {
        if Section.allCases.count > 1 {
            MenuCard(title: "Steam") {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, item in
                    if index > 0 { MenuDivider() }
                    MenuChoiceRow(title: item.title, selected: section == item) { section = item }
                }
            }
        }
        Color.clear.frame(height: 0).onAppear { takeRequestedSection() }
            .onChange(of: model.requestedSteamSection) { _, _ in takeRequestedSection() }
        switch section {
        case .achievements: AchievementsTab(model: model)
        case .friends: SteamFriendsList()
        case .news: SteamNewsList(appID: model.steamAppID ?? 0, canOpen: false)
        case .workshop: WorkshopTab(model: model)
        }
        MenuCard(title: "Steam's overlay", footer: "A game's Steam buttons (Workshop, Store) and Shift+Tab ask for Steam's overlay, which cannot draw here and would leave the game not answering. With this on, this menu opens instead.") {
            MenuToggleRow(title: "Open this menu instead", isOn: Binding(get: { overlayOpens }, set: { overlayOpens = $0; AchievementToastCenter.overlayOpensMenu = $0 }))
        }
    }

    private func takeRequestedSection() {
        guard let wanted = model.requestedSteamSection else { return }
        if let found = Section(rawValue: wanted) { section = found }
        model.requestedSteamSection = nil
    }
}

/// The Workshop inside the running game: what is on the device, and the game's community items to browse, search and subscribe to.
/// While a game runs the app's own connection to Steam is closed (Steam's client in the game is signed in as the same account), so this uses only what needs no
/// connection: Steam's web calls and plain file downloads. Items kept in the game's Workshop depot are queued and download after the game is closed.
struct WorkshopTab: View {
    @ObservedObject var model: GameMenuModel
    @ObservedObject private var workshop = SteamWorkshopStore.shared

    private enum Mode { case device, browse }

    @State private var mode = Mode.device
    @State private var sort = SteamWorkshopSort.trending
    @State private var search = ""
    @State private var searched = ""
    @State private var deviceItems: [SteamWorkshopItem] = []
    @State private var deviceLoaded = false
    @State private var browseItems: [SteamWorkshopItem] = []
    @State private var browseTotal = 0
    @State private var page = 0
    @State private var installed: [UInt64: SteamWorkshopFiles.Installed] = [:]
    @State private var loading = false
    @State private var note: String?
    /// The item whose removal was asked for once; a second tap confirms.
    @State private var armed: UInt64?
    @State private var showNotice = !WorkshopBeta.seen

    private var appID: Int { model.steamAppID ?? 0 }
    private var name: String { model.gameName ?? "this game" }
    private var knownIDs: Set<UInt64> { Set(installed.keys).union(deviceItems.map(\.id)) }

    var body: some View {
        HStack(spacing: 8) { Theme.label("Workshop"); BetaBadge(); Spacer() }
        if workshop.arrived > 0 || workshop.waitingCount > 0 {
            let waiting = workshop.waitingCount
            MenuCard(title: "Restart to apply", footer: waiting > 0 ? "\(waiting) item\(waiting == 1 ? "" : "s") can only download when the game is closed. Restarting closes the game, downloads them, and starts it again."
                     : "Many games only look for Workshop items when they start. Restarting closes the game and starts it again.") {
                MenuActionRow(title: "Restart game", symbol: "arrow.clockwise") { model.restartGame() }
            }
        }
        if showNotice { WorkshopBetaNotice(compact: true) { WorkshopBeta.seen = true; withAnimation { showNotice = false } } }
        MenuCard(title: "", footer: "Subscribing happens on your Steam account. Files are saved with the game's Steam files. A game that only looks for new items when it starts may need to be restarted to show them.") {
            MenuChoiceRow(title: "On this device", selected: mode == .device) { mode = .device }
            MenuDivider()
            MenuChoiceRow(title: "Browse and search", selected: mode == .browse) { mode = .browse }
        }
        if mode == .browse {
            MenuCard(title: "Find items") {
                MenuActionRow(title: "Order: \(sort.title)", symbol: "arrow.up.arrow.down") {
                    let all = SteamWorkshopSort.allCases
                    sort = all[((all.firstIndex(of: sort) ?? 0) + 1) % all.count]
                    Task { await startBrowse() }
                }
                MenuDivider()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                    TextField("Search items", text: $search).textFieldStyle(.plain).foregroundStyle(Theme.text).submitLabel(.search)
                        .onSubmit { Task { await startBrowse() } }
                }
                .padding(.horizontal, 12).frame(minHeight: 46)
            }
        }
        if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.warn) }
        list
            .task { await loadDevice() }
            .onChange(of: mode) { _, new in
                if new == .browse, browseItems.isEmpty { Task { await startBrowse() } }
            }
            .onChange(of: workshop.changes) { _, _ in Task { await loadDevice(force: true) } }
    }

    // MARK: Lists

    @ViewBuilder private var list: some View {
        let items = mode == .device ? deviceItems : browseItems
        if loading && items.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
        } else if items.isEmpty {
            Text(mode == .device ? "No Workshop items on this device for \(name) yet. Choose \u{201C}Browse and search\u{201D} to find some."
                 : (searched.isEmpty ? "No items found." : "Nothing found for \u{201C}\(searched)\u{201D}."))
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
        } else {
            MenuCard(title: mode == .device ? "Installed" : (searched.isEmpty ? sort.title : "Results")) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { MenuDivider() }
                    row(item)
                }
            }
            if mode == .browse, browseItems.count < browseTotal {
                MenuCard(title: "") {
                    MenuActionRow(title: loading ? "Loading\u{2026}" : "Show more", symbol: "ellipsis.circle", detail: "\(browseItems.count) of \(browseTotal)") { Task { await loadMore() } }
                }
            }
        }
    }

    private func row(_ item: SteamWorkshopItem) -> some View {
        let state = workshop.progress[SteamWorkshopStore.key(appID, item.id)]
        let present = installed[item.id] != nil
        return Button { tap(item, present: present, busy: state != nil) } label: {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: item.previewURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Theme.panelHigh.overlay { Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.textDim) } }
                }
                .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    if let line = stats(item) { Text(line).font(.system(size: 11)).foregroundStyle(Theme.textDim) }
                    statusLine(state: state, present: present, item: item)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("ws:\(item.id)", radius: 8, scale: 1.0) { tap(item, present: present, busy: state != nil) }
    }

    @ViewBuilder private func statusLine(state: SteamWorkshopStore.Progress?, present: Bool, item: SteamWorkshopItem) -> some View {
        switch state?.state {
        case .active?:
            ProgressView(value: state?.fraction ?? 0).tint(Theme.accent)
            Text("Downloading\u{2026}").font(.system(size: 11)).foregroundStyle(Theme.accent)
        case .queued?:
            Text("Waiting\u{2026}").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        case .waiting?:
            Text("Subscribed \u{00B7} downloads when the game closes").font(.system(size: 11)).foregroundStyle(Theme.accent)
        case .failed(let why)?:
            Text(why).font(.system(size: 11)).foregroundStyle(Theme.bad).multilineTextAlignment(.leading)
            Text("Tap to try again").font(.system(size: 11)).foregroundStyle(Theme.accent)
        case nil:
            if armed == item.id { Text("Tap again to remove").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.bad) }
            else if present { Text("On this device \u{00B7} tap to remove").font(.system(size: 11)).foregroundStyle(Theme.good) }
            else { Text("Tap to subscribe and download").font(.system(size: 11)).foregroundStyle(Theme.accent) }
        }
    }

    private func stats(_ item: SteamWorkshopItem) -> String? {
        var parts: [String] = []
        if let rating = item.rating { parts.append("\(Int((rating * 100).rounded()))% liked") }
        if item.subscriptions > 0 { parts.append("\(item.subscriptions.formatted(.number.notation(.compactName))) subscribers") }
        if item.fileSize > 0 { parts.append(SteamGameTile.size(item.fileSize)) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Actions

    private func tap(_ item: SteamWorkshopItem, present: Bool, busy: Bool) {
        note = nil
        if let state = workshop.progress[SteamWorkshopStore.key(appID, item.id)]?.state {
            if case .failed = state { workshop.retry(appID: appID, item: item.id, gameName: name, title: item.title) }
            return
        }
        if present {
            if armed == item.id {
                armed = nil
                Task {
                    do {
                        try await workshop.unsubscribe(id: item.id, appID: appID)
                        deviceItems.removeAll { $0.id == item.id }
                        installed[item.id] = nil
                    } catch { note = SteamSignIn.message(error) }
                }
            } else {
                armed = item.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if armed == item.id { armed = nil } }
            }
            return
        }
        Task {
            do { try await workshop.subscribe(item, gameName: name) } catch { note = SteamSignIn.message(error) }
        }
    }

    private func loadDevice(force: Bool = false) async {
        guard appID != 0, force || !deviceLoaded else { return }
        if !deviceLoaded { loading = true }
        defer { loading = false }
        installed = await workshop.installed(appID: appID)
        do { deviceItems = try await workshop.installedItems(appID: appID); deviceLoaded = true } catch { note = SteamSignIn.message(error) }
    }

    private func startBrowse() async {
        searched = search.trimmingCharacters(in: .whitespacesAndNewlines)
        browseItems = []; browseTotal = 0; page = 0
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, appID != 0 else { return }
        loading = true; note = nil
        defer { loading = false }
        do {
            let result = try await workshop.browse(appID: appID, sort: sort, search: searched, page: page + 1)
            page += 1; browseTotal = result.total
            let known = Set(browseItems.map(\.id))
            browseItems += result.items.filter { !known.contains($0.id) }
        } catch { note = SteamSignIn.message(error) }
    }
}
