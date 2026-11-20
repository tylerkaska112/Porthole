// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The interactive tutorials: what each one points at, says, and how it gets the person from screen to screen. The engine is Kit/CoachMarks.swift; this file is only content and the app's
/// own navigation (tabs, Settings pages, the Add a game sheet, a game's page, the in-game menu).
///
/// A step points at something by its name: every row and button that the controller can reach already has one (its `focusTarget` id), the top tabs and the in-game menu's tabs are named
/// `tab-<id>` and `menu-tab-<id>`. A step that uses the thing (`.tap`) moves on a moment after the person taps it, and the next step waits for its own target to appear, so a tap that opens
/// a page or a sheet needs no code of its own.
@MainActor
final class TutorialLibrary {
    static let shared = TutorialLibrary()
    private weak var router: AppRouter?
    private weak var model: AppModel?
    private weak var session: SessionController?
    private static let menuOfferedKey = "f4.coach.menuOffered"
    private static let menuNextKey = "f4.coach.menuNext"

    private init() {}

    func attach(router: AppRouter, model: AppModel, session: SessionController) {
        self.router = router; self.model = model; self.session = session
        Coach.shared.onEvent = { LogStore.shared.log($0) }
        Coach.shared.onFinish = { [weak self] t, _ in self?.returnToTutorials(after: t) }
    }

    // MARK: Starting

    func tutorial(_ id: String) -> CoachTutorial? { all.first { $0.id == id } }

    /// The tutorial for a screen's help (the question mark, a guide's "Walk me through it").
    func tutorialID(forGuide guide: String) -> String? {
        switch guide {
        case "home": "add-game"
        case "stores": "store-signin"
        case "settings": "tour"
        case "gamepage": "play"
        case "addgame": "add-game"
        case "menu", "ingame": "game-menu"
        default: nil
        }
    }

    /// A line to show the person after `start` (the game menu tour waits for the next game), nil when the tutorial simply began.
    private(set) var notice: String?

    @discardableResult
    func start(_ id: String) -> Bool {
        notice = nil
        guard let t = tutorial(id) else { return false }
        // The menu tour points at a running game's menu, so with no game running it waits: the next game that starts begins it.
        if id == "game-menu", session?.isActive != true {
            UserDefaults.standard.set(true, forKey: Self.menuNextKey)
            notice = "Ready. The menu tour will start by itself the next time you launch a game, a few seconds after its picture appears."
            return false
        }
        return Coach.shared.start(t)
    }

    /// The first game ever started: once it is running, the in-game menu tutorial offers itself. Tips off, or already done, and it stays quiet.
    func gameStarted() {
        let d = UserDefaults.standard
        // Asked for from the list of tutorials: it runs on the next game whatever the tips setting or an earlier run says.
        let asked = d.bool(forKey: Self.menuNextKey)
        guard asked || (GuideCenter.shared.enabled && !d.bool(forKey: Self.menuOfferedKey) && !Coach.shared.isDone("game-menu")), !Coach.shared.isActive else { return }
        d.set(true, forKey: Self.menuOfferedKey); d.set(false, forKey: Self.menuNextKey)
        GuideCenter.shared.markSeen(GuideCatalog.gameMenu.id)       // the menu's own first-open tip says the same, so only one of them shows
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))                 // the game has its first frames up
            guard self.session?.isActive == true, !Coach.shared.isActive else { return }
            self.start("game-menu")
        }
    }

    /// When a tutorial ends (finished or closed with the cross) the person lands on the list of tutorials, to pick the next one or stop. Not for the game menu tour: it runs over a game.
    private func returnToTutorials(after t: CoachTutorial) {
        guard t.id != "game-menu", session?.isActive != true, let router else { return }
        router.showAdd = false
        router.homePath = NavigationPath()
        router.openSettings(.guides)
    }

    // MARK: Helpers for steps

    private var hasGames: Bool { !(model?.games.isEmpty ?? true) }
    private var gameCards: [String] { (model?.games ?? []).map { $0.id.uuidString } }
    private func tab(_ t: AppTab) -> Bool { router?.tab == t }
    private func has(_ id: String) -> Bool { CoachAnchors.shared.exists([id]) }

    private func goHome() { router?.homePath = NavigationPath(); router?.tab = .library }
    private func goSettingsList() { router?.tab = .settings; router?.settingsSub = nil; router?.settingsSelection = nil }
    private func goStoresList() { router?.openStores() }
    private func needGame() -> String? { hasGames ? nil : "Add a game first (the Add a game tutorial shows how)." }

    // MARK: The tutorials

    var all: [CoachTutorial] { [tour, addGame, storeSignIn, installFromStore, play, swap, controls, jit, saves, gameMenu] }

    /// Every tab, in a sentence.
    private var tour: CoachTutorial {
        CoachTutorial(id: "tour", title: "Find your way around", symbol: "map.fill", summary: "What each tab is for, and where things live.", steps: [
            CoachStep(id: "intro", title: "Welcome aboard", text: "I'll point at things and say what they do. When something glows, tap it yourself and I'll move on, or press Next. The cross in the corner ends the tour any time."),
            CoachStep(id: "home", anchors: ["tab-home"], title: "Home", text: "Your games live here. Tap a game to open its page; Play starts it. Notices appear above the games when something needs you: JIT waiting, an update, a download.",
                      advance: .tapOrNext, shape: .capsule),
            CoachStep(id: "stores", anchors: ["tab-stores"], title: "Stores", text: "Sign in to Steam, Epic Games, GOG, itch.io, Amazon Games or the EA app, and download the games you own straight to this device.",
                      advance: .tapOrNext, shape: .capsule),
            CoachStep(id: "reports", anchors: ["tab-reports"], title: "Reports", text: "What other people found when they played a game on devices like yours: which settings work, and how it runs. You can send your own after you play.",
                      advance: .tapOrNext, shape: .capsule),
            CoachStep(id: "social", anchors: ["tab-social"], title: "Social", text: "Discord (experimental, off until you turn it on) and your Steam friends: who is online and what they are playing.",
                      advance: .tapOrNext, shape: .capsule),
            CoachStep(id: "settings", anchors: ["tab-settings"], title: "Settings", text: "Everything about how the app runs: display, performance, sound, controls, your store accounts, saves, storage and the connection that lets games run fast. Search at the top finds any setting by name.",
                      advance: .tapOrNext, shape: .capsule),
            CoachStep(id: "help", anchors: ["shell-help"], title: "The question mark", text: "Explains whichever screen you are on. It is always there if you forget what something does.", advance: .next, shape: .circle),
            CoachStep(id: "end", title: "That's the map", text: "There is a tutorial for each everyday job (adding a game, signing in to a store, turning on swap and more). They are all in Settings, under Setup, tutorials and tips."),
        ], minutes: 1)
    }

    private var addGame: CoachTutorial {
        CoachTutorial(id: "add-game", title: "Add a game", symbol: "plus.circle.fill", summary: "Bring in a game from Files, a store or an installer.", steps: [
            CoachStep(id: "open", anchors: ["add-game"], title: "Add a game", text: "This opens the list of places a game can come from.", advance: .tap,
                      ensure: { self.goHome() }, prompt: "Tap Add a game"),
            CoachStep(id: "folder", anchors: ["add-folder"], title: "A game folder from Files", text: "If you already have a Windows game on this device, in Files or on an external drive, open its folder and tap Open. Porthole copies it in and finds the program to run.",
                      ensure: { self.router?.showAdd = true }),
            CoachStep(id: "stores", anchors: ["add-steam"], title: "Download from a store", text: "Games you own on Steam, Epic Games, GOG, itch.io, Amazon Games or the EA app are downloaded straight to this device. You sign in on Epic's, GOG's and most other stores' own pages, so Porthole never sees those passwords. Steam's password is encrypted before it leaves this device.",
                      points: [CoachPoint(symbol: "person.badge.key.fill", text: "First time: you will be asked to sign in (the Sign in to a store tutorial shows how)."),
                               CoachPoint(symbol: "arrow.down.circle.fill", text: "After that, pick a game from your library and install it.")],
                      ensure: { self.router?.showAdd = true }),
            CoachStep(id: "installer", anchors: ["add-installer"], title: "Run a Windows installer", text: "For a game on a disc or in a setup file: Porthole runs the installer inside its own Windows drive. When it finishes, add what it installed.",
                      ensure: { self.router?.showAdd = true }),
            CoachStep(id: "path", anchors: ["add-path-toggle"], title: "Add by path", text: "If you know where a program sits on the Windows drive, such as C:\\Games\\Foo\\foo.exe, you can type it here.",
                      ensure: { self.router?.showAdd = true }),
            CoachStep(id: "end", title: "Pick one", text: "Choose the way that fits your game. Games Porthole already finds in its own folders are listed under Already in the app. A new game appears on Home when it is added."),
        ], minutes: 2)
    }

    private var storeSignIn: CoachTutorial {
        CoachTutorial(id: "store-signin", title: "Sign in to a store", symbol: "person.badge.key.fill", summary: "Steam first; the other stores work the same way.", steps: [
            CoachStep(id: "tab", anchors: ["tab-stores"], title: "Open Stores", text: "Every store you can use is here.", advance: .until({ self.tab(.stores) }), shape: .capsule, prompt: "Tap Stores"),
            CoachStep(id: "steam", anchors: ["store-steam"], title: "Steam", text: "Each store has a tile. Tap Steam to open your Steam library; it asks you to sign in the first time.",
                      advance: .until({ self.router?.storesSelection == .store(.steam) }), ensure: { self.goStoresList() }),
            CoachStep(id: "how", anchors: ["ss-qr"], title: "Two ways to sign in", text: "You can scan a QR code with the Steam Mobile app, or type your account name and password. This button switches between them.",
                      skipIf: { SteamStore.shared.signedIn }),
            CoachStep(id: "account", anchors: ["ss-account"], title: "Account name", text: "Type your Steam account name here. Tap the field to start. I will not see what you type.", advance: .next,
                      skipIf: { SteamStore.shared.signedIn || !self.has("ss-account") }, interactive: true),
            CoachStep(id: "password", anchors: ["ss-password"], title: "Password", text: "Your password is encrypted before it leaves this device and goes only to Steam.", advance: .next,
                      skipIf: { SteamStore.shared.signedIn || !self.has("ss-password") }, interactive: true),
            CoachStep(id: "go", anchors: ["ss-go"], title: "Sign in", text: "Press this when both boxes are filled in.", advance: .tapOrNext, skipIf: { SteamStore.shared.signedIn || !self.has("ss-go") }),
            CoachStep(id: "guard", title: "Steam Guard", text: "Steam may ask for a code. Approve the sign-in in the Steam Mobile app, or type the code Steam sends you into the box that appears, then press Submit code.",
                      skipIf: { SteamStore.shared.signedIn }),
            CoachStep(id: "end", title: "You're signed in", text: "Your Steam games are listed on this page. The other stores (Epic Games, GOG, itch.io, Amazon Games, EA) work the same way: open their tile and press Sign in. You sign in on each store's own page."),
        ], minutes: 2)
    }

    private var installFromStore: CoachTutorial {
        CoachTutorial(id: "install-game", title: "Install a game from Steam", symbol: "arrow.down.circle.fill", summary: "Find a game in your library and download it.",
                      steps: [
            CoachStep(id: "page", anchors: ["store-steam"], title: "Open your Steam library", text: "Tap Steam in Stores.", advance: .until({ self.router?.storesSelection == .store(.steam) }),
                      ensure: { self.router?.tab = .stores; self.goStoresList() },
                      skipIf: { self.router?.tab == .stores && self.router?.storesSelection == .store(.steam) }),
            CoachStep(id: "search", anchors: ["so-search"], title: "Search", text: "Type part of a game's name to find it in your library.", advance: .next, interactive: true),
            CoachStep(id: "filters", anchors: ["so-sort"], title: "Sort and filter", text: "Sort the list, show only what is installed, or select several games to download together.", advance: .next, shape: .circle),
            CoachStep(id: "game", anchors: ["sg-*"], title: "Open a game", text: "Tap a game to see its page: what it is, how it runs for others, and the Install button.", advance: .tap, prompt: "Tap a game"),
            CoachStep(id: "install", anchors: ["sp-main"], title: "Install", text: "This downloads the game to this device. It shows its progress here, on Home and under Downloads. You can pause it, and you can leave the app on the Downloads page while it works.",
                      advance: .next),
            CoachStep(id: "end", title: "That's all", text: "When the download ends, the game is added to Home and is ready to play. Stores > Downloads lists everything being installed."),
        ], minutes: 2)
    }

    private var play: CoachTutorial {
        CoachTutorial(id: "play", title: "Play a game and tune it", symbol: "play.fill", summary: "A game's page: Play, its own settings, its controls.",
                      unavailable: { self.needGame() }, steps: [
            CoachStep(id: "card", anchors: gameCards, title: "Open a game", text: "Tap the first game in the list, the one you played last, to open its page.", advance: .until({ !(self.router?.homePath.isEmpty ?? true) }),
                      ensure: { self.goHome() }, prompt: "Tap the first game", topmost: true),
            CoachStep(id: "play", anchors: ["gp-play"], title: "Play", text: "Starts the game. The first start takes longer: Porthole switches JIT on first, then launches, and some games prepare their graphics as they run.", advance: .next),
            CoachStep(id: "res", anchors: ["gp-res"], title: "This game's settings", text: "Resolution, orientation, power mode and more apply to this game only. A row that says Default follows what you set in Settings; tap a row to give this game its own value.",
                      advance: .next, skipIf: { !self.has("gp-res") }),
            CoachStep(id: "controls", anchors: ["gp-door-controls"], title: "Controls and key binds", text: "How touch works for this game: the layout in use, a preview you can try, and your sets of binds. Inside the game, the pencil edits the controls.", advance: .next),
            CoachStep(id: "more", anchors: ["gp-door-more"], title: "More options", text: "Speed, memory, engine and launch options. Swap lives here: the next tutorial shows it.", advance: .next),
            CoachStep(id: "end", title: "Ready", text: "Press Play whenever you like. Swipe in from the right edge of the screen during a game to open its menu."),
        ], minutes: 2)
    }

    private var swap: CoachTutorial {
        CoachTutorial(id: "swap", title: "Turn on swap", symbol: "internaldrive.fill", summary: "Give a game more memory by using storage when it closes or stutters.",
                      unavailable: { self.needGame() }, steps: [
            CoachStep(id: "card", anchors: gameCards, title: "Open the game", text: "Swap is set for each game. Tap the first game in the list, or scroll to the one that closes or stutters.", advance: .tap,
                      ensure: { self.goHome() }, skipIf: { !(self.router?.homePath.isEmpty ?? true) }, prompt: "Tap the game", topmost: true),
            CoachStep(id: "more", anchors: ["gp-door-more"], title: "More options", text: "Memory settings are on this page.", advance: .tap, prompt: "Tap More options"),
            CoachStep(id: "swap", anchors: ["gp-swap"], title: "Swap", text: "iOS closes an app that uses too much memory. Swap lets Porthole use storage as extra memory. If a game closes by itself or stutters, give it more swap. Default follows Settings; tap here to choose a size for this game only.",
                      advance: .tap, prompt: "Tap Swap"),
            CoachStep(id: "choose", anchors: ["choice-*"], title: "Pick a size", text: "Off, or from 1 GB up to 4 GB. A bigger swap helps a game that runs out of memory. Tap a size to choose it; the game uses it from its next start.",
                      points: [CoachPoint(symbol: "arrow.clockwise", text: "Applies the next time the game starts."), CoachPoint(symbol: "arrow.up.circle.fill", text: "If it still closes, try the next size up.")],
                      advance: .tapOrNext, side: .above, prompt: "Tap a size", group: true),
            CoachStep(id: "end", title: "Done", text: "Start the game again to use it. A game that still closes may simply need more memory than this device has."),
        ], minutes: 1)
    }

    private var controls: CoachTutorial {
        CoachTutorial(id: "controls", title: "Set up your controls", symbol: "gamecontroller.fill", summary: "Choose the controls every game starts with, and how big the buttons are.", steps: [
            CoachStep(id: "tab", anchors: ["tab-settings"], title: "Open Settings", text: "Controls are in Settings.", advance: .until({ self.tab(.settings) }), shape: .capsule, prompt: "Tap Settings"),
            CoachStep(id: "page", anchors: ["set-controls"], title: "Controls", text: "How games are controlled, and the settings for each kind of input.", advance: .until({ self.router?.settingsSelection == .controls }),
                      ensure: { self.goSettingsList() }),
            CoachStep(id: "cards", anchors: ["dc-universal"], title: "Default controls", text: "Every game starts with the controls you pick here, unless you set up controls for that one game.",
                      points: [CoachPoint(symbol: "keyboard", text: "Universal: W A S D, mouse buttons, keys and a Look switch."),
                               CoachPoint(symbol: "gamecontroller.fill", text: "On-screen controller: a console pad drawn on the screen."),
                               CoachPoint(symbol: "rectangle.grid.2x2", text: "Gamepad layout: gamepad buttons you can move and resize."),
                               CoachPoint(symbol: "star.fill", text: "My own layout: one you saved from a game's menu.")], advance: .next),
            CoachStep(id: "try", anchors: ["dc-try"], title: "Try it", text: "Opens a practice screen: press the buttons and feel the layout. Nothing there reaches a game. Edit lets you move and resize the buttons.",
                      advance: .next, skipIf: { !self.has("dc-try") }),
            CoachStep(id: "touch", anchors: ["ct-door-touch"], title: "Touch screen", text: "Button size, left-handed layouts and look sensitivity.", advance: .until({ self.router?.settingsSub == .controlsTouch }), prompt: "Tap Touch screen"),
            CoachStep(id: "size", anchors: ["ct-button-size"], title: "Button size", text: "How big the on-screen buttons are drawn on this device. Automatic makes them a little larger on an iPad. Try a bigger size if buttons are hard to hit.", advance: .next),
            CoachStep(id: "left", anchors: ["ct-left-handed"], title: "Left-handed", text: "Shows every layout flipped left to right, so the stick and the buttons swap hands. Nothing in a layout is changed: switch it off and they are back.", advance: .next),
            CoachStep(id: "end", title: "Done", text: "A single game can have its own controls: open the game's page, then Controls and key binds. In a game, the pencil edits them."),
        ], minutes: 2)
    }

    private var jit: CoachTutorial {
        CoachTutorial(id: "jit", title: "Get JIT working", symbol: "bolt.horizontal.fill", summary: "The connection that lets games run at full speed.", steps: [
            CoachStep(id: "tab", anchors: ["tab-settings"], title: "Open Settings", text: "The connection settings are in Settings.", advance: .until({ self.tab(.settings) }), shape: .capsule, prompt: "Tap Settings"),
            CoachStep(id: "page", anchors: ["set-jit"], title: "JIT and connection", text: "iOS keeps a speed feature called JIT switched off. Games need it, so something has to switch it on each time you play. If a game will not start, look here first.",
                      advance: .until({ self.router?.settingsSelection == .jit }), ensure: { self.goSettingsList() }),
            CoachStep(id: "method", anchors: ["cn-method"], title: "JIT method", text: "Who switches JIT on: Porthole itself (the simplest, and what most people use), the StikDebug app, or another tool.", advance: .next),
            CoachStep(id: "pair", anchors: ["cn-pair-import", "cn-pair-here", "cn-pair-state"], title: "Pairing file", text: "Porthole needs a pairing file for this device to switch JIT on by itself. It shows Imported when you have one; otherwise create it on this device, or import one made on a computer.",
                      advance: .next),
            CoachStep(id: "localdev", anchors: ["cn-localdev"], title: "LocalDevVPN", text: "If this install has no private link of its own, turn this on and use the free LocalDevVPN app: switch it on before you press Play and leave it on while the game runs.", advance: .next,
                      skipIf: { !self.has("cn-localdev") }),
            CoachStep(id: "status", anchors: ["cn-jit"], title: "Where it stands", text: "Shows whether JIT is enabled right now. It is switched on when you press Play, so Not enabled here is normal before a game starts.", advance: .next, skipIf: { !self.has("cn-jit") }),
            CoachStep(id: "end", title: "Done", text: "With a pairing file and a connection chosen, press Play on a game. If it stops with a JIT message, the message says what to do."),
        ], minutes: 2)
    }

    private var saves: CoachTutorial {
        CoachTutorial(id: "saves", title: "Back up your saves", symbol: "externaldrive.fill.badge.timemachine", summary: "Keep your saves safe, and bring them back.", steps: [
            CoachStep(id: "tab", anchors: ["tab-settings"], title: "Open Settings", text: "Backups are in Settings.", advance: .until({ self.tab(.settings) }), shape: .capsule, prompt: "Tap Settings"),
            CoachStep(id: "page", anchors: ["set-saves"], title: "Saves", text: "Backups and restores of your game saves.", advance: .until({ self.router?.settingsSelection == .saves }), ensure: { self.goSettingsList() }),
            CoachStep(id: "backup", anchors: ["sv-backup"], title: "Back up now", text: "Puts every game's saves and settings in one zip file that you can keep in Files, or send somewhere safe.", advance: .next),
            CoachStep(id: "auto", anchors: ["sv-auto"], title: "Back up after each game", text: "On: when a game ends, its saves are zipped into Files > Porthole > Saves backups, and the newest five are kept. Nothing is written when nothing has changed.",
                      advance: .tapOrNext, prompt: "Switch it on if you want it"),
            CoachStep(id: "restore", anchors: ["sv-restore"], title: "Restore", text: "Pick a backup and its files are copied back into place. Files with the same names are overwritten.", advance: .next),
            CoachStep(id: "end", title: "Done", text: "Steam games can also keep saves in Steam Cloud. A game's page has a Steam Cloud card when you are signed in."),
        ], minutes: 1)
    }

    /// The in-game menu, on a running game. It starts by itself the first time a game runs.
    private var gameMenu: CoachTutorial {
        CoachTutorial(id: "game-menu", title: "The game menu", symbol: "line.3.horizontal", summary: "What each tab of the in-game menu does. Starts by itself the first time a game runs.",
                      steps: [
            CoachStep(id: "open", title: "Open the menu", text: "Swipe in from the right edge of the screen, or tap the handle on the edge. The game keeps running behind the menu.", advance: .until({ NavHub.shared.gameMenuOpen }),
                      swipeFrom: .trailing, prompt: "Swipe in from the right edge", blocks: false),
            CoachStep(id: "size", anchors: ["menu-size"], title: "Make it any size", text: "On an iPad this makes the menu much wider; tap it again to bring it back. You can also drag the handle on the menu's left edge to any width you like, and the menu remembers it. Drag the handle all the way in to close the menu.",
                      advance: .next, skipIf: { !self.has("menu-size") }, shape: .circle),
            CoachStep(id: "tab-perf", anchors: ["menu-tab-performance"], title: "Performance", text: "Power mode, the performance overlay and how the device is coping. Open this when a game runs slowly or the device gets hot.", advance: .tap, shape: .rounded, prompt: "Tap Performance"),
            CoachStep(id: "power", anchors: ["nav:power"], title: "Power", text: "How fast the game runs against battery and heat: Performance, Balanced, Battery saver or Auto. Eco mode plays on the efficiency cores: cooler and longer battery, slower.", advance: .next),
            CoachStep(id: "overlay", anchors: ["toggle:Performance overlay"], title: "Performance overlay", text: "Shows frames per second and more on top of the game. It is off until you turn it on; Overlay details chooses what it shows.", advance: .next),
            CoachStep(id: "tab-controls", anchors: ["menu-tab-controls"], title: "Controls", text: "How touch works for this game, whether the on-screen controls show, the keyboard and the pencil that edits the controls.", advance: .tap, prompt: "Tap Controls"),
            CoachStep(id: "layouts", anchors: ["layout-chip:*"], title: "Layouts", text: "Tap a layout to switch this game to it. + New starts another from a template. Your other layouts are kept.", advance: .next, skipIf: { !self.has("layout-chip:new") }),
            CoachStep(id: "left", anchors: ["toggle:Left-handed"], title: "Left-handed", text: "Flips every layout left to right, so the stick and the buttons swap hands.", advance: .next, skipIf: { !self.has("toggle:Left-handed") }),
            CoachStep(id: "show", anchors: ["toggle:Show controls"], title: "Show controls", text: "Hides or shows the on-screen controls. With a controller connected they hide by themselves.", advance: .next, skipIf: { !self.has("toggle:Show controls") }),
            CoachStep(id: "keyboard", anchors: ["action:Keyboard"], title: "Keyboard", text: "Brings up the on-screen keyboard when a game wants you to type. Full keyboard has every key: F keys, arrows, Ctrl, Alt and Shift.", advance: .next, skipIf: { !self.has("action:Keyboard") }),
            CoachStep(id: "edit", anchors: ["action:Edit on-screen controls"], title: "Edit the controls", text: "Move, resize and add buttons right on the game. The pencil at the top of the screen does the same.", advance: .next, skipIf: { !self.has("action:Edit on-screen controls") }),
            CoachStep(id: "tab-game", anchors: ["menu-tab-game"], title: "Game", text: "Reporting how the game runs, tools, the edge handle and closing the game.", advance: .tap, prompt: "Tap Game"),
            CoachStep(id: "report", anchors: ["action:Report how it runs"], title: "Report how it runs", text: "Tell other players how this game works on your device. It takes under a minute and helps the next person.", advance: .next, skipIf: { !self.has("action:Report how it runs") }),
            CoachStep(id: "capture", anchors: ["action:Capture the next frame"], title: "Capture a frame", text: "Saves the next frame the game draws, for a bug report when something looks wrong.", advance: .next, skipIf: { !self.has("action:Capture the next frame") }),
            CoachStep(id: "handle", anchors: ["nav:handle"], title: "Edge handle", text: "The small handle on the right edge that you can tap to open this menu. Here you can change how it looks or hide it; the swipe from the edge always works.", advance: .next, skipIf: { !self.has("nav:handle") }),
            CoachStep(id: "close", anchors: ["action:Close game"], title: "Close game", text: "Ends the game and returns to Porthole. Restart game closes the game and Porthole, and starts it again when you reopen Porthole.", advance: .next, skipIf: { !self.has("action:Close game") }),
            CoachStep(id: "end", title: "That's the menu", text: "Press Close (on an iPad also the handle on the menu's edge), or swipe the menu to the right, to close it and keep playing. You can run this tour again from Settings > Setup, tutorials and tips, or from this menu's Game tab."),
        ], minutes: 2)
    }
}
