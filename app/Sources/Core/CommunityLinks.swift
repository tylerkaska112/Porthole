// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Where Porthole lives online: the accounts and pages Settings > Community and links opens. Foundation only, so a host test can check it.
/// To add an account: add one `Link` to the right section. A link whose address is nil (an account that does not exist yet) is not shown at all.
enum CommunityLinks {
    struct Link: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let url: URL?
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let note: String?
        let links: [Link]
        var id: String { title }
    }

    static let website = URL(string: "https://portholehq.site")
    static let x = URL(string: "https://x.com/portholehq")
    static let discord = URL(string: "https://discord.gg/N7PkdptTFn")
    static let github = URL(string: "https://github.com/tylerkaska112/Porthole")
    /// Not created yet: put the address here when the account exists and the row appears by itself.
    static let tiktok: URL? = nil

    /// What the Share row hands to the share sheet.
    static let shareText = "Porthole runs Windows PC games on iPhone and iPad."

    /// Every section as designed, including links that have no address yet.
    static let all: [Section] = [
        Section(title: "Follow Porthole", note: "News, new versions and clips of games running.", links: [
            Link(id: "x", title: "X", subtitle: "@portholehq", symbol: "megaphone.fill", url: x),
            Link(id: "tiktok", title: "TikTok", subtitle: "Short videos of games running on a phone", symbol: "play.rectangle.fill", url: tiktok),
        ]),
        Section(title: "Talk to people", note: "Ask for help, say what works for you, or report a bug.", links: [
            Link(id: "discord", title: "Discord", subtitle: "Chat with players, and ask for help", symbol: "bubble.left.and.bubble.right.fill", url: discord),
            Link(id: "github", title: "GitHub", subtitle: "The source code, and bug reports", symbol: "chevron.left.forwardslash.chevron.right", url: github),
        ]),
        Section(title: "Read", note: nil, links: [
            Link(id: "website", title: "Website", subtitle: "portholehq.site", symbol: "globe", url: website),
            Link(id: "docs", title: "Documentation", subtitle: "Every setting and message explained", symbol: "book.fill", url: URL(string: "https://portholehq.site/docs/")),
            Link(id: "compat", title: "Compatibility list", subtitle: "How games run for other people", symbol: "checkmark.seal.fill", url: URL(string: "https://portholehq.site/compat.html")),
            Link(id: "changelog", title: "What's new", subtitle: "The changes in each version", symbol: "sparkles", url: URL(string: "https://portholehq.site/changelog.html")),
            Link(id: "privacy", title: "Privacy", subtitle: "What Porthole sends and stores", symbol: "hand.raised.fill", url: URL(string: "https://portholehq.site/privacy.html")),
        ]),
    ]

    /// The sections to show: links without an address are left out, and a section with nothing left disappears.
    static func visible(_ sections: [Section] = all) -> [Section] {
        sections.compactMap { section in
            let links = section.links.filter { $0.url != nil }
            return links.isEmpty ? nil : Section(title: section.title, note: section.note, links: links)
        }
    }
}
