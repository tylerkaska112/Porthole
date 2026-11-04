import SwiftUI

/// Mock data for the preview screens.
enum Mock {
    struct G { let id: UUID; let name: String; let steam: Int; let sub: String; let chip: String; let badge: BadgeData? }
    static let games: [G] = [
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!, name: "Factorio", steam: 427520, sub: "Played 2 hours ago", chip: "Steam", badge: BadgeData(symbol: "checkmark.seal.fill", text: "Playable", tint: Theme.good)),
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!, name: "The Forest", steam: 242760, sub: "Played yesterday", chip: "Steam", badge: BadgeData(symbol: "exclamationmark.triangle.fill", text: "Runs rough", tint: Theme.warn)),
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!, name: "Assetto Corsa", steam: 244210, sub: "Not played yet", chip: "Direct", badge: nil),
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000004")!, name: "Call of Duty: Black Ops III", steam: 311210, sub: "Played 3 days ago", chip: "Steam", badge: BadgeData(symbol: "xmark.octagon.fill", text: "Doesn't start", tint: Theme.bad)),
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000005")!, name: "American Truck Simulator", steam: 270880, sub: "Played last week", chip: "Steam", badge: nil),
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000006")!, name: "Unturned", steam: 304930, sub: "Not played yet", chip: "Steam", badge: nil),
        G(id: UUID(uuidString: "11111111-0000-0000-0000-000000000007")!, name: "Warhammer: Vermintide 2", steam: 552500, sub: "Played last month", chip: "Steam", badge: BadgeData(symbol: "questionmark.circle.fill", text: "Not yet tested", tint: Theme.textDim)),
    ]
    static var cards: [GameCardData] { games.enumerated().map { i, g in GameCardData(id: g.id, name: g.name, subtitle: g.sub, launchChip: g.chip, badge: g.badge, controller: i % 3 == 0 ? .partial : i % 3 == 1 ? .full : nil) } }

    static let cache = NSCache<NSString, UIImage>()
    static let loader: ArtLoader = { id, kind in
        guard let g = games.first(where: { $0.id == id }) else { return nil }
        let file = kind == .hero ? "library_hero.jpg" : "header.jpg"
        let key = "\(g.steam)-\(file)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        for host in ["https://cdn.cloudflare.steamstatic.com", "https://shared.fastly.steamstatic.com"] {
            guard let url = URL(string: "\(host)/steam/apps/\(g.steam)/\(file)"), let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { continue }
            cache.setObject(image, forKey: key); return image
        }
        if kind == .hero, let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(g.steam)/header.jpg"), let (data, _) = try? await URLSession.shared.data(from: url) { return UIImage(data: data) }
        return nil
    }

    static let notices: [NoticeData] = [
        NoticeData(id: "update", symbol: "arrow.down.circle.fill", title: "Update ready", detail: "Version 0.50.21 is ready to install. Open Settings > Updates to download and install it.", actionTitle: "Open", dismissKey: "update"),
        NoticeData(id: "win", symbol: "shippingbox.fill", title: "Windows components", detail: "Many games need Microsoft's C++ runtime. About 25 MB, from Microsoft, checked before use.", tint: Theme.warn, actionTitle: "Download", dismissKey: "runtime"),
    ]
}

struct PreviewRoot: View {
    let screen: String
    @State private var tab = "home"
    @State private var scope = FocusScope()
    @State private var launchScope = FocusScope()
    let tabs = [ShellTab(id: "home", title: "Home", symbol: "house.fill"), ShellTab(id: "steam", title: "Steam", symbol: "arrow.down.circle.fill"),
                ShellTab(id: "reports", title: "Reports", symbol: "checkmark.seal.fill"), ShellTab(id: "settings", title: "Settings", symbol: "gearshape.fill")]

    var body: some View {
        Group {
            switch screen {
            case "launch": LaunchView(data: Self.launch(step: 2), scope: launchScope, cancel: {}, showSteam: nil)
            case "launch-late": LaunchView(data: Self.launch(step: 4), scope: launchScope, cancel: {}, showSteam: {})
            case "launch-fail": LaunchView(data: Self.launchFailed, scope: launchScope, cancel: {})
            case "props": PropsDemo()
            case "pad": PadKeyboardDemo()
            case "info": InfoDemo()
            case "reports", "reports-game":
                AppShell(tabs: tabs, selection: .constant("reports"), showHints: false) { ReportsDemo(game: screen == "reports-game") }.navScope(scope)
            case "report-detail": ReportDetailDemo().navScope(scope)
            case "stores": AppShell(tabs: tabs, selection: .constant("steam"), showHints: false) { StoresHubDemo() }.navScope(scope).onAppear { scope.defaultFocus = "store-steam" }
            case "game": GameDemo().navScope(scope).onAppear { scope.defaultFocus = "gp-play" }
            case "setup", "setup-games": SetupDemo(games: screen == "setup-games").navScope(scope)
            case "perf": PerfDemo()
            case "store-tiles": StoreTilesDemo()
            case "store-sheet": StoreSheetDemo()
            case "store-game": StoreGameDemo().navScope(scope)
            case "store-dock": AppShell(tabs: tabs, selection: .constant("steam"), showHints: false) { StoreDockDemo() }.navScope(scope)
            case "settings": SettingsDemo().navScope(scope).onAppear { scope.defaultFocus = "set-display" }
            default:
                AppShell(tabs: tabs, selection: $tab, showHints: CommandLine.arguments.contains("--hints")) {
                    // --friends: the real Home screen's Friends row above the page. --bar-notices: the notice chips sit in that row (a phone held sideways) instead of inside the page.
                    // --one-notice: a single chip, like "Factorio closed unexpectedly".
                    let friends = CommandLine.arguments.contains("--friends"), inBar = CommandLine.arguments.contains("--bar-notices")
                    let notices = CommandLine.arguments.contains("--no-notices") ? [] : (CommandLine.arguments.contains("--one-notice") ? Array(Mock.notices.prefix(1)) : Mock.notices)
                    HomeView(notices: friends && inBar ? [] : notices, games: Mock.cards, act: { _ in }, dismiss: { _ in }, open: { _ in }, play: { _ in }, add: {}, forceControllerLayout: CommandLine.arguments.contains("--pad"))
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if friends {
                                HStack(spacing: 12) {
                                    if inBar, !notices.isEmpty { NoticeStrip(notices: notices, act: { _ in }, dismiss: { _ in }, compact: true) } else { Spacer(minLength: 0) }
                                    PillButton(id: "home-friends", title: "Friends \u{00B7} 2 online", symbol: "person.2.fill", style: .glass) {}.fixedSize()
                                }
                                .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 4)
                            }
                        }
                }
                .navScope(scope)
                .onAppear {
                    scope.defaultFocus = "hero-play"
                    // --tile: the glow starts on the third game's tile; --sections: the screen switches sections (as the real one does), so the hints name LB and RB's targets.
                    if CommandLine.arguments.contains("--tile"), let id = UUID(uuidString: "11111111-0000-0000-0000-000000000003") { scope.defaultFocus = id; scope.focused = id }
                    if CommandLine.arguments.contains("--sections") { scope.onSection = { _ in } }
                }
            }
        }
        .environment(\.artLoader, Mock.loader)
        .preferredColorScheme(.dark)
        .task { await runScript() }
    }

    static func launch(step: Int) -> LaunchData {
        let titles = ["Turn on JIT", "Start Steam", "Sync cloud saves", "Sign in to Steam", "Load the game"]
        let steps = titles.enumerated().map { LaunchStepData(id: "\($0.offset)", title: $0.element, state: $0.offset < step ? .done : ($0.offset == step ? .active : .pending)) }
        let g = Mock.games[3]
        return LaunchData(gameID: g.id, name: g.name, steps: steps, headline: titles[min(step, 4)] + "\u{2026}", detail: "Steam checks your licence before the game opens. This can take a minute the first time.",
                          chips: [LaunchSettingChip(symbol: "shield.checkered", text: "Through Steam"), LaunchSettingChip(symbol: "display", text: "1280 \u{00D7} 720"), LaunchSettingChip(symbol: "bolt.fill", text: "Balanced"), LaunchSettingChip(symbol: "memorychip", text: "896 MB pool")],
                          began: Date().addingTimeInterval(CommandLine.arguments.contains("--slow") ? -73 : -23))
    }
    static var launchFailed: LaunchData {
        var d = launch(step: 2); d.failure = "Steam needs to download a shared component (Steamworks Common Redistributables) and could not. Check your connection and try again."; return d
    }

    /// `--cmds right,right,down,select` plays navigation commands one by one, to show the focus glow where it ends up.
    func runScript() async {
        guard let i = CommandLine.arguments.firstIndex(of: "--cmds"), i + 1 < CommandLine.arguments.count else { return }
        try? await Task.sleep(for: .seconds(1.5))
        for word in CommandLine.arguments[i + 1].split(separator: ",") {
            let cmd: NavCommand
            switch word {
            case "up": cmd = .move(.up); case "down": cmd = .move(.down); case "left": cmd = .move(.left); case "right": cmd = .move(.right)
            case "select": cmd = .select; case "back": cmd = .back; default: continue
            }
            NavHub.shared.dispatch(cmd)
            try? await Task.sleep(for: .milliseconds(350))
        }
    }
}

@main struct PreviewApp: App {
    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--theme"), i + 1 < CommandLine.arguments.count { ThemeStore.shared.presetID = CommandLine.arguments[i + 1] }
        if CommandLine.arguments.contains("--night") { HalloweenNight.forceTonight = true }
        // --season thanksgiving (or halloween): show that holiday's look whatever the date is.
        if let i = CommandLine.arguments.firstIndex(of: "--season"), i + 1 < CommandLine.arguments.count { ThemeStore.shared.previewSeason = Season(rawValue: CommandLine.arguments[i + 1]) }
    }
    var body: some Scene {
        WindowGroup {
            PreviewRoot(screen: CommandLine.arguments.firstIndex(of: "--screen").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "home")
        }
    }
}


/// The settings look, with sample rows (the real pages use the same rows).
struct SettingsDemo: View {
    @State private var res = "1280x720"
    @State private var glow = GlowLevel.strong
    @State private var moving = true
    @State private var look = 2.4
    @State private var power = 1
    @Environment(\.focusScope) private var scope
    let pages = [("display", "Display", "display", Color.cyan), ("performance", "Performance", "speedometer", .orange), ("controls", "Controls", "hand.tap.fill", .blue), ("sound", "Sound", "speaker.wave.2.fill", .red)]

    var body: some View {
        ZStack {
            AmbientBackdrop()
            HStack(spacing: 0) {
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Settings").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).padding(.horizontal, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Theme.label("Playing").padding(.horizontal, 8)
                            ForEach(pages, id: \.0) { p in SidebarRow(id: "set-\(p.0)", symbol: p.2, tint: p.3, title: p.1, selected: p.0 == "display") {} }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Theme.label("Accounts").padding(.horizontal, 8)
                            SidebarRow(id: "set-steam", symbol: "arrow.down.circle.fill", tint: .indigo, title: "Steam", selected: false) {}
                            SidebarRow(id: "set-jit", symbol: "bolt.horizontal.fill", tint: .green, title: "JIT and tunnel", detail: "!", selected: false) {}
                        }
                    }.padding(14)
                }.frame(width: 300)
                Rectangle().fill(Theme.line).frame(width: 1)
                FocusScroll {
                    PageScaffold(title: "Appearance", symbol: "paintpalette.fill", subtitle: "Theme, colours and motion") {
                        SettingsGroup(title: "Picture") {
                            ChoiceRow(id: "res", symbol: "rectangle.expand.vertical", title: "Resolution", info: "The size of the screen games see.",
                                      options: DisplayResolution.allIDs.map { ($0, DisplayResolution.title(id: $0, screenAspect: 2.16)) }, selection: $res)
                            ChoiceRow(id: "glow", symbol: "sparkles", title: "Glow", options: GlowLevel.allCases.map { ($0, $0.title) }, selection: $glow)
                            ToggleRow(id: "mov", symbol: "wind", title: "Moving background", info: "The soft lights drift slowly.", isOn: $moving)
                            SliderRow(id: "look", symbol: "scope", title: "Look sensitivity", value: $look, range: 0.4...8, step: 0.1, format: { String(format: "%.1f\u{00D7}", $0) })
                            ActionRow(id: "act", symbol: "arrow.counterclockwise", title: "Reset the tunnel", detail: "Done", info: "Deletes the VPN setting and makes a fresh one.")  {}
                            ValueRow(id: "val", symbol: "key.fill", title: "Pairing file", value: "Imported", statusColor: Theme.good)
                        }
                    }
                }.frame(maxWidth: .infinity)
            }
        }
    }
}


/// A page with an (i) that is already open, to see how the information sheet sits on a phone and on an iPad.
struct InfoDemo: View {
    @State private var scope = FocusScope()
    @State private var shown = true
    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            PageScaffold(title: "Appearance", symbol: "paintpalette.fill", subtitle: "Theme, colours and motion") {
                ValueRow(id: "r", symbol: "arrow.up.left.and.arrow.down.right", title: "Resolution", value: "1280 \u{00D7} 720")
            }
        }
        .sheet(isPresented: $shown) {
            InfoPopover(title: "Resolution", text: "The size of the screen games see. Higher is sharper but needs more memory and a faster device; lower is faster. Games that pick their own resolution can choose any size up to this one, and the picture is scaled to your screen. Each game can have its own on its page. Applies the next time a game starts.", scope: scope) { shown = false }
        }
    }
}

private struct PadKeyboardDemo: View {
    @State private var text = "C:\\Games\\Foo"
    var body: some View { PadKeyboardSheet(title: "Program", monospaced: true, text: $text) }
}
