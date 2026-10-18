// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// One download of any store, in the plain shape the shared Downloads page needs.
struct DownloadItem: Identifiable {
    enum Kind { case running, queued, stopped, ready, installing }
    let store: GameStore
    let key: String
    let title: String
    let art: URL?
    var kind: Kind
    var progress = SteamDownloadProgress()
    var failure: String?
    var sizeBytes: UInt64 = 0
    var id: String { store.rawValue + ":" + key }
}

/// Every store's downloads together, and what can be done to each. Each store still has its own queue (they run side by side); this is the one place they are shown.
@MainActor enum Downloads {
    static func items() -> [DownloadItem] {
        var out: [DownloadItem] = []

        let steam = SteamStore.shared
        for (id, d) in steam.downloads.sorted(by: { $0.key < $1.key }) {
            let game = steam.owned.first { $0.id == id }
            var item = DownloadItem(store: .steam, key: String(id), title: game?.name ?? "Steam game",
                                    art: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/header.jpg"), kind: .stopped, progress: d.progress, sizeBytes: game?.sizeBytes ?? 0)
            if id == steam.activeID { item.kind = .running }
            else if steam.queueOrder.contains(id) { item.kind = .queued }
            else if case .failed(let why) = d.state { item.failure = why }
            else if case .active = d.state { continue }
            out.append(item)
        }

        let epic = EpicInstaller.shared, epicLibrary = EpicLibrary.shared
        for (id, install) in epic.installs.sorted(by: { $0.key < $1.key }) where install.isDownload {
            let game = epicLibrary.games.first { $0.appName == id } ?? epic.game(for: id)
            var item = DownloadItem(store: .epic, key: id, title: game?.title ?? "Epic game", art: game?.heroURL ?? game?.artworkURL, kind: .stopped, progress: install.progress)
            if id == epic.activeID { item.kind = .running }
            else if epic.queueOrder.contains(id) { item.kind = .queued }
            else if case .failed(let why) = install.state { item.failure = why }
            out.append(item)
        }

        let gog = GogInstaller.shared
        for (id, install) in gog.installs.sorted(by: { $0.key < $1.key }) {
            guard let game = gog.game(for: id) else { continue }
            var item = DownloadItem(store: .gog, key: String(id), title: game.title, art: game.art, kind: .stopped, progress: install.progress)
            switch install.state {
            case .active: item.kind = .running
            case .queued: item.kind = .queued
            case .paused: break
            case .failed(let why): item.failure = why
            case .ready: item.kind = .ready
            case .running: item.kind = .installing
            case .installed: continue
            }
            if id == gog.activeID { item.kind = .running }
            out.append(item)
        }

        let itch = ItchInstaller.shared
        for (id, install) in itch.installs.sorted(by: { $0.key < $1.key }) {
            guard let game = itch.game(for: id) else { continue }
            var item = DownloadItem(store: .itch, key: String(id), title: game.title, art: game.cover, kind: .stopped, progress: install.progress)
            switch install.state {
            case .active: item.kind = .running
            case .queued: item.kind = .queued
            case .paused: break
            case .failed(let why): item.failure = why
            case .ready: item.kind = .ready
            case .running: item.kind = .installing
            case .installed: continue
            }
            if id == itch.activeID { item.kind = .running }
            out.append(item)
        }

        let amazon = AmazonInstaller.shared
        for (id, install) in amazon.installs.sorted(by: { $0.key < $1.key }) {
            guard let game = amazon.game(for: id) else { continue }
            var item = DownloadItem(store: .amazon, key: id, title: game.title, art: game.art, kind: .stopped, progress: install.progress)
            switch install.state {
            case .active: item.kind = .running
            case .queued: item.kind = .queued
            case .paused: break
            case .failed(let why): item.failure = why
            case .installed: continue
            }
            if id == amazon.activeID { item.kind = .running }
            out.append(item)
        }

        // The waiting ones keep the order of their own store's queue.
        func position(_ item: DownloadItem) -> Int {
            switch item.store {
            case .steam: steam.queueOrder.firstIndex(of: Int(item.key) ?? -1) ?? 0
            case .epic: epic.queueOrder.firstIndex(of: item.key) ?? 0
            case .gog: gog.queueOrder.firstIndex(of: Int(item.key) ?? -1) ?? 0
            case .itch: itch.queueOrder.firstIndex(of: Int(item.key) ?? -1) ?? 0
            case .amazon: amazon.queueOrder.firstIndex(of: item.key) ?? 0
            }
        }
        let storeOrder = Dictionary(uniqueKeysWithValues: GameStore.allCases.enumerated().map { ($1, $0) })
        return out.sorted { a, b in
            if a.kind == .queued, b.kind == .queued, a.store == b.store { return position(a) < position(b) }
            if a.store != b.store { return storeOrder[a.store]! < storeOrder[b.store]! }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    // MARK: Actions

    static func pause(_ i: DownloadItem) {
        switch i.store {
        case .steam: SteamStore.shared.pause(Int(i.key) ?? 0)
        case .epic: EpicInstaller.shared.pause(i.key)
        case .gog: GogInstaller.shared.pause(Int(i.key) ?? 0)
        case .itch: ItchInstaller.shared.pause(Int(i.key) ?? 0)
        case .amazon: AmazonInstaller.shared.pause(i.key)
        }
    }
    static func cancel(_ i: DownloadItem) {
        switch i.store {
        case .steam: SteamStore.shared.cancel(Int(i.key) ?? 0)
        case .epic: EpicInstaller.shared.cancel(i.key)
        case .gog: GogInstaller.shared.cancel(Int(i.key) ?? 0)
        case .itch: ItchInstaller.shared.cancel(Int(i.key) ?? 0)
        case .amazon: AmazonInstaller.shared.cancel(i.key)
        }
    }
    static func startNow(_ i: DownloadItem) {
        switch i.store {
        case .steam: SteamStore.shared.startNow(Int(i.key) ?? 0)
        case .epic: EpicInstaller.shared.startNow(i.key)
        case .gog: GogInstaller.shared.startNow(Int(i.key) ?? 0)
        case .itch: ItchInstaller.shared.startNow(Int(i.key) ?? 0)
        case .amazon: AmazonInstaller.shared.startNow(i.key)
        }
    }
    static func resume(_ i: DownloadItem) {
        switch i.store {
        case .steam: SteamStore.shared.install(Int(i.key) ?? 0)
        case .epic: if let game = EpicLibrary.shared.games.first(where: { $0.appName == i.key }) ?? EpicInstaller.shared.game(for: i.key) { EpicInstaller.shared.install(game) }
        case .gog: GogInstaller.shared.resume(Int(i.key) ?? 0)
        case .itch: ItchInstaller.shared.resume(Int(i.key) ?? 0)
        case .amazon: AmazonInstaller.shared.resume(i.key)
        }
    }
    /// A downloaded setup program waiting to be run (GOG and itch.io).
    static func runSetup(_ i: DownloadItem) {
        switch i.store {
        case .gog: GogInstaller.shared.runInstaller(Int(i.key) ?? 0)
        case .itch: ItchInstaller.shared.runInstaller(Int(i.key) ?? 0)
        default: break
        }
    }
    static func pauseAll() { SteamStore.shared.pauseAll(); EpicInstaller.shared.pauseAll(); GogInstaller.shared.pauseAll(); ItchInstaller.shared.pauseAll(); AmazonInstaller.shared.pauseAll() }
    static func resumeAll() { SteamStore.shared.resumeAll(); EpicInstaller.shared.resumeAll(); GogInstaller.shared.resumeAll(); ItchInstaller.shared.resumeAll(); AmazonInstaller.shared.resumeAll() }

    // MARK: One line for buttons and cards

    /// "Downloads", "Downloads · 2", or the percentage and speed while something is coming down: the same text on every store's page.
    static func title(of items: [DownloadItem]) -> String {
        let live = items.filter { [.running, .queued, .stopped].contains($0.kind) }
        let running = items.filter { $0.kind == .running }
        let waiting = items.filter { $0.kind == .queued }.count
        if running.isEmpty { return live.isEmpty ? "Downloads" : "Downloads \u{00B7} \(live.count)" }
        let rate = running.reduce(0) { $0 + $1.progress.bytesPerSecond }
        let head = running.count == 1 ? "\(Int(running[0].progress.fraction * 100))%" : "\(running.count) downloading"
        return head + (rate > 0 ? " \u{00B7} \(EpicText.size(UInt64(rate)))/s" : "") + (waiting > 0 ? " \u{00B7} +\(waiting)" : "")
    }

    static func summary(of items: [DownloadItem]) -> String {
        let running = items.filter { $0.kind == .running }.count, waiting = items.filter { $0.kind == .queued }.count
        let stopped = items.filter { $0.kind == .stopped }.count, ready = items.filter { $0.kind == .ready }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) downloading") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if stopped > 0 { parts.append("\(stopped) paused") }
        if ready > 0 { parts.append("\(ready) ready to install") }
        return parts.isEmpty ? "Nothing is downloading" : parts.joined(separator: " \u{00B7} ")
    }
}

/// The round Downloads button at the bottom right of the Stores tab. It floats over every store's library and over the games' pages, so it is always there and does not move
/// when switching stores or scrolling. A ring shows the progress of what is coming down, and a number how many downloads there are.
struct DownloadsButton: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epic = EpicInstaller.shared
    @ObservedObject private var gog = GogInstaller.shared
    @ObservedObject private var itch = ItchInstaller.shared
    @ObservedObject private var amazon = AmazonInstaller.shared

    var body: some View {
        let items = Downloads.items()
        let running = items.filter { $0.kind == .running }
        let count = items.filter { [.running, .queued, .stopped, .ready].contains($0.kind) }.count
        let fraction = running.isEmpty ? 0 : running.map(\.progress.fraction).reduce(0, +) / Double(running.count)
        let open = { router.openDownloads() }
        return Button(action: open) {
            ZStack {
                // Solid, never see-through: a solid base under the tint, so it reads on a light page as well as a dark one.
                Circle().fill(Theme.backgroundTop)
                Circle().fill(running.isEmpty ? Theme.panelHigh : Theme.accent.opacity(0.28))
                Circle().strokeBorder(running.isEmpty ? Theme.text.opacity(0.45) : Theme.accent, lineWidth: 2)
                if !running.isEmpty {
                    Circle().trim(from: 0, to: max(0.03, fraction)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(5)
                }
                Image(systemName: "arrow.down").font(.system(size: 22, weight: .bold)).foregroundStyle(running.isEmpty ? Theme.text : Theme.accent)
            }
            .frame(width: 58, height: 58)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20).background(Theme.accent, in: Capsule()).offset(x: 4, y: -4)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusTarget("stores-downloads", radius: 29, scale: 1.1, action: open)
        .accessibilityLabel(Downloads.title(of: items))
    }
}

/// Everything any store is downloading, on one page: what is coming down now with its speed and time left, then the games waiting, then the ones stopped or failed,
/// each marked with its store.
struct AllDownloadsScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epic = EpicInstaller.shared
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @ObservedObject private var gog = GogInstaller.shared
    @ObservedObject private var itch = ItchInstaller.shared
    @ObservedObject private var amazon = AmazonInstaller.shared

    private func back() { router.closeDownloads() }
    private var backTitle: String {
        if case .store(let store)? = router.downloadsReturn { return store.title }
        return router.downloadsReturn == .all ? "All games" : "Stores"
    }

    var body: some View {
        let items = Downloads.items()
        let running = items.filter { $0.kind == .running }
        let waiting = items.filter { $0.kind == .queued }
        let stopped = items.filter { $0.kind == .stopped }
        let ready = items.filter { $0.kind == .ready || $0.kind == .installing }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                PillButton(id: "dl-back", title: backTitle, symbol: "chevron.left", action: back)
                Spacer()
                HStack(spacing: 10) {
                    if !running.isEmpty || !waiting.isEmpty { PillButton(id: "dl-pause-all", title: "Pause all", symbol: "pause.fill") { Downloads.pauseAll() } }
                    if !stopped.isEmpty { PillButton(id: "dl-resume-all", title: "Resume all", symbol: "play.fill", style: .primary) { Downloads.resumeAll() } }
                }
            }
            .padding(.horizontal, 24).padding(.top, 8)
            FocusScroll {
                PageScaffold(title: "Downloads", symbol: "arrow.down.circle.fill") {
                    if !items.isEmpty { Text(Downloads.summary(of: items)).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim) }
                    ForEach(running) { nowCard($0) }
                    if !waiting.isEmpty {
                        SettingsGroup(title: "Up next") { ForEach(waiting) { queueRow($0) } }
                    }
                    if !stopped.isEmpty {
                        SettingsGroup(title: "Paused") { ForEach(stopped) { pausedRow($0) } }
                    }
                    if !ready.isEmpty {
                        SettingsGroup(title: "Ready to install") { ForEach(ready) { readyRow($0) } }
                    }
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(Theme.accentGradient)
                            Text("Nothing is downloading").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                            PillButton(id: "dl-browse", title: "Browse your games", symbol: "square.grid.2x2.fill", action: back)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
        }
        .onNavBack { back(); return true }
    }

    // MARK: Pieces

    private func art(_ item: DownloadItem, width: CGFloat) -> some View {
        Color.clear.frame(width: width, height: width * 215 / 460)
            .overlay { EpicArtView(url: item.art) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) { StoreBadgeBacked(store: item.store, size: 22).padding(4) }
    }

    private func nowCard(_ item: DownloadItem) -> some View {
        let p = item.progress
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                art(item, width: 120).id(item.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2)
                    Text(phaseText(p)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                Text("\(Int(p.fraction * 100))%").font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(Theme.accent)
            }
            ProgressView(value: p.fraction).tint(Theme.accent).shadow(color: Theme.accent.opacity(0.5 * Theme.glowStrength), radius: 6)
            HStack(spacing: 10) {
                PillButton(id: "dl-now-pause-\(item.id)", title: "Pause", symbol: "pause.fill", style: .primary) { Downloads.pause(item) }
                PillButton(id: "dl-now-cancel-\(item.id)", title: "Cancel", symbol: "xmark", style: .danger) { Downloads.cancel(item) }
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5))
    }

    private func row<Buttons: View>(_ item: DownloadItem, line: String, lineColor: Color = Theme.textDim, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                art(item, width: sizeClass == .compact ? 84 : 110)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2)
                    Text("\(item.store.title) \u{00B7} \(line)").font(.caption).foregroundStyle(lineColor).lineLimit(3)
                }
                .contentShape(Rectangle())
                .onTapGesture { router.openStore(item.store) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) { buttons() }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func queueRow(_ item: DownloadItem) -> some View {
        row(item, line: item.sizeBytes > 0 ? "Waiting \u{00B7} \(EpicText.size(item.sizeBytes))" : "Waiting") {
            PillButton(id: "dl-start-\(item.id)", title: "Download now", symbol: "forward.end.fill") { Downloads.startNow(item) }
            PillButton(id: "dl-cancel-\(item.id)", title: "Remove", symbol: "xmark", style: .danger) { Downloads.cancel(item) }
        }
    }

    private func pausedRow(_ item: DownloadItem) -> some View {
        let failed = item.failure != nil
        let line = item.failure ?? (item.progress.totalBytes > 0 ? "Paused at \(Int(item.progress.fraction * 100))%" : "Paused")
        return row(item, line: line, lineColor: failed ? Theme.bad : Theme.textDim) {
            PillButton(id: "dl-resume-\(item.id)", title: failed ? "Try again" : "Resume", symbol: failed ? "arrow.clockwise" : "play.fill", style: .primary) { Downloads.resume(item) }
            PillButton(id: "dl-cancel-\(item.id)", title: "Cancel", symbol: "xmark", style: .danger) { Downloads.cancel(item) }
        }
    }

    private func readyRow(_ item: DownloadItem) -> some View {
        row(item, line: item.kind == .installing ? "Installing\u{2026}" : "Downloaded. Run its setup to finish.") {
            if item.kind == .ready { PillButton(id: "dl-setup-\(item.id)", title: "Install", symbol: "play.fill", style: .primary) { Downloads.runSetup(item) } }
            PillButton(id: "dl-cancel-\(item.id)", title: "Remove", symbol: "xmark", style: .danger) { Downloads.cancel(item) }
        }
    }

    private func phaseText(_ p: SteamDownloadProgress) -> String {
        var text = EpicText.progress(p)
        if p.phase == .downloading, let s = p.secondsLeft { text += " \u{00B7} \(EpicText.duration(s)) left" }
        return text
    }
}
