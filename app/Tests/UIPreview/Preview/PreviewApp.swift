import SwiftUI
import GameController
import simd

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
                ShellTab(id: "reports", title: "Reports", symbol: "checkmark.seal.fill"), ShellTab(id: "social", title: "Social", symbol: "bubble.left.and.bubble.right.fill", badge: 7),
                ShellTab(id: "settings", title: "Settings", symbol: "gearshape.fill")]

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
            case "shell-art": AppShell(tabs: tabs, selection: .constant("steam"), showHints: false) {
                ZStack(alignment: .top) {
                    ShellArt(key: "demo", art: AnyView(ZStack { AmbientBackdrop(animated: false); LinearGradient(colors: [Color(red: 0.2, green: 0.75, blue: 0.8), Color(red: 0.05, green: 0.1, blue: 0.2)], startPoint: .top, endPoint: .bottom) }.ignoresSafeArea()))
                    Text("A store game page").font(.largeTitle.bold()).foregroundStyle(.white).padding(.top, 40)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.navScope(scope)
            case "shaded":
                let col = {
                    VStack(alignment: .leading, spacing: 12) {
                        PillButton(id: "a", title: "Settings", symbol: "slider.horizontal.3", style: .glass) {}
                        PillButton(id: "b", title: "Play", symbol: "play.fill", style: .primary) {}
                        VStack(alignment: .leading, spacing: 4) { Text("62.4 GB").font(.headline); Text("On this device").font(.caption).foregroundStyle(Theme.textDim) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 16)
                        GlowChip(text: "Very Positive", symbol: "hand.thumbsup.fill", tint: Theme.good)
                    }.padding(16)
                }
                ZStack {
                    LinearGradient(colors: [Color(red: 0.85, green: 0.9, blue: 0.95), Color(red: 0.6, green: 0.75, blue: 0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                    VStack(spacing: 20) { col(); col().shadedGlass() }
                }
            case "settings-controls": ScrollView {
                PageScaffold(title: "Controls", symbol: "gamecontroller.fill", subtitle: "How games are controlled, and the settings for each kind of input") {
                    DefaultControlsPicker()
                    SettingsGroup(title: "Input settings", note: "A single game's own controls are set on that game's page.") {
                        ActionRow(id: "d1", symbol: "gamecontroller.fill", title: "Controller", subtitle: "Xbox Wireless Controller connected") {}
                        ActionRow(id: "d2", symbol: "keyboard", title: "Keyboard and mouse", subtitle: "Mouse speed, scrolling and Porthole's menu key") {}
                        ActionRow(id: "d3", symbol: "hand.tap.fill", title: "Touch screen", subtitle: "Look sensitivity 1.0\u{00D7}, sliding across buttons on") {}
                    }
                }.padding(.horizontal, 8).padding(.top, 50)
            }.background(Theme.background.ignoresSafeArea()).navScope(scope)
            case "sandbox":
                sandboxScene()
            case "starter-layouts":
                StarterLayoutPicker { _, _ in }.navScope(FocusScope())
            case "vpad":
                // The on-screen controller as the Porthole arrangement: on a phone over the whole game, on an iPad (--wide) under the picture, which is moved to the top. The iPad is drawn at its
                // real size (1376 x 1032 points) and scaled to fit the simulator.
                let args = CommandLine.arguments
                let style: VirtualPadStyle = args.contains("--ps") ? .playstation : (args.contains("--switch") ? .nintendo : .xbox)
                if args.contains("--wide") {
                    GeometryReader { geo in
                        let k = min(geo.size.width / 1376, geo.size.height / 1032)
                        ZStack(alignment: .top) {
                            Color(red: 0.2, green: 0.4, blue: 0.6)
                            Text("game screen").font(.system(size: 64, weight: .light, design: .serif)).foregroundStyle(.white.opacity(0.7)).frame(width: 1376, height: 774).background(Color.black)
                            VPadPreview(style: style, wide: true, preset: args.contains("--corner") ? .cornerSticks : .porthole)
                            if args.contains("--perf") || args.contains("--perf-few") || args.contains("--discord") {
                                // The overlays in the room between the trigger columns, centred in it.
                                let frames = VirtualPadLayout.frames(in: CGSize(width: 1376, height: 1032), insets: .init(), scale: 1, preset: args.contains("--corner") ? .cornerSticks : .porthole, wide: true)
                                if let room = VirtualPadLayout.centreRoom(frames: frames, top: 774) {
                                    let showPerf = args.contains("--perf") || args.contains("--perf-few")
                                    let names = ["Alex", "Sam", "Jordan", "Riley", "Casey", "Morgan", "Taylor", "Jamie", "Avery", "Quinn", "Drew", "Skyler", "Reese", "Blake", "Rowan", "Parker", "Finley", "Emerson", "Hayden", "Logan"]
                                    let count = args.firstIndex(of: "--people").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? (args.contains("--crowd") ? 6 : 3)
                                    let people = (0..<count).map { names[$0 % names.count] }
                                    BandOverlayStack(room: room.size,
                                                     perf: showPerf ? PerfCardView(fps: 58, fpsTint: nil, rows: PerfBandSample.rows(few: args.contains("--perf-few")), fontSize: 13, opacity: 0.75, centred: true) : nil,
                                                     members: args.contains("--discord") ? people.enumerated().map { CallMember(id: "m\($0.offset)", name: $0.element, avatarURL: nil, speaking: $0.offset % 3 == 1, isSelf: $0.offset == 0) } : [])
                                        .position(x: room.midX, y: room.midY)
                                    #if DEBUG
                                    let _: Void = print("BAND ROOM", room)
                                    #endif
                                }
                            }
                        }.frame(width: 1376, height: 1032)
                            .scaleEffect(k).frame(width: geo.size.width, height: geo.size.height)
                    }.background(Color(red: 0.2, green: 0.4, blue: 0.6)).ignoresSafeArea()
                } else {
                    ZStack { Color.black; Text("game screen").font(.system(size: 40, weight: .light, design: .serif)).foregroundStyle(.white.opacity(0.7)); VPadPreview(style: style, wide: false, preset: args.contains("--corner") ? .cornerSticks : .porthole) }.ignoresSafeArea()
                }
            case "pad-test":
                let args = CommandLine.arguments
                let _: Void = {
                    if let i = args.firstIndex(of: "--cam"), i + 1 < args.count {
                        let v = args[i + 1].split(separator: ",").compactMap { Float($0) }
                        if v.count == 6 { Pad3DView.previewCamera = (SIMD3<Float>(v[0], v[1], v[2]), SIMD3<Float>(v[3], v[4], v[5])) }
                    }
                }()
                let _: Void = { if args.contains("--gyro") { Pad3DView.previewMotion = { t in simd_quatf(angle: Float(sin(t * 0.8)) * 0.7, axis: [0, 0, 1]) * simd_quatf(angle: Float(sin(t * 0.6)) * 0.35, axis: [1, 0, 0]) * simd_quatf(angle: Float(cos(t * 0.5)) * 0.25, axis: [0, 1, 0]) } } }()
                let checking = args.contains("--check")
                let model = PadTestModel(source: {
                    let t = ProcessInfo.processInfo.systemUptime
                    var r = PadReading(name: "Xbox Wireless Controller", kind: args.contains("--ps") ? .dualSense : (args.contains("--ds4") ? .dualShock : .xbox), key: "preview")
                    r.lx = 0.07; r.ly = -0.04
                    r.rx = checking ? 0.02 : Float(sin(t * 1.6)) * 0.85; r.ry = checking ? 0.03 : Float(cos(t * 1.6)) * 0.85
                    r.lt = checking ? 0 : 0.42; r.rt = 0
                    r.hasHome = true; r.hasView = true
                    r.held = checking ? [] : [.a, .rb, .up]
                    return [r]
                })
                ScrollView {
                    PageScaffold(title: "Test controller", symbol: "gamecontroller.fill", subtitle: "See that every stick and button works") { ControllerTestContent(model: { model }) }.padding(.horizontal, 8).padding(.top, 50)
                }
                .background(Theme.background.ignoresSafeArea()).navScope(scope)
                .task { if checking { try? await Task.sleep(nanoseconds: 700_000_000); model.checkDrift() } }
            case "sticks-test":
                let drifting = PadTestModel(source: {
                    var r = PadReading(name: "DualSense Wireless Controller", kind: .dualSense, key: "preview")
                    r.lx = 0.07; r.ly = -0.04; r.rx = 0.02; r.ry = 0.03
                    return [r]
                })
                ScrollView {
                    PageScaffold(title: "Sticks and drift", symbol: "scope", subtitle: "Check a stick that drifts and set a deadzone") { StickSettingsContent(model: { drifting }) }.padding(.horizontal, 8).padding(.top, 50)
                }
                .background(Theme.background.ignoresSafeArea()).navScope(scope)
                .task { try? await Task.sleep(nanoseconds: 700_000_000); drifting.checkDrift() }
            case "keys-test":
                let mouse = KeyboardMouseTestModel()
                ScrollView {
                    PageScaffold(title: "Test keyboard and mouse", symbol: "keyboard", subtitle: "See that every key and button works") {
                        SettingsGroup(title: "Keyboard", note: "Magic Keyboard. Press keys: a key that is held lights up, and one you have pressed keeps a ring.") {
                            KeyboardDiagram(held: [UInt(GCKeyCode.keyW.rawValue), UInt(GCKeyCode.leftShift.rawValue), UInt(GCKeyCode.spacebar.rawValue)], ever: [UInt(GCKeyCode.keyA.rawValue), UInt(GCKeyCode.keyW.rawValue), UInt(GCKeyCode.keyD.rawValue), UInt(GCKeyCode.leftShift.rawValue), UInt(GCKeyCode.spacebar.rawValue)])
                            Text("Last key: Space").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                        }
                        SettingsGroup(title: "Mouse or trackpad", note: "Magic Trackpad. Move it, click every button, turn the wheel.") { MouseDiagram(model: mouse) }
                    }.padding(.horizontal, 8).padding(.top, 50)
                }
                .background(Theme.background.ignoresSafeArea()).navScope(scope)
                .onAppear { mouse.showSample(buttons: ["Left"], ever: ["Left", "Right", "Middle"], position: CGPoint(x: 0.35, y: 0.2), trail: (0..<30).map { i in CGPoint(x: -0.4 + Double(i) * 0.025, y: -0.1 + sin(Double(i) / 4) * 0.2) }, moved: CGSize(width: 1280, height: -310), wheelFlash: 1, mouse: "Magic Trackpad") }
            case "default-controls": ScrollView { VStack(spacing: 18) { DefaultControlsPicker() }.padding(20) }.background(Theme.background.ignoresSafeArea()).navScope(scope)
            case "game": GameDemo().navScope(scope).onAppear { scope.defaultFocus = "gp-play" }
            case "setup", "setup-games", "setup-controls", "coach": if screen == "coach" { CoachDemo() } else { SetupDemo(page: screen).navScope(scope) }
            case "perf": PerfDemo()
            case "store-tiles": StoreTilesDemo()
            case "store-sheet": StoreSheetDemo()
            case "store-game": StoreGameDemo().navScope(scope)
            case "store-dock": AppShell(tabs: tabs, selection: .constant("steam"), showHints: false) { StoreDockDemo() }.navScope(scope)
            case "community": CommunityPage().navScope(scope).onAppear { scope.defaultFocus = "cm-x" }
            case "discord": DiscordBrowser(data: DiscordDemo.data, actions: DiscordDemo.actions)
            case "social": AppShell(tabs: tabs, selection: .constant("social"), showHints: false) { SocialDemo() }.navScope(scope)
            case "menu": MenuDemo()
            case "menu-page": MenuDemo(page: "Power")
            case "discord-banner": DiscordBannerDemo()
            case "achievement-toast": ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.14), Color(red: 0.35, green: 0.3, blue: 0.2), Color(red: 0.1, green: 0.1, blue: 0.15)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(spacing: 12) {
                    AchievementToastCard(name: "Factory Foreman", detail: "Build 100 assemblers and keep the whole factory running for an hour.", icon: nil, lifetime: 5.5)
                    AchievementToastCard(name: "First Steps", detail: "", icon: nil)
                }.frame(maxWidth: 440).padding(.horizontal, 12).padding(.top, 12)
            }
            case "discord-dmcall": DiscordBrowser(data: { var d = DiscordDemo.data; d.directCall = "Alex"; d.callStatus = "Connected"; d.currentChannelID = "dm5"; return d }(), actions: DiscordBrowserActions())
            case "discord-call": DiscordBrowser(data: DiscordDemo.inCall, actions: DiscordBrowserActions())
            case "settings": SettingsDemo().navScope(scope).onAppear { scope.defaultFocus = "set-display" }
            default:
                AppShell(tabs: tabs, selection: $tab, showHints: CommandLine.arguments.contains("--hints")) {
                    // --friends: the real Home screen's Friends row above the page. --bar-notices: the notice chips sit in that row (a phone held sideways) instead of inside the page.
                    // --one-notice: a single chip, like "Factorio closed unexpectedly".
                    let sideways = UIScreen.main.bounds.width > UIScreen.main.bounds.height
                    let friends = true, inBar = true   // the real Home: the alerts share the picker's row
                    let notices = CommandLine.arguments.contains("--no-notices") ? [] : (CommandLine.arguments.contains("--one-notice") ? Array(Mock.notices.prefix(1)) : Mock.notices)
                    HomeView(notices: friends && inBar ? [] : notices, games: Mock.cards, act: { _ in }, dismiss: { _ in }, open: { _ in }, play: { _ in }, add: {}, forceControllerLayout: CommandLine.arguments.contains("--pad"))
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if friends {
                                HStack(spacing: 12) {
                                    if inBar, !notices.isEmpty { NoticeStrip(notices: notices, act: { _ in }, dismiss: { _ in }, compact: sideways) } else { Spacer(minLength: 0) }
                                    HomeLayoutPicker()
                                }
                                .frame(height: sideways ? 48 : 56)
                                .padding(.leading, sideways ? 14 : 28).padding(.trailing, 28).padding(.top, 8).padding(.bottom, 4)
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


/// The on-screen controller in a preview: always the Porthole arrangement.
struct VPadPreview: UIViewRepresentable {
    let style: VirtualPadStyle
    let wide: Bool
    var preset: VirtualPadLayout.Preset = .porthole
    func makeUIView(context: Context) -> VirtualPadView {
        let v = VirtualPadView()
        v.preset = preset; v.style = style; v.wide = wide; v.restingAlpha = 0.7
        return v
    }
    func updateUIView(_ v: VirtualPadView, context: Context) {}
}


/// Sample numbers for the performance overlay in the iPad band.
enum PerfBandSample {
    static func rows(few: Bool) -> [PerfCardRow] {
        let all = [PerfCardRow(id: "frame", label: "Frame", value: "16.7 ms", symbol: "timer", tint: nil), PerfCardRow(id: "cpu", label: "CPU", value: "182%", symbol: "cpu", tint: nil),
                   PerfCardRow(id: "gpu", label: "GPU", value: "71%", symbol: "square.stack.3d.up.fill", tint: nil), PerfCardRow(id: "mem", label: "Mem", value: "3.41 GB", symbol: "memorychip", tint: nil),
                   PerfCardRow(id: "free", label: "Free", value: "3.75 GB", symbol: "memorychip", tint: nil), PerfCardRow(id: "heat", label: "Heat", value: "cool", symbol: "thermometer.medium", tint: nil),
                   PerfCardRow(id: "bat", label: "Battery", value: "75%", symbol: "battery.75percent", tint: nil), PerfCardRow(id: "low", label: "1% low", value: "52", symbol: "arrow.down.right", tint: nil)]
        return few ? Array(all.prefix(2)) : all
    }
}


extension PreviewRoot {
    /// The controls sandbox scene (its own function: inside the big scene switch it was too much for the type-checker).
    static func applySandboxDefaults(_ args: [String]) {
        UserDefaults.standard.set(args.contains("--left"), forKey: TouchHandedness.key)
        if let i = args.firstIndex(of: "--button-size"), i + 1 < args.count { UserDefaults.standard.set(args[i + 1], forKey: TouchButtonSize.key) } else { UserDefaults.standard.removeObject(forKey: TouchButtonSize.key) }
    }

    @ViewBuilder func sandboxScene() -> some View {
        let args = CommandLine.arguments
        // --left flips the layout for the left hand, --button-size N draws the buttons at that factor (the two device settings of Settings > Controls > Touch screen).
        let _ = Self.applySandboxDefaults(args)
        let which = args.firstIndex(of: "--layout").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "gamepad"
        let planned = TouchLayout(controls: [
            TouchControlSpec(label: "", action: "stick-wasd", x: 0.12, y: 0.74, size: 112),
            TouchControlSpec(label: "E", action: "key-E", x: 0.9, y: 0.78, size: 52), TouchControlSpec(label: "F", action: "key-F", x: 0.8, y: 0.78, size: 52),
            TouchControlSpec(label: "Space", action: "space", mode: "hold", x: 0.85, y: 0.6, size: 60),
            TouchControlSpec(label: "", action: "overlay-perf", x: 0.22, y: 0.14, size: 130), TouchControlSpec(label: "", action: "overlay-discord", x: 0.2, y: 0.34, size: 110),
        ], picture: PicturePlacement(across: 1, down: 0, scale: 0.7))
        let shipped = which == "planned" ? ShippedLayout(id: "planned", title: "Planned around the picture", detail: "", layout: planned) : ShippedLayouts.layout(id: which)
        let layout = shipped?.layout ?? TouchLayout.gamepad
        let sandbox = ControlsSandboxScreen(layout: args.contains("--pad") ? TouchLayout() : layout, title: shipped?.title ?? "Gamepad", pad: args.contains("--pad") ? SandboxPad.current : nil, startEditing: args.contains("--edit")) { _ in }
        if args.contains("--ipad") {
            // An iPad in landscape at its real size (1376 x 1032 points), scaled to fit the simulator.
            GeometryReader { geo in
                let k = min(geo.size.width / 1376, geo.size.height / 1032)
                sandbox.frame(width: 1376, height: 1032).scaleEffect(k, anchor: .topLeading).frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }.background(Color.black).ignoresSafeArea()
        } else { sandbox }
    }
}
