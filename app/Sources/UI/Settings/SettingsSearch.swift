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
            row("Resolution", .play, nil, "display screen size sharper picture"),
            row("Power mode", .play, nil, "battery saver eco performance fps frame rate"),
            row("Keep my mode when hot", .play, nil, "heat thermal temperature throttle"),
            row("Precise shader math", .play, nil, "graphics lighting"),
            row("Swap", .play, nil, "memory file out of memory jetsam crash"),
            row("Video memory", .play, nil, "vram gpu"),
            row("Look sensitivity", .play, nil, "mouse aim camera first person"),
            row("Audio buffer", .play, nil, "sound crackle latency"),
            row("Keep compiled pipelines between runs", .advanced, nil, "shader cache stutter pipeline archive pso first run"),
            row("Keep a game running in the background", .play, nil, "background switch apps lock screen loading minutes keep alive"),
            row("Game volume", .play, nil, "sound loud quiet gain boost audio"),
            row("Bring sound back after a call", .play, nil, "sound audio interruption siri alarm phone resume silent"),
            row("Connected controller", .play, nil, "gamepad pad xbox playstation"),
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
            row("Use LocalDevVPN instead", .jit, nil, "tunnel vpn localdev"),
            row("Your own VPN", .jit, nil, "vpn shortcut pause"),
            row("Cellular data", .jit, nil, "mobile data shortcut"),
            row("Reset the tunnel", .jit, nil, "troubleshooting connect"),
            row("Your install", .jit, nil, "signature extensions app ids entitlements install check"),
            row("Colour scheme", .appearance, nil, "theme colour accent dark light"),
            row("Festive themes", .appearance, nil, "holiday halloween christmas"),
            row("Glow", .appearance, nil, "light effects motion"),
            row("Moving background", .appearance, nil, "animation battery"),
            row("Check for updates", .updates, nil, "new version download install"),
            row("Certificate", .updates, nil, "signing p12 profile mobileprovision sign"),
            row("Versions", .updates, nil, "downgrade older build"),
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
            row("Show compatibility badges", .reports, nil, "reports ratings"),
            row("Ask me how a game ran", .reports, nil, "survey prompt"),
            row("My reports", .reports, nil, "delete sent"),
            row("Forget my reporting identity", .reports, nil, "privacy key"),
            row("Setup guide", .help, nil, "first run walk-through"),
            row("Tips and guides", .help, nil, "help explanations"),
            row("Version", .help, nil, "about build number"),
            row("Licences and source code", .help, nil, "open source gpl credits"),
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
        case .play: "display performance sound controls resolution"
        case .saves: "backup restore"
        case .storage: "space delete cache"
        case .stores: "accounts steam epic gog itch amazon ea sign in"
        case .jit: "tunnel vpn pairing connection"
        case .appearance: "theme colour look"
        case .updates: "version signing certificate"
        case .advanced: "engine components developer"
        case .reports: "compatibility badges"
        case .help: "about setup tips credits licences"
        case .report: "bug problem log"
        }
    }
}
