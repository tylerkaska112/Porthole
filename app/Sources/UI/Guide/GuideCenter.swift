// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import Observation

/// What a guide step's button does for you.
enum GuideAction: Hashable {
    case addGame
    case openStore(GameStore)
    case openSettings(SettingsPage)

    var title: String {
        switch self {
        case .addGame: "Add a game now"
        case .openStore(let store): "Open \(store.title)"
        case .openSettings: "Open these settings"
        }
    }
    var symbol: String {
        switch self { case .addGame: "plus.circle.fill"; case .openStore: "arrow.up.forward.app.fill"; case .openSettings: "gearshape.fill" }
    }
}

/// One step of a guide: a picture (a small drawing of the screen, or an SF Symbol), a short heading and a sentence or two, and sometimes a button that takes you there.
struct GuideStep: Hashable {
    var symbol: String
    var title: String
    var text: String
    var art: GuideArt?
    var action: GuideAction?

    init(symbol: String, title: String, text: String, art: GuideArt? = nil, action: GuideAction? = nil) {
        self.symbol = symbol; self.title = title; self.text = text; self.art = art; self.action = action
    }
}

/// A short explanation of one screen: what it is for and what to do on it.
struct Guide: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let steps: [GuideStep]
}

/// The words of every guide. Plain sentences, no jargon; each says what the screen is for and what to do there. Steps with a drawing show the part of the screen they talk about.
enum GuideCatalog {
    static let home = Guide(id: "home", title: "Home", symbol: "house.fill", steps: [
        GuideStep(symbol: "gamecontroller.fill", title: "Your games",
                  text: "Everything you can play is on Home. The big card is the game you played last; press Play to start it. Tap any other card to open that game's page.", art: .home),
        GuideStep(symbol: "plus.circle.fill", title: "Add a game",
                  text: "Add a game brings one in from a store you are signed in to (Steam, Epic Games, GOG or itch.io), or from a Windows program or installer in the Files app.",
                  art: .addGame, action: .addGame),
        GuideStep(symbol: "bell.badge.fill", title: "Notices",
                  text: "Cards above your games tell you what needs attention: JIT waiting, an update, a download. Tap one to act on it, or the x to hide it.", art: .notices),
    ])

    static let stores = Guide(id: "stores", title: "Stores", symbol: "square.grid.2x2.fill", steps: [
        GuideStep(symbol: "square.grid.2x2.fill", title: "Where games come from",
                  text: "Open a store to sign in and see its library. Games that have a Windows version can be installed from there.",
                  art: .stores, action: .openStore(.steam)),
        GuideStep(symbol: "tray.full.fill", title: "All games and Downloads",
                  text: "All games shows every library together. Downloads lists what is being installed and how far along it is.", art: .storesLists),
    ])

    static let reports = Guide(id: "reports", title: "Reports", symbol: "checkmark.seal.fill", steps: [
        GuideStep(symbol: "checkmark.seal.fill", title: "How games run on devices like yours",
                  text: "Reports are what other people found when they played a game. Open a game to see which settings people use when it works great, and how it does on each device.", art: .reports),
        GuideStep(symbol: "square.and.pencil", title: "Write your own",
                  text: "After you play, a report helps the next person. You can write one from a game's page or from here."),
    ])

    static let settings = Guide(id: "settings", title: "Settings", symbol: "gearshape.fill", steps: [
        GuideStep(symbol: "gamecontroller.fill", title: "Display, performance, sound and controls",
                  text: "The picture, speed, sound and controls every game starts with, each on a page of its own. A game's own page can change many of them for that game only.",
                  art: .settings, action: .openSettings(.display)),
        GuideStep(symbol: "storefront.fill", title: "Stores",
                  text: "Your Steam, Epic, GOG, itch.io, Amazon and EA sign-ins, and each store's library and downloads.",
                  art: .settings, action: .openSettings(.stores)),
        GuideStep(symbol: "bolt.horizontal.fill", title: "JIT and connection",
                  text: "The connection that lets games run fast: how JIT is switched on, the tunnel, your VPN and cellular data. If a game will not start, look here first.",
                  art: .settings, action: .openSettings(.jit)),
        GuideStep(symbol: "wrench.and.screwdriver.fill", title: "Advanced and Report a problem",
                  text: "Advanced holds the engine options, Windows components such as .NET, and the log. Search at the top of Settings finds any setting by name. Report a problem sends the log to the developer when something goes wrong.",
                  art: .settings, action: .openSettings(.report)),
    ])

    static let gamePage = Guide(id: "gamepage", title: "A game's page", symbol: "gamecontroller.fill", steps: [
        GuideStep(symbol: "play.fill", title: "Play",
                  text: "Play starts the game. The first start can take a while; Porthole turns JIT on first and then launches.", art: .gamePage),
        GuideStep(symbol: "slider.horizontal.3", title: "Settings for this game",
                  text: "Resolution, power mode, swap and the other rows here apply to this game only. A row that says Default follows Settings.", art: .gameRows),
        GuideStep(symbol: "hand.tap.fill", title: "On-screen controls",
                  text: "Choose how the touch controls work for this game. Inside the game, the pencil lets you move and resize them."),
    ])

    /// The sheet that opens by itself the first time Add a game opens (and from Settings, Tips and guides).
    static let addGame = Guide(id: "addgame", title: "Add a game", symbol: "plus.circle.fill", steps: [
        GuideStep(symbol: "list.bullet", title: "Choose where the game is",
                  text: "Import a game folder from Files, download a game you own from Steam, Epic Games, GOG or itch.io, or run a Windows installer from a disc or a setup file.", art: .addSources),
        GuideStep(symbol: "checkmark.circle.fill", title: "Already in the app",
                  text: "Games Porthole finds in its own folders are listed under Already in the app. Add puts one in your library."),
        GuideStep(symbol: "terminal.fill", title: "Add by path",
                  text: "If you know a program's path on the Windows drive, such as C:\\Games\\Foo\\foo.exe, use Add by path."),
    ])

    /// The game menu: a tip at the top of it the first time it opens (see GameMenu.swift), and a guide to read again from Settings.
    static let gameMenu = Guide(id: "menu", title: "The game menu", symbol: "line.3.horizontal", steps: [
        GuideStep(symbol: "speedometer", title: "Performance",
                  text: "Power mode, Eco mode, and the performance overlay, which is off until you turn it on. Use it when the game runs slowly or the phone gets hot.", art: .gameMenu),
        GuideStep(symbol: "hand.tap.fill", title: "Controls",
                  text: "How touch works for this game, whether the on-screen controls show, the keyboard, and the pencil that edits the controls."),
        GuideStep(symbol: "gamecontroller.fill", title: "Game",
                  text: "Report how the game runs, the touch controls guide, capture a frame for a bug report, the edge handle, and Close game."),
    ])

    /// The first game ever started: shown BEFORE the game starts (GameTourView), so nothing is competing with the game for the processor while the person reads it.
    static let inGame = Guide(id: "ingame", title: "Playing a game", symbol: "gamecontroller.fill", steps: [
        GuideStep(symbol: "pencil", title: "Edit the controls",
                  text: "Once the game is running, the pencil at the top lets you move, resize and add the on-screen buttons and sticks for this game."),
        GuideStep(symbol: "keyboard", title: "Keyboard",
                  text: "Next to it, the keyboard button brings up the on-screen keyboard when a game wants you to type."),
        GuideStep(symbol: "arrow.left", title: "Swipe in from the right",
                  text: "Swipe in from the right edge of the screen to open the menu: performance, controls and the rest."),
        GuideStep(symbol: "hand.point.up.left.fill", title: "Touching the game",
                  text: "Tap to click. Drag to hold the left button. Press and hold, or tap with two fingers, for the right button. Pinch to scroll."),
    ])

    static let all: [Guide] = [home, stores, reports, settings, gamePage, addGame, gameMenu, inGame]
    static func guide(_ id: String) -> Guide? { all.first { $0.id == id } }
}

/// Which guides the person has seen, whether tips are on, and which guide is showing. One place for the whole app: screens ask it to show a guide the first time they appear,
/// the question-mark button asks it to show one again, and Settings can turn it all off or reset it.
@MainActor @Observable
final class GuideCenter {
    static let shared = GuideCenter()

    private static let seenKey = "f4.guides.seen", enabledKey = "f4.guides.enabled", startedKey = "f4.guides.started"

    /// Tips on or off. Off stops the guides from appearing by themselves; the question-mark button and Settings still open them.
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    private(set) var seen: Set<String>
    /// The guide on screen, if any. The app's frame presents it.
    var current: Guide?
    /// The first-game tour on request (Settings, Tips and guides), shown without a game behind it.
    var tourReplay = false

    /// A tip inside something that is not a screen (the game menu): shown once while tips are on.
    func wantsTip(_ id: String) -> Bool { enabled && !seen.contains(id) }

    /// Set while something else covers the screen (a setup guide, a sheet, a running game): a guide waits.
    var blocked = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        seen = Set(d.stringArray(forKey: Self.seenKey) ?? [])
        // People who already had the app before guides existed are not walked through screens they know. They can open any guide with the question mark or from Settings.
        if !d.bool(forKey: Self.startedKey) {
            d.set(true, forKey: Self.startedKey)
            let existing = d.bool(forKey: "f4.setupSeen") || d.bool(forKey: "f4.setupDone") || d.bool(forKey: "f4.menuHintShown")
            if existing { seen = Set(GuideCatalog.all.map(\.id)); d.set(Array(seen), forKey: Self.seenKey) }
        }
    }

    func hasSeen(_ id: String) -> Bool { seen.contains(id) }

    /// The first game ever started should show the tour before it starts.
    var wantsFirstGameTour: Bool { enabled && !seen.contains(GuideCatalog.inGame.id) }

    func markSeen(_ id: String) {
        guard seen.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(seen), forKey: Self.seenKey)
    }

    /// Show every guide again, the next time its screen appears.
    func resetAll() {
        seen = []
        UserDefaults.standard.set([String](), forKey: Self.seenKey)
        enabled = true
    }

    /// A screen has appeared: show its guide if tips are on, it has not been seen, and nothing else is in the way. Waits a moment so the screen can settle first.
    func autoShow(_ id: String) {
        guard enabled, !seen.contains(id), GuideCatalog.guide(id) != nil, id != GuideCatalog.inGame.id, id != GuideCatalog.gameMenu.id else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard enabled, !seen.contains(id), !blocked, current == nil, let guide = GuideCatalog.guide(id) else { return }
            present(guide)
        }
    }

    /// The person asked for it (the question mark, Settings): shown whether or not it was seen before.
    func show(_ id: String) {
        guard current == nil, !blocked, let guide = GuideCatalog.guide(id) else { return }
        present(guide)
    }

    private func present(_ guide: Guide) {
        markSeen(guide.id)
        current = guide
    }
}
