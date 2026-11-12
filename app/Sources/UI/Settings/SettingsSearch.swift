// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What the search box in Settings looks through: every page, every page inside a page, every engine option (taken from the catalogue itself), and the rows people look for by name.
/// A search lands on the page that holds the setting. The list of rows is written by hand: when a row is added to a page that people might search for, add it here too.
enum SettingsIndex {
    struct Entry: Identifiable {
        let title: String
        let page: SettingsPage
        let sub: SettingsSub?
        /// Other words that find it.
        let keywords: String
        var id: String { "\(page.rawValue)|\(sub.map { String(describing: $0) } ?? "")|\(title)|\(keywords)" }

        /// "Advanced \u{203A} Engine options \u{203A} Memory".
        var path: String {
            var parts = [page.title]
            var chain: [String] = []
            var s = sub
            while let current = s { chain.insert(current.title, at: 0); s = current.parent }
            parts.append(contentsOf: chain)
            if parts.last == title { parts.removeLast() }
            // A row that is only shown when "Show technical options" is on says so.
            if keywords.contains("technical option") { parts.append("technical option") }
            return parts.joined(separator: " \u{203A} ")
        }
    }

    private static func row(_ title: String, _ page: SettingsPage, _ sub: SettingsSub? = nil, _ keywords: String = "") -> Entry {
        Entry(title: title, page: page, sub: sub, keywords: keywords)
    }

    static let entries: [Entry] = {
        var list: [Entry] = []
        for page in SettingsPage.allCases { list.append(row(page.title, page, nil, page.keywords)) }
        for store in GameStore.allCases { list.append(row(store.title, .stores, .store(store), "sign in account library games store")) }
        list.append(row("Engine options", .advanced, .engineGroups, "engine switches wine fex dxmt"))
        list.append(row("Changed from default", .advanced, .engineChanged, "reset modified"))
        list.append(row("Links and remote control", .advanced, .links, "porthole:// url shortcut"))
        list.append(row("Diagnostics", .advanced, .diagnostics, "log debug"))
        for group in EngineOptions.groups {
            list.append(row(group.title, .advanced, .engineGroup(group.title), "engine options"))
            for option in group.options { list.append(row(option.title, .advanced, .engineGroup(group.title), "engine option " + option.key)) }
        }
        list += [
            row("Resolution", .display, nil, "display screen size sharper picture"),
            row("Power mode", .performance, nil, "battery saver eco performance fps frame rate"),
            row("Keep my mode when hot", .performance, nil, "heat thermal temperature throttle"),
            row("Precise shader math", .performance, nil, "graphics lighting"),
            row("Swap", .performance, nil, "memory file out of memory jetsam crash"),
            row("Video memory", .performance, nil, "vram gpu"),
            row("Look sensitivity", .controls, nil, "mouse aim camera first person"),
            row("Audio buffer", .sound, nil, "sound crackle latency technical option"),
            row("Keep other apps' sound playing", .sound, nil, "music youtube video podcast spotify mix together second screen split view picture in picture"),
            row("Keep compiled pipelines between runs", .advanced, nil, "shader cache stutter pipeline archive pso first run"),
            row("Keep a game running in the background", .performance, nil, "background switch apps lock screen loading minutes keep alive"),
            row("Game volume", .sound, nil, "sound loud quiet gain boost audio"),
            row("Bring sound back after a call", .sound, nil, "sound audio interruption siri alarm phone resume silent technical option"),
            row("Connected controller", .controls, nil, "gamepad pad xbox playstation"),
            row("Back up saves", .saves, nil, "backup restore save files"),
            row("Back up after each game", .saves, nil, "automatic backup"),
            row("Clear temporary files", .storage, nil, "cache free space delete"),
            row("Free space", .storage, nil, "disk used by games size"),
            row("Steam client", .stores, .store(.steam), "valve download login"),
            row("Steam Cloud saves", .stores, .store(.steam), "cloud download saves"),
            row("SSD library folder", .stores, .store(.steam), "external drive storage ssd usb"),
            row("Steam games window", .stores, .store(.steam), "wine desktop display"),
            row("Sign out", .stores, nil, "log out account store"),
            row("JIT method", .jit, nil, "stikdebug helper pairing"),
            row("Pairing file", .jit, nil, "import jit idevice"),
            row("VPN and cellular options", .jit, .connectionExtras, "more tunnel vpn localdev cellular mobile data"),
            row("Use LocalDevVPN instead", .jit, .connectionExtras, "tunnel vpn localdev"),
            row("Your own VPN", .jit, .connectionExtras, "vpn shortcut pause"),
            row("Cellular data", .jit, .connectionExtras, "mobile data shortcut"),
            row("Reset the tunnel", .jit, nil, "troubleshooting connect"),
            row("Your install", .jit, nil, "signature extensions app ids entitlements install check"),
            row("Colour scheme", .appearance, nil, "theme colour accent dark light"),
            row("Festive themes", .appearance, nil, "holiday halloween christmas"),
            row("Glow", .appearance, nil, "light effects motion"),
            row("Moving background", .appearance, nil, "animation battery"),
            row("Check for updates", .updates, nil, "new version download install"),
            row("Certificate", .signing, nil, "signing p12 profile mobileprovision sign"),
            row("Older versions", .updates, .olderVersions, "versions downgrade older build go back"),
            row("Show technical options", .advanced, nil, "debug readouts"),
            row("Bigger code pool", .advanced, nil, "memory window"),
            row("Visual C++ runtime", .advanced, .components, "vcruntime redistributable dll download"),
            row(".NET Framework (Wine Mono)", .advanced, .components, "mono dotnet net celeste download"),
            row("32-bit Visual C++ runtime", .advanced, .components, "vc c++ runtime 32 bit x86 msvcp download"),
            row("Web pages in programs (Wine Gecko)", .advanced, .components, "gecko web html browser launcher installer mshtml download"),
            row("Ask before a link starts a game", .advanced, .links, "porthole url"),
            row("Allow remote-control links", .advanced, .links, "testing computer"),
            row("Read the log", .advanced, .diagnostics, "madeira-log text"),
            row("Save window pictures", .advanced, .diagnostics, "screenshots surfdump"),
            row("Wine debug channels", .advanced, .diagnostics, "winedebug +msg"),
            row("Look for known problems", .fixing, nil, "autofix automatic fix suggestions"),
            row("Ask me before changing a game", .fixing, nil, "autofix apply undo"),
            row("What was changed", .fixing, nil, "autofix history undo"),
            row("Controller rumble", .controls, nil, "vibration haptics motors gamepad"),
            row("Test controller rumble", .controls, nil, "vibration buzz"),
            row("Open the menu with the controller", .controls, nil, "pad menu button chord"),
            row("Controller as keyboard and mouse", .controls, nil, "pad kbm pointer"),
            row("Pointer for the controller", .controls, nil, "pad cursor stick mouse"),
            row("Hide on-screen controls when a controller is used", .controls, nil, "touch controls hide"),
            row("Mouse speed", .controls, nil, "mouse sensitivity camera"),
            row("Always use the mouse to look", .controls, nil, "mouse look relative camera"),
            row("Scroll direction", .controls, nil, "wheel scroll reversed natural"),
            row("Hold a key to repeat it", .controls, nil, "key repeat keyboard"),
            row("Keyboard layout for typing", .controls, nil, "keys letters layout"),
            row("Keys for Porthole", .controls, nil, "menu key lock pointer shortcut ctrl alt"),
            row("Fewer keys on the on-screen keyboard", .controls, nil, "keyboard function row compact"),
            row("Send controllers to games", .controls, nil, "xinput controller technical option"),
            row("Controller type for player 1", .controls, nil, "xbox playstation pad mode technical option"),
            row("Show compatibility badges", .reports, nil, "reports ratings"),
            row("Ask me how a game ran", .reports, nil, "survey prompt"),
            row("My reports", .reports, nil, "delete sent"),
            row("Forget my reporting identity", .reports, nil, "privacy key"),
            row("Setup guide", .guides, nil, "first run walk-through"),
            row("Tips and guides", .guides, nil, "help explanations"),
            row("Version", .about, nil, "about build number"),
            row("Licences and credits", .about, nil, "open source source code gpl credits madeira iridium stikdebug idevice"),
            row("Bundle", .about, nil, "bundle id identifier technical option"),
            row("Report a problem", .report, nil, "bug log send feedback"),
        ]
        return list
    }()

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Entries whose name, path or keywords contain every word typed, best matches first (a name that starts with the text, then one that contains it).
    static func search(_ query: String, limit: Int = 30) -> [Entry] {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(Entry, Int)] = []
        for entry in entries {
            let title = fold(entry.title), rest = fold(entry.path + " " + entry.keywords)
            guard words.allSatisfy({ title.contains($0) || rest.contains($0) }) else { continue }
            var score = 0
            if title.hasPrefix(words[0]) { score += 3 } else if title.contains(words[0]) { score += 2 }
            if words.allSatisfy({ title.contains($0) }) { score += 2 }
            if entry.sub == nil { score += 1 }
            scored.append((entry, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

extension SettingsPage {
    /// Extra words that find the page itself.
    var keywords: String {
        switch self {
        case .display: "screen resolution picture size"
        case .performance: "speed power battery memory swap shader fps"
        case .sound: "audio volume music speaker"
        case .controls: "controller gamepad keyboard mouse touch trackpad rumble input keys look sensitivity"
        case .saves: "backup restore"
        case .storage: "space delete cache"
        case .stores: "accounts steam epic gog itch amazon ea sign in"
        case .jit: "tunnel vpn pairing connection"
        case .appearance: "theme colour look"
        case .updates: "version downgrade older builds"
        case .signing: "certificate profile p12 mobileprovision sideload"
        case .advanced: "engine components developer"
        case .reports: "compatibility badges"
        case .fixing: "autofix automatic fixes known problems"
        case .guides: "setup tips help walk-through first run"
        case .about: "version build credits licences source"
        case .report: "bug problem log"
        }
    }
}
