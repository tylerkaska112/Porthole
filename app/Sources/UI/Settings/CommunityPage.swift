// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Settings > Help > Community and links: Porthole's accounts and pages (X, TikTok, Discord, GitHub, the website) and a way to tell a friend.
/// Each row opens the address in the browser or the app that owns it. Nothing is sent from the device.
struct CommunityPage: View {
    @State private var sharing = false

    var body: some View {
        PageScaffold(title: "Community and links", symbol: "person.3.fill", subtitle: "Where Porthole lives online") {
            ForEach(CommunityLinks.visible()) { section in
                SettingsGroup(title: section.title, note: section.note) {
                    ForEach(section.links) { link in
                        ActionRow(id: "cm-\(link.id)", symbol: link.symbol, title: link.title, subtitle: link.subtitle, chevron: false) {
                            if let url = link.url { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
            SettingsGroup(title: "Spread the word", note: "If Porthole works for you, a share helps other people find it.") {
                ActionRow(id: "cm-share", symbol: "square.and.arrow.up.fill", title: "Tell a friend", subtitle: "Share a link to the website", chevron: false) { sharing = true }
            }
        }
        .sheet(isPresented: $sharing) {
            ActivityView(items: [CommunityLinks.shareText] + [CommunityLinks.website].compactMap { $0 })
        }
    }
}
