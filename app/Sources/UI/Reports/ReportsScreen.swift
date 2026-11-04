// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The Reports tab. It opens on the player's own games and how they run on this version of the engine; All games lists every game people have reported; My reports lists what
// the player sent. A game opens its own page (CompatGameView). The drawing is in ReportsParts.swift and ReportsLayouts.swift.

struct ReportsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(AppRouter.self) private var router
    @Environment(\.focusScope) private var scope
    @ObservedObject private var compat = CompatStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    @State private var section = ReportsScope.mine
    @State private var filter = ReportsFilter.all
    @State private var order = ReportsOrder.popular
    @State private var query = ""
    @State private var remote: [CompatGameSummary] = []
    @State private var loading = false
    @State private var loadedAll = false
    @State private var truncated = false
    @State private var error: String?
    @State private var cachedOn: Date?
    @State private var open: ReportsItem?
    private let device = CompatDeviceInfo.current

    /// Filtering by verdict or ordering by date needs the whole list: the server pages and sorts only by report count and name.
    private var bulk: Bool { filter != .all || order == .recent }

    var body: some View {
        Group {
            if let open {
                VStack(alignment: .leading, spacing: 0) {
                    PillButton(id: "rs-back", title: "Reports", symbol: "chevron.left") { self.open = nil }.padding(.horizontal, 24).padding(.top, 8)
                    CompatGameView(gameID: open.gameID, fallbackTitle: open.title, libraryGame: open.libraryID.flatMap { id in model.games.first { $0.id == id } })
                }
            } else { screen }
        }
        .onNavBack { if open != nil { open = nil; return true }; return false }
        .onAppear {
            if let asked = router.reportsScope { section = asked; router.reportsScope = nil }
            else if model.games.isEmpty { section = .all }
            startFocus(force: true)
        }
        .onChange(of: router.reportsScope) { _, asked in if let asked { section = asked; router.reportsScope = nil; open = nil } }
        .onChange(of: open?.id) { _, id in if id == nil { startFocus(force: true) } }
        .onChange(of: section) { _, _ in startFocus(force: true) }
    }

    private func startFocus(force: Bool) { scope?.start(at: "seg-\(section.rawValue)", force: force) }

    // MARK: The lists

    private var mineItems: [ReportsItem] {
        model.games.filter { $0.installer != true }.map { game in
            let badge = compat.badges[game.id] ?? CompatBadge(overall: nil, forDevice: nil, verdict: nil, earlier: nil)
            let count = (badge.overall?.reports ?? 0) + (badge.earlier?.reports ?? 0)
            return ReportsItem(id: game.id.uuidString, gameID: compat.candidateIDs(for: game).first ?? "none", title: game.name, reportCount: count, lastReport: nil, badge: badge, libraryID: game.id)
        }
    }

    private var remoteItems: [ReportsItem] {
        remote.map { summary in
            let mine = model.games.first { compat.candidateIDs(for: $0).contains(summary.id) }
            return ReportsItem(id: summary.id, gameID: summary.id, title: summary.title ?? "Untitled game", reportCount: summary.reportCount, lastReport: summary.lastReport, badge: summary.badge, libraryID: mine?.id)
        }
    }

    private func subtitle(_ item: ReportsItem) -> String {
        let earlier = item.badge.earlier?.reports ?? 0
        if item.needsReport {
            if earlier > 0 { return "\(earlier) earlier report\(earlier == 1 ? "" : "s"). None on this version yet: report how it runs now." }
            return "Not tested on this version yet. Be the first to report."
        }
        if item.reportCount == 0 { return "No reports yet" }
        var text = "\(item.reportCount) report\(item.reportCount == 1 ? "" : "s")"
        if let last = item.lastReport { text += " \u{00B7} latest \(CompatDeviceInfo.date(last))" }
        return text
    }

    private var screen: some View {
        FocusScroll {
            PageScaffold(title: "Reports", symbol: "checkmark.seal.fill") {
                SegmentedPills(options: ReportsScope.allCases.map { .init(id: $0.rawValue, title: $0.title) }, selection: section.rawValue) { section = ReportsScope(rawValue: $0) ?? .mine }
                switch section {
                case .mine: listLayout(items: mineItems, ownGames: true)
                case .all: listLayout(items: remoteItems, ownGames: false)
                case .sent: MyReportsView()
                }
            }
            .frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .task(id: "\(section.rawValue)|\(bulk ? "bulk" : "page")|\(order.rawValue)|\(bulk ? "" : query)") {
            guard section == .all else { return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    @ViewBuilder private func listLayout(items: [ReportsItem], ownGames: Bool) -> some View {
        let summary = ReportsLogic.summary(items)
        // In the paged list the server has already searched and ordered; only the verdict filter and the bulk search are done here.
        let shown = (ownGames || bulk) ? ReportsLogic.visible(items, filter: filter, order: order, query: query) : items
        ReportsListLayout(filter: $filter, order: $order, query: $query,
                          headline: headline(summary, ownGames: ownGames), detail: detail(summary, ownGames: ownGames),
                          summary: summary, items: shown, subtitle: subtitle, open: { open = $0 },
                          more: { item in if !ownGames, !bulk, item.id == shown.last?.id { Task { await loadMore() } } }) {
            listFooter(ownGames: ownGames, shown: shown, total: items.count)
        }
    }

    private func headline(_ s: ReportsLogic.Summary, ownGames: Bool) -> String {
        if s.total == 0 { return ownGames ? "No games yet" : "No reports yet" }
        if ownGames { return "\(s.great) of \(s.total) of your games work great" }
        return loadedAll || bulk ? "\(s.great) of \(s.total) reported games work great" : "\(s.great) of the first \(s.total) work great"
    }

    private func detail(_ s: ReportsLogic.Summary, ownGames: Bool) -> String {
        if s.total == 0 { return ownGames ? "Add a game to see how it runs." : "Nobody has sent a report yet." }
        if ownGames {
            var text = "\(s.tested) tested on this version of the engine \u{00B7} \(s.untested) not yet tested."
            if s.untested > 0 { text += " Open one to report how it runs." }
            return text
        }
        return "\(s.tested) with a verdict on this version \u{00B7} \(s.untested) not yet tested on it."
    }

    @ViewBuilder private func listFooter(ownGames: Bool, shown: [ReportsItem], total: Int) -> some View {
        if let cachedOn, !ownGames {
            Label("Showing the list saved on \(cachedOn.formatted(date: .abbreviated, time: .omitted)). A connection is needed to refresh it.", systemImage: "wifi.slash")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        }
        if !ownGames {
            if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding() }
            if truncated { Text("Showing the first \(total) games. Search to narrow the list.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            if let error, cachedOn == nil {
                SettingsGroup {
                    if network.isOnline { Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                    else { OfflineChip(detail: "this list needs a connection").padding(.horizontal, 6) }
                    Text("The reports are stored on a home server, so they can be unavailable while it is off.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                    ActionRow(id: "rs-retry", symbol: "arrow.clockwise", title: "Try again", chevron: false) { Task { await reload() } }
                }
            }
        }
        if shown.isEmpty && !loading && error == nil {
            Text(emptyText(ownGames: ownGames)).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        }
    }

    private func emptyText(ownGames: Bool) -> String {
        if !query.isEmpty { return "No game matches \u{201C}\(query)\u{201D}." }
        if filter != .all { return "No game is marked \u{201C}\(filter.title)\u{201D}." }
        return ownGames ? "Add a game to the library and it appears here." : "No reports have been sent yet."
    }

    // MARK: Loading (All games)

    private func reload() async {
        loading = true; error = nil; loadedAll = false; truncated = false
        let client = CompatClient.standard()
        do {
            if bulk {
                var all: [CompatGameSummary] = []
                while all.count < 600 {
                    let page = try await client.games(query: "", sort: "reports", limit: 100, offset: all.count, device: device?.id)
                    all += page
                    if page.count < 100 { loadedAll = true; break }
                }
                truncated = !loadedAll
                loadedAll = true
                remote = all
            } else {
                remote = try await client.games(query: query.trimmingCharacters(in: .whitespaces), sort: order == .name ? "name" : "reports", limit: 30, offset: 0, device: device?.id)
                loadedAll = remote.count < 30
            }
            cachedOn = nil
            if query.isEmpty { CompatListCache.save(remote) }
        } catch {
            self.error = error.localizedDescription
            if let saved = CompatListCache.load() { remote = saved.games; cachedOn = saved.date; loadedAll = true } else { remote = [] }
        }
        loading = false
    }

    private func loadMore() async {
        guard !loading, !loadedAll, !bulk else { return }
        loading = true
        do {
            let more = try await CompatClient.standard().games(query: query.trimmingCharacters(in: .whitespaces), sort: order == .name ? "name" : "reports", limit: 30, offset: remote.count, device: device?.id)
            remote += more
            loadedAll = more.count < 30
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: - My reports

/// What the player sent, with a way to delete a report from the server. (It used to be in Settings.)
struct MyReportsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var compat = CompatStore.shared
    @State private var mine: [CompatMyReport] = []
    @State private var loading = false
    @State private var error: String?
    @State private var deleting: CompatMyReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: mine.isEmpty ? nil : "\(mine.count) report\(mine.count == 1 ? "" : "s") sent",
                          note: "Press a report to delete it from the server. Reports carry a random key kept on this device, not your name, and the game's log, which only the developer can read.") {
                if compat.queuedCount > 0 {
                    Label("\(compat.queuedCount) report\(compat.queuedCount == 1 ? "" : "s") waiting to be sent.", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding() }
                ForEach(mine) { r in
                    ActionRow(id: "rp-\(r.id)", symbol: r.rating.symbol, tint: r.rating.color, title: r.gameTitle,
                              subtitle: "\(r.device) \u{00B7} \(CompatDeviceInfo.date(r.date))\(r.hidden ? " \u{00B7} hidden" : "")\(Self.statusText(r.status))" + (r.comment.map { $0.isEmpty ? "" : "\n\u{201C}\($0)\u{201D}" } ?? ""),
                              detail: r.rating.title, chevron: false) { deleting = r }
                }
                if mine.isEmpty && !loading && error == nil { Text("You haven't sent any reports. Open one of your games and tell people how it ran.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
            }
        }
        .task { await load() }
        .confirm("Delete this report?", message: deleting.map { "\($0.gameTitle) \u{2014} \($0.rating.title)" }, confirmTitle: "Delete", destructive: true,
                 isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let r = deleting { Task { await delete(r) } }
        }
    }

    /// Where the report stands: every report waits for the developer's approval before it appears in Reports.
    private static func statusText(_ status: String?) -> String {
        switch status { case "pending"?: " \u{00B7} waiting for review"; case "rejected"?: " \u{00B7} not accepted"; default: "" }
    }

    private func load() async {
        loading = true; error = nil
        do { mine = try await CompatClient.standard().mine() } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func delete(_ r: CompatMyReport) async {
        do { try await CompatClient.standard().delete(reportID: r.id); mine.removeAll { $0.id == r.id }; await compat.refreshBadges(for: model.games) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - One game

/// Everything the server knows about one game: the verdict, how the reports divide, what people mention, how it does on each device, and the reports themselves.
struct CompatGameView: View {
    let gameID: String
    var fallbackTitle: String?
    var libraryGame: Game?
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var compat = CompatStore.shared
    @State private var detail: CompatGameDetail?
    @State private var reports: [CompatPublicReport] = []
    @State private var loading = true
    @State private var loadedAll = false
    @State private var missing = false
    @State private var error: String?
    @State private var verdictFilter: CompatVerdict?
    @State private var myDeviceOnly = false
    @State private var showDetail = false
    @State private var showEarlier = false
    @State private var writing: Game?
    @State private var reading: CompatPublicReport?
    private let device = CompatDeviceInfo.current
    /// The first load takes this many reports (three pages), enough for the bar and the tags to mean something.
    private let firstLoad = 150

    var body: some View {
        FocusScroll {
            PageScaffold(title: detail?.title ?? fallbackTitle ?? "Game", symbol: "checkmark.seal.fill") {
                GameReportsLayout(data: data, writeTitle: writeTitle, writeSubtitle: writeSubtitle, writeProminent: writeProminent, write: { writing = libraryGame },
                                  verdictFilter: $verdictFilter, myDeviceOnly: $myDeviceOnly, hasDevice: device != nil, showDetail: $showDetail, showEarlier: $showEarlier,
                                  loading: loading, openReport: { id in reading = reports.first { $0.id == id } }, more: { Task { await loadMore() } })
                if let error {
                    SettingsGroup {
                        if NetworkStatus.shared.isOnline { Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                        else { OfflineChip(detail: "this page needs a connection").padding(.horizontal, 6) }
                        ActionRow(id: "cg-retry", symbol: "arrow.clockwise", title: "Try again", chevron: false) { Task { await reload() } }
                    }
                }
            }
            .frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .task(id: gameID) { await reload() }
        .sheet(item: $writing, onDismiss: { Task { await reload() } }) { ReportSheet(game: $0).environmentObject(model).preferredColorScheme(Theme.scheme) }
        .sheet(item: $reading) { report in
            ReportDetailSheet(report: report, flag: { await flag(report) }, done: { reading = nil })
        }
    }

    // MARK: The button

    private var badge: CompatBadge? { detail?.badge ?? libraryGame.flatMap { compat.badges[$0.id] } }
    private var reported: Bool { libraryGame.map { compat.hasReported($0) } ?? false }

    private var writeTitle: String? {
        guard libraryGame != nil else { return nil }
        if reported { return "Update my report" }
        if badge?.verdict == nil { return (badge?.earlier?.reports ?? 0) > 0 ? "Report how it runs on this version" : "Be the first to report" }
        return "Write a report"
    }
    private var writeSubtitle: String? {
        guard libraryGame != nil else { return nil }
        if reported { return "You reported on this version." }
        return badge?.verdict == nil ? "Nobody has told us how it runs on this version yet. It takes under a minute." : "Add how it ran for you."
    }
    private var writeProminent: Bool { libraryGame != nil && !reported && badge?.verdict == nil }

    // MARK: The data

    private var data: GameReportsData {
        var d = GameReportsData()
        let b = detail?.badge
        if let overall = b?.overall {
            d.heroSymbol = overall.verdict.symbol; d.heroTint = overall.verdict.color; d.heroTitle = overall.verdict.title
            d.heroDetail = "From \(overall.reports) report\(overall.reports == 1 ? "" : "s") on this version of the engine" + (overall.confidence == "low" ? " \u{00B7} not many yet" : "")
        } else if let past = b?.past, let earlier = b?.earlier?.reports {
            d.heroSymbol = past.symbol; d.heroTint = past.color; d.heroTitle = past.text
            d.heroDetail = "\(earlier) earlier report\(earlier == 1 ? "" : "s"), none on this version"
            d.note = past.explanation
        } else if let earlier = b?.earlier?.reports, earlier > 0 {
            d.heroTitle = "Not yet tested"; d.heroDetail = "The engine changed since the \(earlier) earlier report\(earlier == 1 ? "" : "s")"
            d.note = "How this game runs may be different now. The earlier reports are kept for reference below."
        } else {
            d.heroTitle = "Not yet tested"; d.heroDetail = "No reports yet"
            if libraryGame != nil { d.note = "Play it for a few minutes and send the first report." }
        }
        let samples = reports.map { ReportsLogic.Sample(rating: $0.rating, tags: $0.tags.map(\.rawValue), onThisEngine: $0.onThisEngine != false, deviceID: $0.deviceId) }
        let breakdown = ReportsLogic.breakdown(samples, topTags: 6)
        if breakdown.total > 0 {
            d.breakdown = breakdown
            if !loadedAll { d.heroDetail += " \u{00B7} the bar counts the newest \(reports.count)" }
        }
        d.tags = breakdown.tags.map { (title: CompatTag(rawValue: $0.tag)?.title ?? $0.tag, count: $0.count) }
        if let mine = b?.forDevice, let device { d.yourDevice = (device.name, mine.verdict) }
        if let summary = detail?.settingsSummary {
            d.factsTitle = "When it works great, people use"
            d.facts = summary.items.filter { ["launch", "power", "desktopDisplay", "swapMB", "vramMB", "preciseMath"].contains($0.key) }.prefix(5).map {
                .init(id: $0.key, title: CompatSettings.describe($0.key, $0.value), value: "\($0.count) of \(summary.reports)")
            }
        }
        d.devices = (detail?.devices ?? []).map { .init(id: $0.deviceId, name: $0.device, verdict: $0.verdict, reports: $0.reports, yours: $0.deviceId == device?.id) }
        d.lines = reports.filter { !myDeviceOnly || $0.deviceId == device?.id }.map(line)
        d.canLoadMore = !loadedAll
        return d
    }

    private func line(_ r: CompatPublicReport) -> GameReportsData.Line {
        var lines = [showDetail ? "iOS \(r.ios) \u{00B7} app \(r.appVersion) \u{00B7} \(r.stability.title) \u{00B7} files from \(r.source.title.components(separatedBy: " (").first ?? r.source.title)" : r.stability.title]
        if r.onThisEngine == false { lines.append("Earlier engine (\(CompatEngine.describe(r.engine))): not counted") }
        if let p = r.perf, p.fpsAvg != nil || p.minutes != nil {
            lines.append([p.fpsAvg.map { String(format: "%.0f fps avg", $0) }, p.fpsLow.map { String(format: "%.0f low", $0) }, p.minutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " \u{00B7} "))
        }
        if showDetail, let s = r.settings { lines.append(s.summary) }
        if showDetail, !r.tags.isEmpty { lines.append(r.tags.map(\.title).joined(separator: " \u{00B7} ")) }
        if let c = r.comment, !c.isEmpty { lines.append("\u{201C}\(c)\u{201D}") }
        return .init(id: r.id, rating: r.rating, title: "\(r.device) \u{00B7} \(CompatDeviceInfo.date(r.date))", subtitle: lines.joined(separator: "\n"), earlier: r.onThisEngine == false)
    }

    // MARK: Loading

    private func reload() async {
        loading = true; error = nil; loadedAll = false; missing = false
        reports = []
        let client = CompatClient.standard()
        do {
            detail = try await client.game(id: gameID, device: device?.id)
            while reports.count < firstLoad {
                let page = try await client.reports(gameID: gameID, device: nil, limit: 50, offset: reports.count)
                reports += page
                if page.count < 50 { loadedAll = true; break }
            }
        } catch let CompatError.server(404, _) { missing = true; detail = nil; loadedAll = true }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func loadMore() async {
        loading = true
        do {
            let more = try await CompatClient.standard().reports(gameID: gameID, device: nil, limit: 50, offset: reports.count)
            reports += more
            loadedAll = more.count < 50
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Flags a report; returns what to tell the person.
    private func flag(_ r: CompatPublicReport) async -> String {
        do { try await CompatClient.standard().flag(reportID: r.id); return "Thanks. If other people flag it too, it's hidden until it has been looked at." }
        catch { return error.localizedDescription }
    }
}

// MARK: - A report opened in full

extension ReportDetailData {
    /// Every field a public report carries, in words.
    init(_ r: CompatPublicReport) {
        self.init()
        rating = r.rating
        device = r.device
        date = CompatDeviceInfo.date(r.date)
        if r.onThisEngine == false { earlierNote = "Sent from \(CompatEngine.describe(r.engine)), an earlier version of the game engine. It is kept for reference and does not count toward the verdict." }
        tags = r.tags.map(\.title)
        comment = r.comment

        var happened: [Row] = [.init(id: "crash", label: "Crashes", value: r.stability.title)]
        if let p = r.perf {
            if let fps = p.fpsAvg { happened.append(.init(id: "fps", label: "Average frame rate", value: String(format: "%.0f fps", fps))) }
            if let low = p.fpsLow { happened.append(.init(id: "low", label: "Lowest frame rate", value: String(format: "%.0f fps", low))) }
            if let minutes = p.minutes { happened.append(.init(id: "min", label: "Played for", value: "\(minutes) min")) }
            if let thermal = p.thermal, !thermal.isEmpty { happened.append(.init(id: "heat", label: "Device heat", value: thermal.prefix(1).uppercased() + thermal.dropFirst())) }
        }
        groups.append(.init(id: "ran", title: "How it ran", note: p(r) ? nil : "This report has no measurements: the person chose not to include them, or the game ended before there were any.", rows: happened))

        groups.append(.init(id: "on", title: "What it ran on", note: nil, rows: [
            .init(id: "device", label: "Device", value: r.device),
            .init(id: "ios", label: "iOS", value: r.ios),
            .init(id: "app", label: "Porthole", value: r.appVersion),
            .init(id: "engine", label: "Game engine", value: CompatEngine.describe(r.engine) + (r.onThisEngine == true ? " (this version)" : "")),
            .init(id: "files", label: "Game files from", value: r.source.title),
        ]))

        if let s = r.settings {
            let power = s.power == "performance" ? "Performance" : (s.power == "saver" ? "Battery saver" : "Balanced")
            let coverage: [String: String] = ["": "Large blocks (8 MB and up)", "blocks": "All blocks of 1 MB and up", "wide": "1 MB and up, and overflow", "broad": "Broad"]
            var rows: [Row] = [
                .init(id: "launch", label: "Started", value: s.launch == "steam" ? "Through Steam" : "Run directly, not through Steam"),
                .init(id: "power", label: "Power mode", value: power),
                .init(id: "hot", label: "Keeps its mode when hot", value: s.keepModeWhenHot ? "Yes" : "No, drops to battery saver"),
                .init(id: "swap", label: "Swap", value: s.swapMB == 0 ? "Off" : "\(s.swapMB) MB"),
            ]
            if s.swapMB > 0 { rows.append(.init(id: "cover", label: "Swap covers", value: coverage[s.swapCoverage] ?? s.swapCoverage)) }
            rows += [
                .init(id: "vram", label: "Video memory", value: s.vramMB == 0 ? "Automatic" : "\(s.vramMB) MB"),
                .init(id: "audio", label: "Audio buffer", value: "\(s.audioCushionMs) ms"),
                .init(id: "math", label: "Precise shader math", value: s.preciseMath ? "On" : "Off"),
                .init(id: "desk", label: "Wine desktop display", value: s.desktopDisplay ? "On" : "Off"),
                .init(id: "controls", label: "Controls", value: s.controls == "firstPerson" ? "First person" : "Standard"),
            ]
            groups.append(.init(id: "set", title: "Settings used", note: "What the person had set for this game when they reported.", rows: rows))
        } else {
            groups.append(.init(id: "set", title: "Settings used", note: "This person did not share their settings.", rows: []))
        }
    }

    private func p(_ r: CompatPublicReport) -> Bool { r.perf != nil && (r.perf?.fpsAvg != nil || r.perf?.minutes != nil) }
}

/// A report opened in a sheet: all it says, and a way to flag it.
struct ReportDetailSheet: View {
    let report: CompatPublicReport
    /// Flags it on the server; returns what to tell the person.
    let flag: () async -> String
    let done: () -> Void
    @State private var scope = FocusScope()
    @State private var confirmFlag = false
    @State private var flagged: String?

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Report").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "rd-close", title: "Close", symbol: "xmark", action: done)
                }
                .padding(.horizontal, 24).padding(.top, 16)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        ReportDetailView(data: ReportDetailData(report))
                        SettingsGroup(title: "Something wrong with it?", note: "If it breaks the rules (insults, spam, someone else's details), flag it. If other people flag it too, it is hidden until it has been looked at.") {
                            ActionRow(id: "rd-flag", symbol: "flag.fill", title: flagged == nil ? "Flag this report" : "Flagged", subtitle: flagged, destructive: flagged == nil, chevron: false) {
                                if flagged == nil { confirmFlag = true }
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = done; scope.defaultFocus = "rd-close"; scope.focused = "rd-close" }
        .confirm("Flag this report?", message: "If other people flag it too, it's hidden until it has been looked at.", confirmTitle: "Flag it", isPresented: $confirmFlag) {
            Task { flagged = await flag() }
        }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}
