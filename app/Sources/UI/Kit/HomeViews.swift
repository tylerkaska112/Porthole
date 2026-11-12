// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The home screen and its pieces. They take plain values (no app models), so the same views are drawn by the app and by the simulator preview.

enum ArtKind { case header, hero }

/// How a view asks for a game's picture. The app plugs in Steam's artwork; the default has none.
typealias ArtLoader = @Sendable (UUID, ArtKind) async -> UIImage?
private struct ArtLoaderKey: EnvironmentKey { static let defaultValue: ArtLoader = { _, _ in nil } }
extension EnvironmentValues { var artLoader: ArtLoader { get { self[ArtLoaderKey.self] } set { self[ArtLoaderKey.self] = newValue } } }

struct BadgeData: Equatable {
    var symbol: String
    var text: String
    var tint: Color
}

/// How well a game works with a controller, as Steam lists it.
enum ControllerLevel: String, Equatable {
    case full, partial
    var title: String { self == .full ? "Full controller support" : "Partial controller support" }
    /// What fits on a small tile.
    var short: String { self == .full ? "FULL" : "PARTIAL" }
    /// What the badge means, in plain words (shown when it is tapped on a game's page).
    var explanation: String {
        switch self {
        case .full:
            return "Steam lists this game as designed to be played with a controller from start to finish: the menus, the launcher and the game itself.\n\nPlug in or connect a controller and it should work without the touch screen or a keyboard."
        case .partial:
            return "Steam lists this game as playable with a controller, but not completely. Some parts still expect a keyboard and mouse, usually menus, a launcher, text entry or certain actions, so the game may ask you to switch.\n\nOn Porthole you can still reach those parts: open the game's page, then Controls and key binds, to put keys on controller buttons or show the on-screen controls for the parts the controller cannot do."
        }
    }
}

/// A controller badge that says which kind it is without reading closely: FULL is a solid green capsule, PARTIAL is amber and outlined with dashes.
struct ControllerPill: View {
    let level: ControllerLevel
    var compact = false
    /// Just the controller symbol, in the badge's colour: for a tile that has stepped back and is small.
    var iconOnly = false

    var body: some View {
        let full = level == .full
        let tint = full ? Theme.good : Theme.warn
        HStack(spacing: 5) {
            Image(systemName: "gamecontroller.fill").font(.system(size: compact ? 11 : 13, weight: .bold))
            if !iconOnly {
                Text(compact ? level.short : level.title)
                    .font(.system(size: compact ? 10 : 13, weight: compact ? .heavy : .bold)).tracking(compact ? 0.6 : 0).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(full ? Color.black.opacity(0.85) : tint)
        .padding(.horizontal, compact ? 8 : 11).padding(.vertical, compact ? 4 : 6)
        .background(full ? AnyShapeStyle(tint) : AnyShapeStyle(Color.black.opacity(0.6)), in: Capsule())
        .overlay { if !full { Capsule().strokeBorder(tint, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3])) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(level.title)
    }
}

/// The controller badge on a game's own page: pressing it explains what it means.
struct ControllerPillButton: View {
    let level: ControllerLevel
    @State private var shown = false
    @State private var scope = FocusScope()

    var body: some View {
        Button { shown = true } label: { ControllerPill(level: level) }
            .buttonStyle(.plain)
            .focusTarget("controller-badge", radius: 16, scale: 1.08) { shown = true }
            .accessibilityHint("Explains what this means")
            .sheet(isPresented: $shown) { InfoPopover(title: level.title, text: level.explanation, scope: scope) { shown = false } }
    }
}

struct GameCardData: Identifiable, Equatable {
    let id: UUID
    var name: String
    var subtitle: String
    var launchChip: String?          // "Steam" / "Direct"
    var store: GameStore?            // the launcher the game was downloaded from (its badge sits on the picture)
    var badge: BadgeData?
    var controller: ControllerLevel?
}

struct NoticeData: Identifiable, Equatable {
    let id: String
    var symbol: String
    var title: String
    var detail: String?              // shown in the (i) pop-up
    var tint: Color = Theme.accent
    var actionTitle: String?
    var spinner = false
    /// Set for a chip the person may hide (a small x appears on it). The key says which one, so a new one of the same kind (a newer update) shows again.
    var dismissKey: String?
    /// For an error: its text, so the (i) pop-up can offer to look it up in the website's documentation.
    var helpMessage: String?
}

/// A game's picture, with a colourful placeholder (made from its name) until the artwork arrives.
struct GameArtView: View {
    let id: UUID
    let name: String
    var kind: ArtKind = .header
    /// Writes the game's name on the colourful placeholder, for a tile whose name is not shown anywhere else.
    var titled = false
    /// No placeholder icon or name while the picture loads: for a backdrop, where a plain gradient is better than a controller symbol.
    var plain = false
    @Environment(\.artLoader) private var loader
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Placeholder(name: name, titled: titled, plain: plain)
            if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
        }
        .clipped()
        .animation(.easeOut(duration: 0.3), value: image == nil)
        .task(id: id) { image = nil; image = await loader(id, kind) }
        .accessibilityHidden(true)
    }

    /// What a game without a picture gets: a gradient and soft light made from its name (the same every launch), and its first letter large and faint behind everything.
    private struct Placeholder: View {
        let name: String
        let titled: Bool
        let plain: Bool

        /// FNV-1a: the same number for the same name on every launch (String.hashValue is seeded per run, so the colours would change each time the app opens).
        private static func stableHash(_ text: String) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325
            for byte in text.lowercased().utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
            return h
        }

        var body: some View {
            let h = Self.stableHash(name)
            let hue = Double(h % 360) / 360
            let hue2 = (hue + 0.08 + Double((h >> 9) % 20) / 100).truncatingRemainder(dividingBy: 1)
            let blobX = CGFloat((h >> 17) % 60) / 100 - 0.1, blobY = CGFloat((h >> 25) % 50) / 100 - 0.2
            let letter = String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased()
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.42), Color(hue: hue2, saturation: 0.6, brightness: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geo in
                    let m = min(geo.size.width, geo.size.height), w = geo.size.width
                    Circle().fill(Color(hue: hue2, saturation: 0.45, brightness: 0.85).opacity(0.30)).frame(width: max(m, w * 0.55))
                        .blur(radius: m * 0.22).offset(x: w * blobX, y: geo.size.height * blobY)
                    Text(letter).font(.system(size: m * 1.25, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.07))
                        .frame(width: w, height: geo.size.height).offset(x: w * 0.18, y: m * 0.12)
                }
                if plain {
                    EmptyView()
                } else if titled {
                    Text(name).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7).padding(14)
                } else {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .clipped()
        }
    }
}

/// One game on the shelf: just its picture (the name is written big above the shelf when it is the chosen one), small icons for how it runs, and the glow when selected. The games that
/// are not the chosen one sit back a little, so the eye goes to the one the page is about.
struct GameTile: View {
    let game: GameCardData
    var width: CGFloat = 230
    /// How much the glow ring grows when selected. Smaller when the tile itself already grows (a controller is in use).
    var focusScale: CGFloat = 1.12
    /// A tile that has stepped back: smaller icons.
    var small = false
    /// The game the page is showing (the others are dimmed a little).
    var chosen = true
    var play: (() -> Void)?
    var onFocus: (() -> Void)?
    let open: () -> Void

    private let radius: CGFloat = 18
    @State private var pendingOpen: DispatchWorkItem?

    /// With a mouse a second click on the tile within a third of a second plays the game; a single click opens its page once that time has passed.
    private func clicked() {
        guard HardwareInput.shared.mouseConnected, let play else { open(); return }
        if let pending = pendingOpen { pending.cancel(); pendingOpen = nil; play(); return }
        let item = DispatchWorkItem { pendingOpen = nil; open() }
        pendingOpen = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    var body: some View {
        Button(action: clicked) {
            Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                .overlay { GameArtView(id: game.id, name: game.name, titled: true) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: width * 0.22).allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) { if let badge = game.badge { BadgeIcon(badge: badge, size: small ? 22 : 26).padding(small ? 7 : 9) } }
                .overlay(alignment: .bottomTrailing) { if let store = game.store { StoreCorner(store: store, size: small ? 20 : 26).padding(small ? 7 : 9) } }
                .overlay(alignment: .bottomLeading) { if let level = game.controller { ControllerPill(level: level, compact: true, iconOnly: true).padding(small ? 7 : 9) } }
                .overlay(alignment: .topTrailing) {
                    // Halloween: a cobweb in the corner of some tiles (always the same ones: it follows the game's id), a spider on a few.
                    let pick = Int(game.id.uuid.0)
                    if halloweenOn, pick % 3 == 0 { HalloweenWeb(corner: .topTrailing, size: max(40, width * 0.24), spider: pick % 6 == 0) }
                }
                .brightness(chosen ? 0 : -0.1).saturation(chosen ? 1 : 0.9)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(chosen ? 0.22 : 0.1), lineWidth: 1))
                .shadow(color: .black.opacity(chosen ? 0.45 : 0.25), radius: chosen ? 14 : 8, y: chosen ? 8 : 4)
        }
        .buttonStyle(TilePress())
        .frame(width: width)
        .animation(.easeOut(duration: 0.25), value: chosen)
        .focusTarget(game.id, radius: radius, scale: focusScale, secondary: play, label: "Details", secondaryLabel: "Play", onFocus: onFocus, action: open)
        .accessibilityLabel(game.name)
    }
}

/// A tile gives a little under the finger.
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// How a game runs, as a small round icon in the badge's colour: the full words are on the page of the chosen game.
struct BadgeIcon: View {
    let badge: BadgeData
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: badge.symbol).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(badge.tint)
            .frame(width: size, height: size)
            .background(.black.opacity(0.6), in: Circle())
            .overlay(Circle().strokeBorder(badge.tint.opacity(0.55), lineWidth: 1))
            .accessibilityLabel(badge.text)
    }
}

struct BadgePill: View {
    let badge: BadgeData
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.symbol).font(.caption2.weight(.bold))
            Text(badge.text).font(.caption2.weight(.bold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(badge.tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(badge.tint.opacity(0.5), lineWidth: 1))
    }
}

/// The chosen game, written large over its artwork: name, a line about it, how it runs, and Play right there.
struct HeroInfo: View {
    let game: GameCardData
    var mostRecent = true
    let play: () -> Void
    let open: () -> Void
    var playing = false
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        let tight = vSize == .compact
        VStack(alignment: .leading, spacing: tight ? 12 : 18) {
            VStack(alignment: .leading, spacing: tight ? 6 : 10) {
                if !tight {
                    HStack(spacing: 7) {
                        Image(systemName: mostRecent ? "play.circle.fill" : "books.vertical.fill").font(.system(size: 13, weight: .bold))
                        Text(mostRecent ? "CONTINUE PLAYING" : "IN YOUR LIBRARY").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(1.6)
                    }
                    .foregroundStyle(Theme.accent)
                }
                Text(game.name).font(.system(size: tight ? 28 : 42, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.55), radius: 10, y: 2)
                Label { Text(game.subtitle) } icon: { Image(systemName: "clock.fill").font(.system(size: tight ? 11 : 12)) }
                    .font(.system(size: tight ? 13 : 15, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75)).shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                FlowLayout(spacing: 8) {
                    if let store = game.store { StoreChip(store: store) }
                    // The store chip already says "Steam"; this one is only for "Direct" (a game that skips its launcher).
                    if let chip = game.launchChip, !(game.store != nil && chip == "Steam") { GlowChip(text: chip, symbol: chip == "Steam" ? "shield.checkered" : "play.fill", tint: .white) }
                    if let badge = game.badge { BadgePill(badge: badge) }
                    if let level = game.controller { ControllerPill(level: level, compact: true) }
                }
            }
            .id(game.id)
            .transition(.opacity.combined(with: .offset(y: 10)))
            HStack(spacing: 12) {
                PillButton(id: "hero-play", title: playing ? "Preparing" : "Play", symbol: "play.fill", style: .primary, enabled: !playing, action: play)
                PillButton(id: "hero-open", title: "Details", symbol: "slider.horizontal.3", action: open)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: game.id)
    }
}

/// Behind the home screen: the chosen game's artwork, dimmed and faded into the background, changing as the selection moves along the shelf.
struct HomeBackdrop: View {
    let game: GameCardData?
    var height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            if let game {
                Color.clear.overlay { SlowZoom { GameArtView(id: game.id, name: game.name, kind: .hero, plain: true).opacity(0.9) } }
                    .clipped()
                    .id(game.id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .overlay { LinearGradient(colors: [Theme.backgroundBottom.opacity(0.88), Theme.backgroundBottom.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing) }
        .overlay { LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Theme.backgroundBottom.opacity(0.7), location: 1)], startPoint: .top, endPoint: .bottom) }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.5), value: game?.id)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Zooms its content in very slowly (a few percent over a quarter of a minute), so the picture behind the page is never quite still. It starts again when the content is replaced.
struct SlowZoom<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var zoomed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content.scaleEffect(zoomed ? 1.07 : 1).onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 18)) { zoomed = true } } }
    }
}

/// A line of things that need attention, as short chips. Details live behind the (i).
struct NoticeStrip: View {
    let notices: [NoticeData]
    let act: (NoticeData) -> Void
    var dismiss: ((NoticeData) -> Void)?
    /// Shorter chips, for a phone held sideways where every point of height counts.
    var compact = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(notices) { n in
                    HStack(spacing: 0) {
                        Button { act(n) } label: {
                            HStack(spacing: 8) {
                                if n.spinner { ProgressView().controlSize(.small).tint(n.tint) } else { Image(systemName: n.symbol).font(.subheadline.weight(.bold)).foregroundStyle(n.tint) }
                                Text(n.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                if let action = n.actionTitle { Text(action).font(.caption.weight(.heavy)).foregroundStyle(Theme.onAccent).padding(.horizontal, 9).padding(.vertical, 3).background(n.tint, in: Capsule()) }
                            }
                            .padding(.leading, 14).padding(.trailing, n.detail == nil ? 14 : 4).padding(.vertical, compact ? 4 : 8)
                            .frame(minHeight: compact ? 40 : 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusTarget("notice-\(n.id)", radius: 22, scale: 1.04) { act(n) }
                        if let detail = n.detail { InfoButton(id: "notice-info-\(n.id)", title: n.title, text: detail, helpMessage: n.helpMessage) }
                        if n.dismissKey != nil, let dismiss {
                            Button { dismiss(n) } label: {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textDim)
                                    .frame(width: compact ? 40 : 44, height: compact ? 40 : 44).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .focusTarget("notice-dismiss-\(n.id)", radius: 22, scale: 1.12) { dismiss(n) }
                            .accessibilityLabel("Hide this")
                        }
                    }
                    .background(Theme.panel, in: Capsule())
                    .overlay(Capsule().strokeBorder(n.tint.opacity(0.35), lineWidth: 1))
                }
            }
            .padding(.vertical, compact ? 2 : 6).padding(.horizontal, 2)
        }
    }
}

/// The last tile on the shelf: add a game.
struct AddGameTile: View {
    var width: CGFloat = 230
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.accent)
                        Text("Add a game").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    }
                }
                .background(Theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
        }
        .buttonStyle(TilePress())
        .frame(width: width)
        .focusTarget("add-game", radius: 18, scale: 1.12, action: action)
        .accessibilityLabel("Add a game")
    }
}

// MARK: - The way the library is laid out

/// How Home shows the library: the shelf along the bottom (the default), a grid of cards, or a list.
enum HomeLayout: String, CaseIterable, Identifiable {
    case shelf, grid, list
    static let key = "f4.homeLayout"
    var id: String { rawValue }
    var title: String { switch self { case .shelf: "Shelf"; case .grid: "Grid"; case .list: "List" } }
    var symbol: String { switch self { case .shelf: "rectangle.3.group.fill"; case .grid: "square.grid.2x2.fill"; case .list: "list.bullet" } }
}

/// Three small buttons that switch Home between the shelf, a grid and a list. The choice is kept.
struct HomeLayoutPicker: View {
    @AppStorage(HomeLayout.key) private var raw = HomeLayout.shelf.rawValue

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeLayout.allCases) { layout in
                let on = raw == layout.rawValue
                Button { withAnimation(.easeOut(duration: 0.2)) { raw = layout.rawValue } } label: {
                    Image(systemName: layout.symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                        .frame(width: 40, height: 36).background(on ? Theme.accent : Color.clear, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusTarget("home-layout-\(layout.rawValue)", radius: 18, scale: 1.08) { withAnimation(.easeOut(duration: 0.2)) { raw = layout.rawValue } }
                .accessibilityLabel("\(layout.title) layout")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).background(Theme.panel, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }
}

/// One game in the list layout: a small picture, the name and what is known about it, and a Play button.
struct GameListRow: View {
    let game: GameCardData
    let play: () -> Void
    let open: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Color.clear.aspectRatio(460.0 / 215.0, contentMode: .fit).frame(width: 104)
                        .overlay { GameArtView(id: game.id, name: game.name, titled: false) }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(game.subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                        HStack(spacing: 6) {
                            if let badge = game.badge { BadgeIcon(badge: badge, size: 22) }
                            if let level = game.controller { ControllerPill(level: level, compact: true, iconOnly: true) }
                            if let store = game.store { StoreCorner(store: store, size: 22) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TilePress())
            .focusTarget(game.id, radius: 14, scale: 1.02, secondary: play, label: "Details", secondaryLabel: "Play", action: open)
            .accessibilityLabel(game.name)
            Button(action: play) {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 44, height: 44).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .focusTarget("list-play-\(game.id)", radius: 22, scale: 1.1, action: play)
            .accessibilityLabel("Play \(game.name)")
        }
        .padding(10)
        .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// The last row of the list layout: add a game.
struct AddGameRow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.accent)
                Text("Add a game").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
            .contentShape(Rectangle())
        }
        .buttonStyle(TilePress())
        .focusTarget("add-game", radius: 16, scale: 1.02, action: action)
        .accessibilityLabel("Add a game")
    }
}


/// The home screen: the chosen game's artwork across the back, its name and Play in front, and one shelf of games along the bottom. Moving along the shelf changes the chosen game.
struct HomeView: View {
    let notices: [NoticeData]
    let games: [GameCardData]
    var featuredPlaying = false
    let act: (NoticeData) -> Void
    var dismiss: ((NoticeData) -> Void)?
    let open: (GameCardData) -> Void
    let play: (GameCardData) -> Void
    let add: () -> Void
    var menu: ((GameCardData) -> AnyView)?
    /// Draws the controller layout (wide chosen tile) without a controller: for the simulator preview.
    var forceControllerLayout = false
    @AppStorage(HomeLayout.key) private var layoutRaw = HomeLayout.shelf.rawValue
    private var layout: HomeLayout { HomeLayout(rawValue: layoutRaw) ?? .shelf }
    @State private var shownID: UUID?
    /// False until the page has appeared: the tiles then come in one after another.
    @State private var arrived = false
    @Environment(\.focusScope) private var scope
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    /// Always starts on the first game in the list (the Add button when there is none), so it is clear where the controller is whenever Home opens.
    private func startFocus(force: Bool) { let target: AnyHashable = games.first.map { AnyHashable($0.id) } ?? AnyHashable("empty-add")
        scope?.start(at: target, force: force) }

    private var shown: GameCardData? { games.first { $0.id == shownID } ?? games.first }

    var body: some View {
        GeometryReader { geo in
            let side: CGFloat = hSize == .regular ? 32 : 16
            let sideways = vSize == .compact   // a phone held sideways: everything has to fit in about 350 points of height
            let tileWidth: CGFloat = sideways ? min(190, geo.size.width / 4.4) : geo.size.width > 900 ? 270 : hSize == .regular ? 230 : min(max(180, geo.size.width * 0.56), 250)
            ZStack {
                HomeBackdrop(game: layout == .shelf ? shown : games.first, height: geo.size.height * (geo.size.height > geo.size.width ? 0.72 : 0.8))
                // The bats (or falling leaves) go above the game's picture and still behind the text (the backdrop's own would be hidden by that picture).
                FestiveSky()
                // Not a scroll view: the page is sized to the screen and never moves up or down. Only the row of games scrolls, sideways.
                if layout != .shelf {
                    libraryPage(width: geo.size.width, side: side, sideways: sideways).frame(width: geo.size.width, height: geo.size.height)
                } else {
                VStack(alignment: .leading, spacing: sideways ? 8 : 20) {
                    if !notices.isEmpty { NoticeStrip(notices: notices, act: act, dismiss: dismiss, compact: sideways).padding(.horizontal, side - 2) }
                    Spacer(minLength: 0)
                    if let shown {
                        HeroInfo(game: shown, mostRecent: shown.id == games.first?.id, play: { play(shown) }, open: { open(shown) }, playing: featuredPlaying && shown.id == games.first?.id)
                            .padding(.horizontal, side)
                        if !sideways { shelfTitle.padding(.horizontal, side).padding(.bottom, -10) }
                        shelf(tileWidth: tileWidth, side: side, sideways: sideways)
                    } else {
                        EmptyHome(add: add).padding(.horizontal, side)
                    }
                }
                .padding(.vertical, sideways ? 4 : 12)
                .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .onAppear { startFocus(force: true); BatsPlacement.shared.homeDrawsThem = true; arrived = true }
        .onDisappear { BatsPlacement.shared.homeDrawsThem = false }
        .onChange(of: games.first?.id) { _, _ in startFocus(force: false) }
    }

    /// The grid and list layouts: the page scrolls up and down. The most recently played game is written large at the top with Play, and the whole library follows below it.
    private func libraryPage(width: CGFloat, side: CGFloat, sideways: Bool) -> some View {
        let available = width - side * 2, gap: CGFloat = 14
        let columns = layout == .grid ? (available >= 820 ? 4 : available >= 520 ? 3 : 2) : 1
        let cell = (available - gap * CGFloat(columns - 1)) / CGFloat(columns)
        enum Item: Identifiable { case game(GameCardData), add
            var id: String { switch self { case .game(let g): g.id.uuidString; case .add: "add" } } }
        let items: [Item] = games.map(Item.game) + [.add]
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        @ViewBuilder func rowView(_ row: [Item]) -> some View {
            HStack(alignment: .top, spacing: gap) {
                ForEach(row) { item in
                    switch item {
                    case .game(let game):
                        if layout == .grid {
                            VStack(alignment: .leading, spacing: 6) {
                                GameTile(game: game, width: cell, focusScale: 1.05, play: { play(game) }) { open(game) }
                                Text(game.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(game.subtitle).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            .frame(width: cell, alignment: .leading)
                            .contextMenu { if let menu { menu(game) } }
                        } else {
                            GameListRow(game: game, play: { play(game) }) { open(game) }
                                .contextMenu { if let menu { menu(game) } }
                        }
                    case .add:
                        if layout == .grid { AddGameTile(width: cell, action: add) } else { AddGameRow(action: add) }
                    }
                }
                if row.count < columns { Spacer(minLength: 0) }
            }
        }
        return FocusScroll(axes: .vertical) {
            VStack(alignment: .leading, spacing: sideways ? 12 : 18) {
                if !notices.isEmpty { NoticeStrip(notices: notices, act: act, dismiss: dismiss, compact: sideways).padding(.horizontal, side - 2) }
                if let hero = games.first {
                    HeroInfo(game: hero, mostRecent: true, play: { play(hero) }, open: { open(hero) }, playing: featuredPlaying).padding(.horizontal, side)
                } else {
                    EmptyHome(add: add).padding(.horizontal, side)
                }
                if !games.isEmpty {
                    shelfTitle.padding(.horizontal, side)
                    Group {
                        if games.count > 24 { LazyVStack(alignment: .leading, spacing: gap) { ForEach(rows.indices, id: \.self) { rowView(rows[$0]) } } }
                        else { VStack(alignment: .leading, spacing: gap) { ForEach(rows.indices, id: \.self) { rowView(rows[$0]) } } }
                    }
                    .padding(.horizontal, side).padding(.bottom, 24)
                }
            }
            .padding(.top, sideways ? 4 : 12)
        }
    }

    /// "Your library" with how many games it holds.
    private var shelfTitle: some View {
        HStack(spacing: 8) {
            Text("YOUR LIBRARY").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(1.6).foregroundStyle(.white.opacity(0.6))
            Text("\(games.count)").font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8).padding(.vertical, 2).background(.white.opacity(0.12), in: Capsule())
            Spacer(minLength: 0)
            if games.count > 1, let at = games.firstIndex(where: { $0.id == shown?.id }) {
                Text("\(at + 1) of \(games.count)").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: at)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// With a controller the chosen game is wide and the others step back, like Steam's Big Picture shelf; with touch every tile is the same size.
    private func shelf(tileWidth: CGFloat, side: CGFloat, sideways: Bool) -> some View {
        let pad = forceControllerLayout || ControllerInput.shared.connected
        let chosen = shown?.id
        @ViewBuilder func tiles() -> some View {
            ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                GameTile(game: game, width: pad ? (game.id == chosen ? tileWidth * 1.3 : tileWidth * 0.78) : tileWidth, focusScale: pad ? 1.03 : 1.12, small: pad && game.id != chosen, chosen: game.id == chosen,
                         play: { play(game) }, onFocus: { shownID = game.id }) { open(game) }
                    .contextMenu { if let menu { menu(game) } }
                    .opacity(arrived ? 1 : 0).offset(y: arrived ? 0 : 16)
                    .animation(.spring(response: 0.55, dampingFraction: 0.86).delay(Double(min(index, 8)) * 0.05), value: arrived)
            }
            AddGameTile(width: pad ? tileWidth * 0.78 : tileWidth, action: add)
            FestivePatch(height: (pad ? tileWidth * 0.78 : tileWidth) * 215.0 / 460.0)
        }
        return FocusScroll(axes: .horizontal) {
            // A big library is built as it scrolls into view; a normal one is built whole, so the D-pad always finds its neighbour.
            Group {
                if games.count > 24 { LazyHStack(spacing: 14) { tiles() } } else { HStack(spacing: 14) { tiles() } }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: shownID)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: pad)
            .padding(.horizontal, side).padding(.vertical, sideways ? 14 : 26)
        }
        .scrollClipDisabled()
        .mask { HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 36) }.padding(.vertical, -80) }
    }
}

struct EmptyHome: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 54)).foregroundStyle(Theme.accentGradient).shadow(color: Theme.accent.opacity(0.6), radius: 18)
            Text("Add your first game").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            PillButton(id: "empty-add", title: "Add a game", symbol: "plus", style: .primary, action: add)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .panel(radius: 24)
    }
}
