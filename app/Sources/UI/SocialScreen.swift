// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// What the Social tab can show. Discord first; Steam holds the friends list now and later its messages and groups.
enum SocialSection: String, CaseIterable, Identifiable {
    case discord, steam
    var id: String { rawValue }
    var title: String { switch self { case .discord: "Discord"; case .steam: "Steam" } }
}

/// The Social tab: the people you play with, wherever they are. A switch at the top chooses Discord (experimental: Discord itself once you are signed in, with its settings behind
/// a gear; the sign-in page before that) or Steam (the friends list; messages and groups are meant to follow).
struct SocialScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.focusScope) private var scope
    @AppStorage("f4.socialSection") private var saved = SocialSection.discord.rawValue
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var discord = DiscordSession.shared
    @State private var showSettings = false
    @Environment(\.verticalSizeClass) private var vertical

    private var discordFillsTab: Bool { section == .discord && discord.enabled && discord.state == .connected }
    private var section: SocialSection { SocialSection(rawValue: saved) ?? .discord }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !discordFillsTab || vertical != .compact {
                HStack(spacing: 14) {
                    SegmentedPills(options: SocialSection.allCases.map { .init(id: $0.rawValue, title: $0.title) }, selection: section.rawValue) { saved = $0 }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
            }
            if discordFillsTab {
                // Discord itself, filling the tab; its settings are behind the gear.
                // Held sideways the switch above is hidden to give the chat the room; the rail has a small button for Steam instead.
                DiscordBrowserScreen(embedded: true, settings: { showSettings = true },
                                     otherSection: vertical == .compact ? (title: SocialSection.steam.title, go: { saved = SocialSection.steam.rawValue }) : nil)
            } else {
                FocusScroll {
                    Group {
                        switch section {
                        case .discord: DiscordPage().environment(\.embeddedPage, true)
                        case .steam: steamSection
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 8).padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showSettings) { DiscordSettingsSheet() }
        .onAppear {
            if let asked = router.socialSection { saved = asked.rawValue; router.socialSection = nil }
            scope?.start(at: "seg-\(section.rawValue)", force: true)
        }
        .onChange(of: router.socialSection) { _, asked in if let asked { saved = asked.rawValue; router.socialSection = nil } }
        .onChange(of: saved) { _, _ in scope?.start(at: "seg-\(section.rawValue)", force: true) }
    }

    // MARK: Steam

    @ViewBuilder private var steamSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Friends", note: steam.signedIn ? "Who is online and what they are playing, from your Steam account. Read only for now." : nil) {
                if steam.signedIn {
                    SteamFriendsList().padding(.horizontal, 6)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash").font(.system(size: 36)).foregroundStyle(Theme.textDim)
                        Text("Sign in to Steam to see your friends here.").font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                        PillButton(id: "social-steam-signin", title: "Open Steam", symbol: "arrow.up.forward.app.fill") { router.openSteam() }
                    }
                    .frame(maxWidth: .infinity).padding(20)
                }
            }
            SettingsGroup(title: "Messages and groups", note: "Steam chat and groups are not in Porthole yet. They are meant to live here.") { EmptyView() }
        }
    }
}

/// Discord's settings (account, voice, notifications) over the Social tab, opened by the gear on the Discord screen.
struct DiscordSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Discord settings").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44).background(Theme.panelHigh, in: Circle()).foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain).accessibilityLabel("Close").focusTarget("dc-settings-close", radius: 22) { dismiss() }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            FocusScroll {
                DiscordPage().environment(\.embeddedPage, true)
                    .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 8).padding(.bottom, 24)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.start(at: "dc-settings-close", force: true) }
        .preferredColorScheme(Theme.scheme)
    }
}
