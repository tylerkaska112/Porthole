import SwiftUI

/// The Reports tab's list and a game's reports page, drawn with sample data.
struct ReportsDemo: View {
    var game = false
    @State private var scope = ReportsScope.mine
    @State private var filter = ReportsFilter.all
    @State private var order = ReportsOrder.popular
    @State private var query = ""
    @State private var verdictFilter: CompatVerdict?
    @State private var myDevice = false
    @State private var detail = false
    @State private var earlier = false

    static func badge(_ v: CompatVerdict?, reports: Int = 0, earlier: Int = 0, past: CompatVerdict? = nil) -> CompatBadge {
        CompatBadge(overall: v.map { CompatVerdictInfo(verdict: $0, reports: reports, confidence: "high") }, forDevice: nil, verdict: v,
                    earlier: CompatEarlier(reports: earlier, verdict: past, engine: "old", appVersion: past == nil ? nil : "1.1.0", date: nil, verdictReports: nil))
    }
    static let items: [ReportsItem] = {
        let rows: [(String, CompatVerdict?, Int, String)] = [
            ("Factorio", .great, 41, "2026-11-02"), ("The Forest", .playable, 18, "2026-11-01"), ("Celeste", .great, 6, "2026-11-03"),
            ("Call of Duty: Black Ops III", .broken, 9, "2026-10-28"), ("Terraria", .great, 22, "2026-10-30"), ("Unturned", nil, 0, ""),
            ("American Truck Simulator", nil, 0, ""), ("Assetto Corsa", .playable, 3, "2026-10-12"), ("Stardew Valley", .great, 14, "2026-11-02"),
        ]
        var out: [ReportsItem] = []
        for (i, row) in rows.enumerated() {
            let past: CompatVerdict? = (row.1 == nil && i == 5) ? .great : nil
            let earlier = past == nil ? 0 : 2
            let date: String? = row.3.isEmpty ? nil : row.3
            out.append(ReportsItem(id: "g\(i)", gameID: "g\(i)", title: row.0, reportCount: row.2, lastReport: date, badge: badge(row.1, reports: row.2, earlier: earlier, past: past), libraryID: UUID()))
        }
        return out
    }()

    var body: some View {
        FocusScroll {
            if game { gamePage } else { list }
        }
    }

    private var list: some View {
        let shown = ReportsLogic.visible(Self.items, filter: filter, order: order, query: query)
        let s = ReportsLogic.summary(Self.items)
        return PageScaffold(title: "Reports", symbol: "checkmark.seal.fill") {
            SegmentedPills(options: ReportsScope.allCases.map { .init(id: $0.rawValue, title: $0.title) }, selection: scope.rawValue) { scope = ReportsScope(rawValue: $0) ?? .mine }
            ReportsListLayout(filter: $filter, order: $order, query: $query, headline: "\(s.great) of \(s.total) games work great",
                              detail: "\(s.tested) tested on this version of the engine \u{00B7} \(s.untested) not yet tested. Tap one to report.", summary: s, items: shown,
                              subtitle: { $0.reportCount > 0 ? "\($0.reportCount) reports \u{00B7} latest \($0.lastReport ?? "")" : ($0.needsReport ? "Not tested on this version yet. Be the first to report." : "No reports yet") },
                              open: { _ in }) { EmptyView() }
        }
        .frame(maxWidth: 1000).frame(maxWidth: .infinity)
    }

    private var gamePage: some View {
        var d = GameReportsData()
        d.heroSymbol = "checkmark.seal.fill"; d.heroTint = Theme.good; d.heroTitle = "Works great"; d.heroDetail = "From 41 reports on this version of the engine"
        d.breakdown = ReportsLogic.Breakdown(great: 33, playable: 6, broken: 2, tags: [], earlier: 5)
        d.yourDevice = ("iPhone 18 Pro", .great)
        d.tags = [("Controls work", 24), ("Graphics glitches", 5), ("Phone gets hot", 4), ("Slow to load", 3)]
        d.factsTitle = "When it works great, people use"
        d.facts = [.init(id: "p", title: "Performance mode", value: "30 of 33"), .init(id: "d", title: "Wine desktop display on", value: "28 of 33"), .init(id: "s", title: "no extra swap", value: "25 of 33")]
        d.devices = [.init(id: "a", name: "iPhone 18 Pro", verdict: .great, reports: 12, yours: true), .init(id: "b", name: "iPad Pro M5", verdict: .great, reports: 20, yours: false), .init(id: "c", name: "iPhone 15", verdict: .playable, reports: 9, yours: false)]
        d.lines = [
            .init(id: 1, rating: .great, title: "iPhone 18 Pro \u{00B7} 2 Nov", subtitle: "Never crashed\n60 fps avg \u{00B7} 52 low \u{00B7} 90 min", earlier: false),
            .init(id: 2, rating: .playable, title: "iPhone 15 \u{00B7} 1 Nov", subtitle: "Crashes sometimes\n\u{201C}Fine after lowering the resolution\u{201D}", earlier: false),
            .init(id: 3, rating: .great, title: "iPad Pro M5 \u{00B7} 30 Oct", subtitle: "Never crashed", earlier: false),
            .init(id: 4, rating: .playable, title: "iPhone 16 \u{00B7} 12 Oct", subtitle: "Earlier engine (1.0): not counted", earlier: true),
        ]
        d.canLoadMore = true
        return PageScaffold(title: "Factorio", symbol: "checkmark.seal.fill") {
            GameReportsLayout(data: d, writeTitle: "Update my report", writeSubtitle: "You reported on this version.", writeProminent: false, verdictFilter: $verdictFilter, myDeviceOnly: $myDevice, hasDevice: true,
                              showDetail: $detail, showEarlier: $earlier, twoColumnsFrom: CommandLine.arguments.contains("--cols") ? 600 : 780)
        }
        .frame(maxWidth: 1000).frame(maxWidth: .infinity)
    }
}

/// One report opened in full, with sample values.
struct ReportDetailDemo: View {
    var body: some View {
        var d = ReportDetailData()
        d.rating = .playable
        d.device = "iPhone 15"
        d.date = "1 Nov 2026"
        d.earlierNote = nil
        d.tags = ["Controls work", "Graphics glitches", "Phone gets hot"]
        d.comment = "Fine after lowering the resolution to 1280 \u{00D7} 720. It gets warm after about twenty minutes."
        d.groups = [
            .init(id: "ran", title: "How it ran", note: nil, rows: [.init(id: "c", label: "Crashes", value: "Crashes sometimes"), .init(id: "f", label: "Average frame rate", value: "34 fps"),
                                                                  .init(id: "l", label: "Lowest frame rate", value: "21 fps"), .init(id: "m", label: "Played for", value: "52 min"), .init(id: "h", label: "Device heat", value: "Serious")]),
            .init(id: "on", title: "What it ran on", note: nil, rows: [.init(id: "d", label: "Device", value: "iPhone 15"), .init(id: "i", label: "iOS", value: "27.0.1"), .init(id: "a", label: "Porthole", value: "1.2.83"),
                                                                       .init(id: "e", label: "Game engine", value: "Madeira 31477ff r0 (this version)"), .init(id: "s", label: "Game files from", value: "Steam")]),
            .init(id: "set", title: "Settings used", note: "What the person had set for this game when they reported.", rows: [.init(id: "p", label: "Power mode", value: "Performance"), .init(id: "w", label: "Swap", value: "2048 MB"), .init(id: "v", label: "Video memory", value: "Automatic")]),
        ]
        return FocusScroll {
            ReportDetailView(data: d).padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }
}

/// A store page: the controls docked at the top, the games scrolling underneath.
struct StoreDockDemo: View {
    @State private var search = ""
    @State private var filter = "all"
    var body: some View {
        StorePage {
            PillButton(id: "d-store", title: "Steam", symbol: "chevron.up.chevron.down") {}
            IconPillButton(id: "d-refresh", symbol: "arrow.clockwise", label: "Refresh the list") {}
            SearchField(id: "d-search", prompt: "Search 120 games", text: $search)
            SegmentedPills(options: [.init(id: "all", title: "All"), .init(id: "installed", title: "Installed"), .init(id: "controller", title: "Controller")], selection: filter) { filter = $0 }
            IconPillButton(id: "d-friends", symbol: "person.2.fill", label: "Friends") {}
            IconPillButton(id: "d-sort", symbol: "arrow.up.arrow.down", label: "Sort") {}
            IconPillButton(id: "d-select", symbol: "checkmark.circle", label: "Select several") {}
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(0..<24, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 18).fill(Theme.panelHigh).aspectRatio(460.0 / 215.0, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
                            .focusTarget("dk-\(i)", radius: 18, scale: 1.1) {}
                        Text("Game \(i + 1)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }
}


/// The Stores tab's front page, with sample launchers: two signed in (one downloading), one empty, three not signed in.
struct StoresHubDemo: View {
    var body: some View {
        let cards = [StoreCardData(store: .steam, signedIn: true, account: "linemen1209", games: 128, installed: 14, downloading: 0.42),
                     StoreCardData(store: .epic, signedIn: true, account: "Alex", games: 23, installed: 3),
                     StoreCardData(store: .gog, signedIn: true, account: "tyler", games: 0, installed: 0),
                     StoreCardData(store: .itch, signedIn: false), StoreCardData(store: .amazon, signedIn: false), StoreCardData(store: .ea, signedIn: false)]
        FocusScroll {
            StoresHubView(cards: cards, allBadges: [.steam, .epic, .gog], totalGames: 151, totalInstalled: 17, downloadsSummary: "1 downloading \u{00B7} 2 queued",
                          downloadsFraction: CommandLine.arguments.contains("--idle") ? nil : 0.42, open: { _ in }, openAll: {}, openDownloads: {})
                .padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }
}


/// A game's page with sample values: the hero, and rows like the real page's.
struct GameDemo: View {
    @Environment(\.verticalSizeClass) private var vSize
    private var g: Mock.G { Mock.games[3] }

    private func hero(back: Bool) -> some View {
        GameHero(id: g.id, name: g.name, stats: [GameHeroStat(symbol: "clock.fill", title: "Last played", value: "3 days ago"), GameHeroStat(symbol: "hourglass", title: "Time played", value: "4 h 12 min"),
                                                 GameHeroStat(symbol: "internaldrive.fill", title: "On this device", value: "62.4 GB")],
                 play: {}, back: back ? {} : nil, compact: vSize == .compact) {
            StoreChip(store: .steam); GlowChip(text: "64-bit", tint: .white); ControllerPillButton(level: .partial)
            GlowChip(text: "Very Positive \u{00B7} 91%", symbol: "hand.thumbsup.fill", tint: Theme.good)
            BadgePill(badge: BadgeData(symbol: "questionmark.circle.fill", text: "Not yet tested", tint: Theme.textDim))
        }
    }

    @ViewBuilder private var rows: some View {
        SettingsGroup(title: "Play") {
            ChoiceRow(id: "gp-mode", symbol: "shield.checkered", title: "Start", options: [(false, "Through Steam"), (true, "Run directly")], selection: .constant(false))
            ChoiceRow(id: "gp-res", symbol: "display", title: "Resolution", options: [("a", "Default (1280 x 720)")], selection: .constant("a"))
        }
        SettingsGroup(title: "Explore") {
            ActionRow(id: "gp-door-controls", symbol: "gamecontroller.fill", title: "Controls and key binds", subtitle: "Mouse and keys") {}
            ActionRow(id: "gp-door-compat", symbol: "checkmark.seal.fill", title: "How it runs for others", subtitle: "Not yet tested \u{00B7} be the first to report") {}
            ActionRow(id: "gp-door-news", symbol: "newspaper.fill", title: "News and patch notes", subtitle: "From Steam") {}
            ActionRow(id: "gp-door-workshop", symbol: "puzzlepiece.extension.fill", title: "Workshop", subtitle: "Mods and community items", badge: "Beta") {}
        }
        SettingsGroup(title: "Manage") {
            ActionRow(id: "gp-door-more", symbol: "slider.horizontal.3", title: "More options", subtitle: "Speed, memory, engine and launch options") {}
            ActionRow(id: "gp-door-about", symbol: "info.circle.fill", title: "About and files", subtitle: "62.4 GB") {}
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackdrop(animated: false)
            Color.clear.overlay { GameArtView(id: g.id, name: g.name, kind: .hero).blur(radius: 7).scaleEffect(1.08) }.clipped().overlay { Color.black.opacity(0.38) }
                .overlay { LinearGradient(colors: [.clear, Theme.backgroundBottom.opacity(0.55), Theme.backgroundBottom.opacity(0.9)], startPoint: .top, endPoint: .bottom) }.ignoresSafeArea()
            GeometryReader { geo in
                if geo.size.width > geo.size.height * 1.05 {
                    HStack(alignment: .top, spacing: 0) {
                        FocusScroll { hero(back: true).padding(.horizontal, 20).padding(.vertical, vSize == .compact ? 8 : 14) }.frame(width: min(vSize == .compact ? 340 : 400, geo.size.width * 0.42))
                        FocusScroll { VStack(alignment: .leading, spacing: 12) { rows }.padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        PillButton(id: "gp-back", title: "Home", symbol: "chevron.left") {}.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 6)
                        FocusScroll { VStack(alignment: .leading, spacing: 18) { hero(back: false); rows }.padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity) }
                    }
                }
            }
        }
    }
}


/// The first-run guide's welcome and games pages, with sample values.
struct SetupDemo: View {
    let games: Bool
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if games { SetupStepper(names: ["Speed", "Components", "Games"], current: 3, done: [true, true, false]).frame(maxWidth: 360) }
                    Spacer()
                    PillButton(id: "su-later", title: "Finish later", symbol: "xmark") {}
                }
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 6).frame(maxWidth: 728)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        if games {
                            Text("Add your games").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                            SettingsGroup(title: "Stores") {
                                StoreSignInRow(id: "su-steam", store: .steam, signedIn: true, info: "x") {}
                                StoreSignInRow(id: "su-epic", store: .epic, signedIn: false, info: "x") {}
                                StoreSignInRow(id: "su-gog", store: .gog, signedIn: false, info: "x") {}
                                StoreSignInRow(id: "su-itch", store: .itch, signedIn: false, info: "x") {}
                            }
                        } else {
                            SetupWelcomeHero(compact: vSize == .compact)
                            VStack(spacing: 10) {
                                SetupStepCard(id: "su-o-1", number: 1, symbol: "bolt.fill", title: "Full speed", subtitle: "About 2 minutes", tag: "Needed") {}
                                SetupStepCard(id: "su-o-2", number: 2, symbol: "shippingbox.fill", title: "Windows components", subtitle: "About 25 MB", tag: "Done", tagGood: true) {}
                                SetupStepCard(id: "su-o-3", number: 3, symbol: "gamecontroller.fill", title: "Add your games", subtitle: "Steam, Epic Games, GOG, itch.io, Amazon Games, EA or Files", tag: "Optional") {}
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                PillButton(id: "su-next", title: games ? "Continue" : "Let's start", symbol: "chevron.right", style: .primary) {}.padding(.vertical, 12)
            }
        }
    }
}


/// The performance overlay over a game picture, with sample numbers. --line, --graph, --few and --bad pick the variants.
struct PerfDemo: View {
    var body: some View {
        let args = CommandLine.arguments
        let bad = args.contains("--bad")
        var history: [Double] = []
        for i in 0..<60 {
            let t = Double(i)
            var v: Double = bad ? 22 + 14 * sin(t / 4) + Double(i % 7) : 58 + 3 * sin(t / 5)
            if !bad && i == 40 { v -= 18 }
            history.append(v)
        }
        var rows = [PerfCardRow(id: "low", label: "Low", value: "52", symbol: "arrow.down.right", tint: nil),
                    PerfCardRow(id: "frame", label: "Frame", value: bad ? "41.2 ms" : "16.7 ms", symbol: "timer", tint: nil),
                    PerfCardRow(id: "cpu", label: "CPU", value: "182%", symbol: "cpu", tint: nil),
                    PerfCardRow(id: "thread", label: "Top thread", value: "69%", symbol: "chart.bar.fill", tint: nil),
                    PerfCardRow(id: "gpu", label: "GPU", value: "100%", symbol: "square.stack.3d.up.fill", tint: Theme.warn),
                    PerfCardRow(id: "gpuf", label: "GPU frame", value: "525.5 ms", symbol: "square.stack.3d.up.fill", tint: nil),
                    PerfCardRow(id: "mem", label: "Mem", value: "3.41 GB", symbol: "memorychip", tint: bad ? Theme.bad : nil),
                    PerfCardRow(id: "free", label: "Free", value: "3.75 GB", symbol: "memorychip", tint: nil),
                    PerfCardRow(id: "gmem", label: "GPU mem", value: "0.45 GB", symbol: "display", tint: nil),
                    PerfCardRow(id: "heat", label: "Heat", value: bad ? "serious" : "cool", symbol: "thermometer.medium", tint: bad ? Theme.bad : nil),
                    PerfCardRow(id: "bat", label: "Battery", value: "75%", symbol: "battery.75percent", tint: nil),
                    PerfCardRow(id: "mode", label: "Mode", value: "Performance", symbol: "bolt.fill", tint: nil),
                    PerfCardRow(id: "swap", label: "Swap", value: "-", symbol: "internaldrive", tint: nil)]
        if args.contains("--few") { rows = Array(rows.prefix(3)) }
        var size: CGFloat = 11
        if let i = args.firstIndex(of: "--size"), i + 1 < args.count, let v = Double(args[i + 1]) { size = CGFloat(v) }
        return ZStack(alignment: .topTrailing) {
            Color.clear.overlay { GameArtView(id: Mock.games[0].id, name: "Factorio", kind: .hero) }.clipped().ignoresSafeArea()
            PerfCardView(fps: bad ? 24 : 58, fpsTint: bad ? Theme.bad : nil, rows: rows, history: history, showGraph: args.contains("--graph"), asLine: args.contains("--line"), fontSize: size, opacity: 0.75).fixedSize()
                .padding(16)
        }
        .environment(\.artLoader, Mock.loader)
    }
}


/// The store tiles as every store now draws them: a status on the picture, a download in progress, and the name under it.
struct StoreTilesDemo: View {
    private func tile(_ i: Int, status: BadgeData?, progress: Double?, paused: Bool = false, store: GameStore? = nil, line: String? = nil) -> some View {
        let g = Mock.games[i]
        return VStack(alignment: .leading, spacing: 8) {
            Button {} label: {
                Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                    .overlay { GameArtView(id: g.id, name: g.name, kind: .header) }
                    .overlay(alignment: .topLeading) { if let status { TileStatus(badge: status).padding(8) } }
                    .overlay(alignment: .bottomTrailing) { if let store { StoreCorner(store: store, size: 26).padding(8) } }
                    .storeTileStyle()
            }
            .buttonStyle(TilePress())
            .focusTarget("st-\(i)", radius: 18, scale: 1.1) {}
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                if let progress { TileProgress(value: progress, paused: paused); Text(paused ? "Paused" : "1.4 GB of 3.2 GB \u{00B7} 4 min left").font(.caption2).foregroundStyle(Theme.textDim) }
                else if let line { Text(line).font(.caption).foregroundStyle(Theme.textDim) }
            }.padding(.horizontal, 4)
        }
    }

    var body: some View {
        StorePage {
            HStack(spacing: 6) { ForEach(GameStore.allCases) { StoreBadgeBacked(store: $0, size: 34) } }
            SearchField(id: "st-search", prompt: "Search 120 games", text: .constant(""))
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                tile(0, status: BadgeData(symbol: "arrow.down.circle.fill", text: "42%", tint: Theme.accent), progress: 0.42, store: .steam)
                tile(1, status: BadgeData(symbol: "checkmark.circle.fill", text: "In library", tint: Theme.good), progress: nil, store: .steam)
                tile(2, status: BadgeData(symbol: "arrow.triangle.2.circlepath.circle.fill", text: "Update", tint: Theme.accent), progress: nil, store: .epic)
                tile(3, status: BadgeData(symbol: "pause.circle.fill", text: "Paused", tint: Theme.warn), progress: 0.7, paused: true, store: .gog)
                tile(4, status: BadgeData(symbol: "exclamationmark.triangle.fill", text: "Failed", tint: Theme.bad), progress: nil, line: "The disk is full.")
                tile(5, status: nil, progress: nil, line: "2.1 GB download")
            }
        }
        .environment(\.artLoader, Mock.loader)
    }
}

/// A store's game sheet with sample values.
struct StoreSheetDemo: View {
    var body: some View {
        StoreSheetShell(store: .gog, title: "Call of Duty: Black Ops III", subtitle: nil, close: {}, art: { GameArtView(id: Mock.games[3].id, name: "x", kind: .hero) }) {
            TileProgress(value: 0.42)
            Text("1.4 GB of 3.2 GB \u{00B7} 4 min left").font(.footnote).foregroundStyle(Theme.textDim)
            HStack(spacing: 10) {
                StoreSheetButton(title: "Pause", symbol: "pause.fill") {}
                StoreSheetButton(title: "Cancel", symbol: "xmark", destructive: true) {}
            }
            StoreSheetButton(title: "Install", symbol: "arrow.down.circle.fill", prominent: true) {}
            Text("Downloads the game straight from GOG. Keep the app open while it installs.").font(.footnote).foregroundStyle(Theme.textDim)
        }
        .environment(\.artLoader, Mock.loader)
    }
}


/// The Steam and Epic game pages with sample values: the hero (picture, title, chips, buttons, numbers), then the media, the description and the rows.
struct StoreGameDemo: View {
    @Environment(\.verticalSizeClass) private var vSize
    private var g: Mock.G { Mock.games[0] }

    private func hero(back: Bool) -> some View {
        StoreHero(name: "Factorio", subtitle: "Wube Software LTD. \u{00B7} 14 Aug, 2020",
                  stats: [GameHeroStat(symbol: "arrow.down.circle.fill", title: "Download", value: "3.2 GB"), GameHeroStat(symbol: "internaldrive.fill", title: "On this device", value: "4.0 GB"),
                          GameHeroStat(symbol: "calendar", title: "Released", value: "14 Aug, 2020")],
                  back: back ? {} : nil, backTitle: "Steam", compact: vSize == .compact) {
            GameArtView(id: g.id, name: "Factorio", kind: .hero)
        } chips: {
            StoreChip(store: .steam)
            BadgePill(badge: BadgeData(symbol: "checkmark.seal.fill", text: "Playable", tint: Theme.good))
            ControllerPillButton(level: .partial)
            GlowChip(text: "Overwhelmingly Positive \u{00B7} 98%", symbol: "hand.thumbsup.fill", tint: Theme.good)
        } actions: {
            VStack(alignment: .leading, spacing: 10) {
                PillButton(id: "sp-main", title: "Pause", symbol: "pause.fill", style: .primary) {}
                TileProgress(value: 0.42)
                Text("1.4 GB of 3.2 GB \u{00B7} 4 min left").font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }

    @ViewBuilder private var details: some View {
        SettingsGroup(title: "About this game") {
            Text("Factorio is a game about building and maintaining factories. You will be mining resources, researching technologies, building infrastructure, automating production and fighting enemies.")
                .font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.92)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            ValueRow(id: "sp-genres", symbol: "tag.fill", title: "Genres", value: "Automation, Indie")
        }
        SettingsGroup(title: "Explore") {
            ActionRow(id: "sp-door-compat", symbol: "checkmark.seal.fill", title: "How it runs on Porthole", subtitle: "Playable") {}
            ActionRow(id: "sp-door-news", symbol: "newspaper.fill", title: "News and patch notes", subtitle: "From Steam") {}
            ActionRow(id: "sp-door-versions", symbol: "square.stack.3d.up.fill", title: "Version and DLC", subtitle: "Normal version") {}
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackdrop(animated: false)
            Color.clear.overlay { GameArtView(id: g.id, name: g.name, kind: .hero) }.blur(radius: 8).scaleEffect(1.08).clipped().overlay { Color.black.opacity(0.4) }
                .overlay { LinearGradient(colors: [.clear, Theme.backgroundBottom.opacity(0.55), Theme.backgroundBottom.opacity(0.92)], startPoint: .top, endPoint: .bottom) }.ignoresSafeArea()
            GeometryReader { geo in
                if geo.size.width > geo.size.height * 1.05 {
                    HStack(alignment: .top, spacing: 0) {
                        FocusScroll { hero(back: true).padding(.horizontal, 20).padding(.vertical, 8) }.frame(width: min(vSize == .compact ? 340 : 420, geo.size.width * 0.42))
                        FocusScroll { VStack(alignment: .leading, spacing: 20) { details }.padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { PillButton(id: "sp-back", title: "Steam", symbol: "chevron.left") {}; Spacer() }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 6)
                        FocusScroll { VStack(alignment: .leading, spacing: 20) { hero(back: false); details }.padding(.horizontal, 24).padding(.bottom, 30).frame(maxWidth: 900).frame(maxWidth: .infinity) }
                    }
                }
            }
        }
        .environment(\.artLoader, Mock.loader)
    }
}
