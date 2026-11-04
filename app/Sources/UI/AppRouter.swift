// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import Observation

/// The app's top-level sections. On iPhone they are the tab bar; on iPad the same list becomes a sidebar.
enum AppTab: Hashable { case library, stores, compatibility, settings }

/// What the Stores tab shows: its list of launchers (nil), every launcher's games on one page, or one launcher's library.
enum StoresSelection: Hashable { case all, store(GameStore), downloads }

/// Where the person is, and what is open on top of it, so any screen can send them somewhere else (a banner that says "update ready" opens Settings, and so on).
@Observable
@MainActor
final class AppRouter {
    var tab: AppTab = .library
    var showAdd = false
    var showSetup = false
    var showUpdates = false
    var pickInstaller = false
    /// The games opened on the Home section (a game's page sits on top of the home screen).
    var homePath = NavigationPath()
    /// Which Settings page to open next time the Settings section appears (nil = the list).
    var settingsPage: SettingsPage?
    /// The Settings page being shown. Kept here, not in the screen, because changing the theme rebuilds the screen and it must come back to the same page.
    var settingsSelection: SettingsPage?
    /// The page inside the chosen Settings page (one store's settings, one group of engine options ...), or nil for the page itself.
    var settingsSub: SettingsSub?

    /// The part of the Reports tab to show next time it appears (nil = leave it as it is).
    var reportsScope: ReportsScope?

    /// The Stores tab's page (nil = the list of launchers).
    var storesSelection: StoresSelection?

    /// Where the shared Downloads page was opened from, so Back returns there.
    var downloadsReturn: StoresSelection?

    func openSteam() { openStore(.steam) }
    func openDownloads() {
        if storesSelection != .downloads { downloadsReturn = storesSelection }
        storesSelection = .downloads; tab = .stores
    }
    func closeDownloads() { storesSelection = downloadsReturn; downloadsReturn = nil }
    func openStore(_ store: GameStore) { storesSelection = .store(store); tab = .stores }
    func openStores() { storesSelection = nil; tab = .stores }
    func openReports(_ scope: ReportsScope) { reportsScope = scope; tab = .compatibility }
    func openSettings(_ page: SettingsPage? = nil, sub: SettingsSub? = nil) { settingsSub = sub; settingsPage = page; tab = .settings }
}

/// The pages in Settings' list, in the order of SettingsScreen.sections.
enum SettingsPage: String, Hashable, CaseIterable, Identifiable {
    case play, saves, storage, stores, jit, appearance, updates, advanced, reports, help, report
    var id: String { rawValue }
}

/// A page inside a Settings page: one store's own settings, a group of engine options, one of Advanced's pages.
enum SettingsSub: Hashable {
    case store(GameStore)
    case engineGroups, engineGroup(String), engineChanged
    case components, links, diagnostics
}
