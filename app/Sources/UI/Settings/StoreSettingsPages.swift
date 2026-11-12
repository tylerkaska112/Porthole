// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Settings > Stores: one list of every store with who is signed in, and one page per store for its sign-in, its library and what it installed.

extension SettingsSub {
    /// The page's name, shown as its big title and in search results.
    var title: String {
        switch self {
        case .store(let store): store.title
        case .engineGroups: "Engine options"
        case .engineGroup(let title): title
        case .engineChanged: "Changed from default"
        case .components: "Windows components"
        case .links: "Links and remote control"
        case .diagnostics: "Diagnostics"
        case .connectionExtras: "VPN and cellular options"
        case .olderVersions: "Older versions"
        }
    }

    /// The page this one was opened from (nil = the Settings page itself).
    var parent: SettingsSub? {
        switch self {
        case .engineGroup, .engineChanged: .engineGroups
        default: nil
        }
    }

    /// The Settings page it lives on, for the Back button when it has no parent of its own.
    var page: SettingsPage {
        if case .store = self { return .stores }
        if self == .connectionExtras { return .jit }
        if self == .olderVersions { return .updates }
        return .advanced
    }

    /// The row that opens it, so Back puts the highlight where it was.
    var rowID: String {
        switch self {
        case .store(let store): "hub-store-\(store.rawValue)"
        case .engineGroups: "hub-engine"
        case .engineGroup(let title): "hub-eng-\(title)"
        case .engineChanged: "hub-eng-changed"
        case .components: "hub-components"
        case .links: "hub-links"
        case .diagnostics: "hub-diagnostics"
        case .connectionExtras: "hub-connection-extras"
        case .olderVersions: "hub-older-versions"
        }
    }
}

/// The Back button at the top of a page inside a Settings page.
struct SubPageHeader: View {
    let sub: SettingsSub
    @Environment(AppRouter.self) private var router
    @Environment(\.focusScope) private var scope

    var body: some View {
        PillButton(id: "set-back", title: sub.parent?.title ?? sub.page.title, symbol: "chevron.left") {
            router.settingsSub = sub.parent
            DispatchQueue.main.async { scope?.focused = sub.rowID }
        }
    }
}

/// A page inside a Settings page: Back, a big title, then the groups. Pages written for the combined layout (their own title dropped) go inside it unchanged.
struct SubPage<Content: View>: View {
    let sub: SettingsSub
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SubPageHeader(sub: sub)
            PageHeader(title: sub.title, symbol: symbol)
            content.environment(\.embeddedPage, true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}

// MARK: - The list of stores

struct StoresSettingsPage: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epic = EpicAuth.shared
    @ObservedObject private var gog = GogAuth.shared
    @ObservedObject private var itch = ItchAuth.shared
    @ObservedObject private var amazon = AmazonAuth.shared
    @ObservedObject private var ea = EAAuth.shared
    @AppStorage(StoreVisibility.key) private var hiddenRaw = ""

    var body: some View {
        if case .store(let store)? = router.settingsSub { StoreSettingsPage(store: store) } else { list }
    }

    /// Who is signed in to a store, or nil when nobody is.
    private func account(_ store: GameStore) -> String? {
        switch store {
        case .steam: steam.signedIn ? (steam.accountName ?? "Signed in") : nil
        case .epic: epic.accountName.map { $0.isEmpty ? "Signed in" : $0 }
        case .gog: gog.accountName.map { $0.isEmpty ? "Signed in" : $0 }
        case .itch: itch.accountName.map { $0.isEmpty ? "Signed in" : $0 }
        case .amazon: amazon.accountName.map { $0.isEmpty ? "Signed in" : $0 }
        case .ea: ea.signedIn ? (ea.accountName ?? "Signed in") : nil
        }
    }

    private var list: some View {
        PageScaffold(title: "Stores", symbol: "storefront.fill", subtitle: "Your store accounts and what each one holds") {
            SettingsGroup(title: "Accounts", note: "Sign in to a store to see the games you own there and install them. Each store has its own page for its sign-in, its library and what it installed.") {
                ForEach(GameStore.allCases) { store in
                    let who = account(store)
                    ActionRow(id: StoresSettingsPage.rowID(store), symbol: "storefront.fill", tint: store.tint, title: store.title,
                              subtitle: who.map { "Signed in as \($0)" } ?? "Not signed in", detail: who == nil ? "Sign in" : nil) { router.settingsSub = .store(store) }
                }
            }
            SettingsGroup(title: "Show on the Stores tab", note: "Hide the stores you do not use so the Stores tab only shows the ones you do. Hiding only changes what is shown: nothing is signed out or deleted, and a download that is running still appears in Downloads. You can also long-press a store on the Stores tab to hide it.") {
                ForEach(GameStore.allCases) { store in
                    ToggleRow(id: "stores-show-\(store.rawValue)", symbol: "eye.fill", title: store.title,
                              isOn: Binding(get: { !StoreVisibility.hiddenIDs(hiddenRaw).contains(store.rawValue) },
                                            set: { hiddenRaw = StoreVisibility.setting(store.rawValue, hidden: !$0, in: hiddenRaw, known: GameStore.allCases.map(\.rawValue)) }))
                }
            }
        }
    }

    static func rowID(_ store: GameStore) -> String { SettingsSub.store(store).rowID }
}

/// One store's page.
struct StoreSettingsPage: View {
    let store: GameStore

    var body: some View {
        SubPage(sub: .store(store), symbol: "storefront.fill") {
            switch store {
            case .steam: SteamSettingsPage()
            case .epic: EpicStoreSettings()
            case .gog: GogStoreSettings()
            case .itch: ItchStoreSettings()
            case .amazon: AmazonStoreSettings()
            case .ea: EAStoreSettings()
            }
        }
    }
}

/// What every store page shows: the account, the library, and what is installed. The five stores without settings of their own pass their numbers in.
struct StoreAccountGroups: View {
    let store: GameStore
    let account: String?
    let libraryCount: Int
    let loading: Bool
    let installedCount: Int
    var libraryNote: String
    let refresh: () -> Void
    let signOut: () -> Void
    let signInSheet: () -> AnyView

    @Environment(AppRouter.self) private var router
    @State private var showSignIn = false
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            SettingsGroup(title: "Account", note: account == nil ? "You sign in on \(store.title)'s own page. The sign-in stays in this device's Keychain; Porthole never sees your password." : nil) {
                if let account {
                    ValueRow(id: "sp-account", symbol: "person.fill", title: "Signed in as", value: account.isEmpty ? "Your account" : account)
                    ActionRow(id: "sp-open", symbol: "books.vertical.fill", title: "Open the \(store.title) library") { router.openStore(store) }
                    ActionRow(id: "sp-out", symbol: "rectangle.portrait.and.arrow.right", title: "Sign out of \(store.title)", destructive: true, chevron: false) { confirmSignOut = true }
                } else {
                    ActionRow(id: "sp-in", symbol: "person.badge.key.fill", title: "Sign in to \(store.title)", prominent: true) { showSignIn = true }
                }
            }
            if account != nil {
                SettingsGroup(title: "Library", note: libraryNote) {
                    ValueRow(id: "sp-games", symbol: "square.grid.2x2.fill", title: "Games on your account", value: loading ? "Loading\u{2026}" : "\(libraryCount)")
                    ActionRow(id: "sp-refresh", symbol: "arrow.clockwise", title: "Refresh the list", chevron: false) { refresh() }
                    ValueRow(id: "sp-installed", symbol: "checkmark.circle.fill", title: "Installed on this device", value: "\(installedCount)")
                }
            }
        }
        .sheet(isPresented: $showSignIn) { signInSheet() }
        .confirm("Sign out of \(store.title)?", message: "Games you installed stay on this device.", confirmTitle: "Sign out", destructive: true, isPresented: $confirmSignOut) { signOut() }
    }
}

struct EpicStoreSettings: View {
    @ObservedObject private var auth = EpicAuth.shared
    @ObservedObject private var library = EpicLibrary.shared
    @ObservedObject private var installer = EpicInstaller.shared
    var body: some View {
        StoreAccountGroups(store: .epic, account: auth.accountName, libraryCount: library.games.count, loading: library.isLoading, installedCount: installer.installed.count,
                           libraryNote: "Only games with a Windows version are listed.",
                           refresh: { library.refresh() }, signOut: { auth.signOut(); library.clear() }, signInSheet: { AnyView(EpicSignInView()) })
            .task { if auth.signedIn { library.refreshIfStale() } }
    }
}

struct GogStoreSettings: View {
    @ObservedObject private var auth = GogAuth.shared
    @ObservedObject private var library = GogLibrary.shared
    @ObservedObject private var installer = GogInstaller.shared
    @AppStorage(GogGalaxy.enabledKey) private var galaxy = true
    var body: some View {
        StoreAccountGroups(store: .gog, account: auth.accountName, libraryCount: library.games.count, loading: library.isLoading, installedCount: installer.installed.count,
                           libraryNote: "Games from your GOG account that have a Windows version.",
                           refresh: { library.refresh() }, signOut: { auth.signOut(); library.clear() }, signInSheet: { AnyView(GogSignInView()) })
        SettingsGroup(title: "Game services", note: "What GOG's own client does while a game runs.") {
            ToggleRow(id: "gog-galaxy", symbol: "trophy.fill", title: "GOG Galaxy services",
                      info: "A game built with GOG's Galaxy SDK talks to GOG's client for its sign-in, achievements, stats, leaderboards and play time. While one of your GOG games runs, Porthole answers for that client on this device only, using your GOG sign-in to get a token for that one game. It needs a game installed from GOG's own builds (a game installed before this was added is read once, at its next start). Without it, or without a sign-in, the game runs offline, as it would without GOG's client. Not tested on a device yet.",
                      isOn: $galaxy)
        }
    }
}

struct ItchStoreSettings: View {
    @ObservedObject private var auth = ItchAuth.shared
    @ObservedObject private var library = ItchLibrary.shared
    @ObservedObject private var installer = ItchInstaller.shared
    var body: some View {
        StoreAccountGroups(store: .itch, account: auth.accountName, libraryCount: library.games.count, loading: library.isLoading, installedCount: installer.installed.count,
                           libraryNote: "Games you bought or claimed on itch.io that have a Windows version.",
                           refresh: { library.refresh() }, signOut: { auth.signOut(); library.clear() }, signInSheet: { AnyView(ItchSignInView()) })
    }
}

struct AmazonStoreSettings: View {
    @ObservedObject private var auth = AmazonAuth.shared
    @ObservedObject private var library = AmazonLibrary.shared
    @ObservedObject private var installer = AmazonInstaller.shared
    var body: some View {
        StoreAccountGroups(store: .amazon, account: auth.accountName, libraryCount: library.games.count, loading: library.isLoading, installedCount: installer.installed.count,
                           libraryNote: "Games from your Amazon Games account.",
                           refresh: { library.refresh() }, signOut: { auth.signOut(); library.clear() }, signInSheet: { AnyView(AmazonSignInView()) })
    }
}

struct EAStoreSettings: View {
    @ObservedObject private var auth = EAAuth.shared
    @ObservedObject private var library = EALibrary.shared
    @ObservedObject private var installer = EAInstaller.shared
    var body: some View {
        StoreAccountGroups(store: .ea, account: auth.signedIn ? (auth.accountName ?? "") : nil, libraryCount: library.games.count, loading: library.isLoading, installedCount: installer.installed.count,
                           libraryNote: "Games that use EA's kernel anti-cheat (Battlefield 2042 and later, EA SPORTS FC, Madden) cannot run here.",
                           refresh: { library.refresh() }, signOut: { auth.signOut() }, signInSheet: { AnyView(EASignInView()) })
            .task { library.refreshIfStale() }
    }
}
