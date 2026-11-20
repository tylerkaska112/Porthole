import SwiftUI

/// The in-game menu's frame with sample cards, over something that looks like a game, at the size the real panel has.
struct MenuDemo: View {
    var tab = "performance"
    var page: String?
    @State private var on = true
    @State private var scope = FocusScope()

    private let tabs = [MenuTabItem(id: "performance", title: "Performance", symbol: "gauge.with.dots.needle.67percent"),
                        MenuTabItem(id: "controls", title: "Controls", symbol: "gamecontroller"),
                        MenuTabItem(id: "game", title: "Game", symbol: "ellipsis.circle"),
                        MenuTabItem(id: "steam", title: "Steam", symbol: "person.2.fill"),
                        MenuTabItem(id: "discord", title: "Discord", symbol: "bubble.left.and.bubble.right.fill")]

    /// A busy, bright picture, the worst case for reading text over it: sky, a sun, white buildings and dark ground.
    private var gameLike: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.45, green: 0.75, blue: 1.0), Color(red: 0.85, green: 0.92, blue: 1.0), Color(red: 0.25, green: 0.45, blue: 0.2)], startPoint: .top, endPoint: .bottom)
            Circle().fill(Color.yellow).frame(width: 140).offset(x: 200, y: -80)
            HStack(spacing: 10) { ForEach(0..<14, id: \.self) { i in Rectangle().fill(i % 3 == 0 ? Color.white : Color(white: 0.8)).frame(width: 46, height: CGFloat(120 + (i * 37) % 160)) } }.offset(y: 60)
            Rectangle().fill(Color(red: 0.1, green: 0.2, blue: 0.1)).frame(height: 90).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
    }

    /// An iPad gets the floating card, as in the game.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { geo in
            if isPad {
                ZStack(alignment: .trailing) {
                    gameLike
                        .onAppear {
                            // The size is kept between launches: start from the standard one unless asked for the large one.
                            MenuCardSize.shared.reset()
                            if CommandLine.arguments.contains("--menu-large") { MenuCardSize.shared.toggleLarge(total: geo.size.width) }
                        }
                    MenuCardFrame(total: geo.size.width, safe: geo.safeAreaInsets, close: {}, swipeBack: {}) {
                        MenuChrome(title: "Menu", subtitle: "Firewatch", page: page, backTitle: "Performance", tabs: tabs, tab: tab, selectTab: { _ in }, back: {}, close: {}, card: true,
                                   toggleSize: { withAnimation { MenuCardSize.shared.toggleLarge(total: geo.size.width) } }, sizeIsLarge: MenuCardSize.shared.isLarge(total: geo.size.width)) {
                            DemoPerformance(on: $on)
                        }
                        .environment(\.colorScheme, .dark)
                        .navScope(scope)
                    }
                }
            } else {
            ZStack(alignment: .trailing) {
                gameLike
                Color.black.opacity(geo.size.width < 640 ? 0 : 0.4).ignoresSafeArea()
                if geo.size.width < 640 || true { MenuBackdrop() }
                MenuChrome(title: "Menu", subtitle: "Factorio", page: page, backTitle: "Performance", tabs: tabs, tab: tab, selectTab: { _ in }, back: {}, close: {}) {
                    DemoPerformance(on: $on)
                }
                .frame(width: geo.size.width < 640 ? geo.size.width : min(geo.size.width, 1000)).frame(maxHeight: .infinity)
                .environment(\.colorScheme, .dark)
                .navScope(scope)
            }
            }
        }
    }
}

/// Several cards from one view, the way the real tabs are written (a tab is one struct whose body is a list of cards).
private struct DemoPerformance: View {
    @Binding var on: Bool
    var body: some View {
        MenuCard(title: "This phone") {
            HStack { Text("Processor").foregroundStyle(Theme.text); Spacer(); Text("38%").foregroundStyle(Theme.accent) }.padding(12)
            MenuDivider()
            HStack { Text("Memory").foregroundStyle(Theme.text); Spacer(); Text("3.1 / 5.8 GB").foregroundStyle(Theme.accent) }.padding(12)
            MenuDivider()
            HStack { Text("Temperature").foregroundStyle(Theme.text); Spacer(); Text("Fair").foregroundStyle(Theme.warn) }.padding(12)
        }
        MenuCard(title: "Speed") {
            MenuNavRow(id: "power", symbol: "bolt.fill", tint: .orange, title: "Power", value: "Balanced") {}
            MenuDivider()
            MenuNavRow(id: "engine", symbol: "gearshape.2.fill", tint: .gray, title: "Engine", value: "Default") {}
        }
        MenuCard(title: "Picture") {
            MenuNavRow(id: "up", symbol: "arrow.up.left.and.arrow.down.right", tint: .blue, title: "Upscaling", value: "Off") {}
            MenuDivider()
            MenuNavRow(id: "fg", symbol: "film.stack", tint: .purple, title: "Frame generation", value: "On, 2 extra") {}
        }
        MenuCard(title: "On the screen") {
            MenuToggleRow(title: "Performance overlay", detail: nil, isOn: $on)
            MenuDivider()
            MenuToggleRow(title: "Detailed readout", detail: "Frame times and memory", isOn: $on)
        }
        MenuCard(title: "Sound") {
            MenuToggleRow(title: "Game sound", detail: nil, isOn: $on)
        }
    }
}
