// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import LauncherCore

/// The first-run walkthrough, in plain words: Welcome, three numbered steps (Full speed, Windows components, Games) and Done.
/// A step that is not finished says so on its button ("Skip for now"), nothing is skipped silently, and where the person got to is remembered.
struct SetupGuideView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epic = EpicAuth.shared
    @ObservedObject private var gog = GogAuth.shared
    @ObservedObject private var itch = ItchAuth.shared
    @ObservedObject private var amazon = AmazonAuth.shared
    @Environment(\.dismiss) private var dismiss
    /// A phone held sideways: the height is what is scarce, so the buttons move up beside the steps and the pages get the whole height.
    @Environment(\.verticalSizeClass) private var vSize
    private var short: Bool { vSize == .compact }
    var openAdd: () -> Void = {}
    var openSteam: () -> Void = {}
    var openEpic: () -> Void = {}
    var openGog: () -> Void = {}
    var openItch: () -> Void = {}
    var openAmazon: () -> Void = {}

    /// First time through on iOS 27 or later the in-app method (with the on-device pairing button) is preselected; otherwise whatever is set already.
    private static func initialMethod() -> JITMethod {
        if UserDefaults.standard.string(forKey: JITMethod.key) == nil, OnDevicePairing.isSupported, InstallCheck.hasJITHelper {
            JITMethod.current = .inApp
        }
        return JITMethod.current
    }

    private enum Step: Int, CaseIterable {
        case welcome, speed, downloads, games, tips, done

        /// Position among the numbered steps (1...3); the first and last page are not numbered.
        var number: Int? { (1...3).contains(rawValue) ? rawValue : nil }
        static let numbered = 3
        var name: String {
            switch self {
            case .welcome: "Welcome"
            case .speed: "Full speed"
            case .downloads: "Windows components"
            case .games: "Games"
            case .tips: "Good to know"
            case .done: "Done"
            }
        }
    }
    private enum Need { case needed, recommended, optional
        var label: String { switch self { case .needed: "Needed"; case .recommended: "Recommended"; case .optional: "Optional" } }
    }

    @State private var step: Step = {
        let saved = UserDefaults.standard.integer(forKey: "f4.setupStep")
        return Step(rawValue: saved).flatMap { $0 == .done ? nil : $0 } ?? .welcome       // an out-of-range number from an older version of the guide starts over
    }()

    // Speed (JIT)
    @State private var method = SetupGuideView.initialMethod()
    @State private var hasPairing = BuiltinJIT.hasPairing
    @State private var showMethods = false
    @State private var pickPairing = false
    @State private var pairingMessage: String?
    @State private var pairHere = false
    @State private var stikAvailable = StikJITHelper.isAvailable
    // Connection
    @AppStorage("f4.tunnelAllowed") private var tunnelAllowed = false
    @State private var tunnelMessage: String?
    @State private var tunnelBusy = false
    /// An install without the tunnel extension (or one told to use LocalDevVPN) has no private link of its own to allow.
    private var tunnelNeeded: Bool { InstallCheck.hasTunnel && !TunnelManager.useLocalDevVPN }
    private var jitReady: Bool {
        switch method {
        case .inApp: hasPairing
        case .stikDebug: stikAvailable
        case .other: true
        }
    }
    private var runtimeReady: Bool { VCRuntimeInstaller.shared.available }

    private func need(_ s: Step) -> Need? {
        switch s {
        case .speed: .needed
        case .downloads: .recommended
        case .games: .optional
        case .welcome, .tips, .done: nil
        }
    }

    /// Signed in to any of the five stores.
    private var anyStore: Bool { steam.signedIn || epic.signedIn || gog.signedIn || itch.signedIn || amazon.signedIn }

    private func complete(_ s: Step) -> Bool {
        switch s {
        case .speed: jitReady && (!tunnelNeeded || tunnelAllowed)
        case .downloads: runtimeReady
        case .games: anyStore || !model.games.isEmpty
        case .welcome, .tips, .done: true
        }
    }

    @State private var scope = FocusScope()

    private var firstFocus: AnyHashable {
        switch step {
        case .welcome, .tips, .done: "su-next"
        case .speed:
            if method != .inApp { tunnelNeeded && !tunnelAllowed ? "su-tunnel" : "su-next" }
            else { hasPairing ? (tunnelNeeded ? "su-tunnel" : "su-next") : (OnDevicePairing.isSupported ? "su-pair-here" : "su-pair-pick") }
        case .downloads: "vc-main"
        case .games: "su-steam"
        }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(spacing: 0) {
                topBar
                FocusScroll {
                    VStack(alignment: .leading, spacing: short ? 12 : 16) {
                        switch step {
                        case .welcome: welcome
                        case .speed: speedPage
                        case .downloads: downloadsPage
                        case .games: gamesPage
                        case .tips: tipsPage
                        case .done: donePage
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, short ? 6 : 12)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .id(step)
                }
                if !short { navBar }
            }
        }
        .navScope(scope)
        .onAppear {
            stikAvailable = StikJITHelper.isAvailable; hasPairing = BuiltinJIT.hasPairing
            scope.onBack = { if step == .welcome { dismiss() } else { go(-1) } }
            scope.onSection = { go($0) }
            scope.defaultFocus = firstFocus; scope.focused = firstFocus
        }
        .onChange(of: step) { _, now in
            UserDefaults.standard.set(now == .done ? 0 : now.rawValue, forKey: "f4.setupStep")
            scope.defaultFocus = firstFocus; scope.focused = firstFocus
        }
        .onDisappear { UserDefaults.standard.set(true, forKey: "f4.setupSeen") }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
        .sheet(isPresented: $pickPairing) {
            FilePickerSheet(onPick: { urls in
                pickPairing = false
                do { try BuiltinJIT.importPairing(from: urls[0]); pairingMessage = nil }
                catch { pairingMessage = "That file isn't a pairing file. A pairing file ends in .plist or .mobiledevicepairing." }
                hasPairing = BuiltinJIT.hasPairing
            }, onCancel: { pickPairing = false })
        }
        .sheet(isPresented: $pairHere, onDismiss: { hasPairing = BuiltinJIT.hasPairing }) { PairOnDeviceView() }
    }

    // MARK: Header and footer

    private var topBar: some View {
        Group { if short { compactTopBar } else { regularTopBar } }
    }

    /// Sideways: one row with the steps, where you are, Back, the main button and a round "finish later".
    private var compactTopBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                if let n = step.number {
                    HStack(spacing: 5) {
                        ForEach(1...Step.numbered, id: \.self) { i in
                            Capsule().fill(i <= n ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh)).frame(width: 26, height: 6)
                        }
                    }
                    Text(step.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                    if let need = need(step) { tag(complete(step) ? "Done" : need.label, good: complete(step)) }
                }
                Spacer(minLength: 8)
                if step != .welcome { PillButton(id: "su-back", title: "Back", symbol: "chevron.left") { go(-1) } }
                PillButton(id: "su-next", title: primaryTitle, symbol: step == .done ? "play.fill" : "chevron.right", style: primaryIsMain ? .primary : .glass) {
                    if step == .done { UserDefaults.standard.set(true, forKey: "f4.setupDone"); dismiss() } else { go(1) }
                }
                IconPillButton(id: "su-later", symbol: "xmark", label: step == .done ? "Close" : "Finish later") { dismiss() }
            }
            if step.number != nil, !complete(step), need(step) == .needed {
                Label("Games won't start until this is done", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
        .frame(maxWidth: 728)
    }

    private var regularTopBar: some View {
        VStack(spacing: 8) {
            HStack {
                if let n = step.number {
                    HStack(spacing: 6) {
                        ForEach(1...Step.numbered, id: \.self) { i in
                            Capsule().fill(i <= n ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh)).frame(width: 34, height: 6)
                                .shadow(color: i == n ? Theme.accent.opacity(0.6 * Theme.glowStrength) : .clear, radius: 5)
                        }
                    }
                }
                Spacer()
                PillButton(id: "su-later", title: step == .done ? "Close" : "Finish later", symbol: "xmark") { dismiss() }
            }
            if step.number != nil {
                HStack(spacing: 8) {
                    Text(step.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.textDim)
                    if let need = need(step) { tag(complete(step) ? "Done" : need.label, good: complete(step)) }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: 728)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Let's start"
        case .done: jitReady && tunnelAllowed ? "Start playing" : "Finish for now"
        default: complete(step) ? "Continue" : "Skip for now"
        }
    }
    private var primaryIsMain: Bool { step == .welcome || step == .done || complete(step) }

    private var navBar: some View {
        VStack(spacing: 8) {
            if step.number != nil, !complete(step), need(step) == .needed {
                Label("Games won't start until this is done", systemImage: "exclamationmark.triangle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.warn)
            }
            HStack(spacing: 12) {
                if step != .welcome { PillButton(id: "su-back", title: "Back", symbol: "chevron.left") { go(-1) } }
                PillButton(id: "su-next", title: primaryTitle, symbol: step == .done ? "play.fill" : "chevron.right", style: primaryIsMain ? .primary : .glass) {
                    if step == .done { UserDefaults.standard.set(true, forKey: "f4.setupDone"); dismiss() } else { go(1) }
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 728)
    }

    private func go(_ delta: Int) { step = Step(rawValue: min(max(step.rawValue + delta, 0), Step.allCases.count - 1)) ?? step }

    // MARK: Pages

    private func header(_ title: String, info: String? = nil, infoTitle: String = "More") -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: short ? 24 : 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            if let info { InfoButton(id: "su-hdr-info", title: infoTitle, text: info) }
            Spacer()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            if short {
                // Sideways there is no room for a big picture above the title: the two sit side by side.
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 30)).foregroundStyle(Theme.accentGradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome to Porthole").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Theme.text)
                        Text("Three quick steps. Stop any time.").font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                }
            } else {
                Image(systemName: "gamecontroller.fill").font(.system(size: 46)).foregroundStyle(Theme.accentGradient).shadow(color: Theme.accent.opacity(0.6 * Theme.glowStrength), radius: 16)
                Text("Welcome to Porthole").font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(Theme.text)
                Text("Three quick steps. Stop any time.").font(.title3).foregroundStyle(Theme.textDim)
            }
            SettingsGroup {
                ForEach([Step.speed, .downloads, .games], id: \.rawValue) { s in outlineRow(s) }
                RowBase(id: "su-privacy", symbol: "lock.shield.fill", tint: Theme.good, title: "Stays on this device",
                        info: "Your store sign-ins stay in this device\u{2019}s Keychain and go only to the store itself. Porthole goes online to download what you ask for (Microsoft\u{2019}s components, your game downloads and updates), to check for updates, and to load compatibility badges. It asks for the whole list of badges, so nobody is told which games you own. A compatibility report or a problem report is sent only when you choose to send one; a problem log is cleaned of account names, e-mail addresses and public IP addresses first.", action: {}) { EmptyView() }
            }
        }
    }

    private func outlineRow(_ s: Step) -> some View {
        let lines: [Step: (String, String, String)] = [
            .speed: ("bolt.fill", "Full speed", "About 2 minutes"),
            .downloads: ("shippingbox.fill", "Windows components", "About 25 MB"),
            .games: ("gamecontroller.fill", "Add your games", "Steam, Epic Games, GOG, itch.io, Amazon Games or Files"),
        ]
        let l = lines[s] ?? ("circle", s.name, "")
        return RowBase(id: "su-o-\(s.rawValue)", symbol: l.0, title: l.1, subtitle: l.2, action: { step = s }) {
            if let need = need(s) { tag(need.label) }
        }
    }

    private var speedPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Get ready to play", info: "iOS keeps a speed feature called JIT switched off. Games on Porthole need it, so something has to switch it on each time you play. JIT lets an app create and run new machine code while it is running; Apple doesn't let normal apps switch it on, so a helper asks iOS for it.", infoTitle: "What is JIT?")
            if InstallCheck.layout != .full {
                Text(InstallCheck.layoutSummary).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            if method == .inApp && !showMethods {
                RowBase(id: "su-method-auto", symbol: "wand.and.stars", title: "Switched on by Porthole", subtitle: "The simplest way, and what most people use", action: {}) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
            } else {
              SettingsGroup {
                ForEach(JITMethod.available) { m in
                    RowBase(id: "su-m-\(m.rawValue)", symbol: m == .inApp ? "wand.and.stars" : m == .stikDebug ? "app.badge.fill" : "wrench.and.screwdriver.fill", title: m.title, subtitle: m.summary,
                            info: "\u{2713} \(m.pros)\n\u{2022} \(m.cons)", action: { method = m; JITMethod.current = m }) {
                        if method == m { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }
                }
              }
            }
            switch method {
            case .inApp:
                SettingsGroup {
                    ValueRow(id: "su-pair-state", symbol: hasPairing ? "checkmark.circle.fill" : "circle.dashed", title: hasPairing ? "Pairing file ready" : "Pairing file needed", value: hasPairing ? "Done" : "Needed", statusColor: hasPairing ? Theme.good : Theme.warn)
                    if !hasPairing {
                        if OnDevicePairing.isSupported {
                            ActionRow(id: "su-pair-here", symbol: "iphone.gen3", title: "Create it on this device", subtitle: "About a minute, no computer", chevron: false, prominent: true) { pairHere = true }
                            ActionRow(id: "su-pair-pick", symbol: "doc.badge.plus", title: "I already have a pairing file", chevron: false) { pickPairing = true }
                        } else {
                            ActionRow(id: "su-pair-pick", symbol: "doc.badge.plus", title: "Choose the pairing file", subtitle: "Made once on a computer",
                                      info: "1. On a computer, install a free pairing tool such as iloader or Jitterbug.\n2. Plug in your device and tap Trust.\n3. Save the pairing file for your device (.plist or .mobiledevicepairing).\n4. Move it to this device (AirDrop, iCloud Drive or a cable).\n5. Come back and choose it here.\nYou only do this once.", chevron: false) { pickPairing = true }
                        }
                    } else {
                        ActionRow(id: "su-pair-replace", symbol: "arrow.triangle.2.circlepath", title: "Replace the pairing file", chevron: false) { OnDevicePairing.isSupported ? (pairHere = true) : (pickPairing = true) }
                    }
                    if let pairingMessage { Text(pairingMessage).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                }
            case .stikDebug:
                SettingsGroup {
                    ValueRow(id: "su-stik-state", symbol: stikAvailable ? "checkmark.circle.fill" : "circle.dashed", title: stikAvailable ? "StikDebug found" : "StikDebug not found", value: stikAvailable ? "Done" : "Needed", statusColor: stikAvailable ? Theme.good : Theme.warn)
                    ActionRow(id: "su-stik-check", symbol: "arrow.clockwise", title: "Check again", subtitle: stikAvailable ? nil : "Install StikDebug first", chevron: false) { stikAvailable = StikJITHelper.isAvailable }
                }
            case .other:
                Text("Press Play, switch JIT on with your tool, and the game starts by itself.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            if method == .inApp && !showMethods {
                ActionRow(id: "su-other-methods", symbol: "ellipsis.circle", title: "Use a different method", chevron: false) { showMethods = true }
            }
            if !InstallCheck.hasTunnel {
                SettingsGroup(title: "Private link") {
                    ValueRow(id: "su-tunnel-none", symbol: "link", title: "Comes from LocalDevVPN", value: "Nothing to allow", statusColor: Theme.good)
                }
                Text("This install has no tunnel of its own, which saves an App ID and leaves your own VPN alone. If your JIT tool needs a private link, turn LocalDevVPN on before you press Play.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            } else if TunnelManager.useLocalDevVPN {
                SettingsGroup(title: "Private link") {
                    ValueRow(id: "su-tunnel-localdev", symbol: "link", title: "Comes from LocalDevVPN", value: "Nothing to allow", statusColor: Theme.good)
                }
            } else {
            SettingsGroup(title: "Private link") {
                ValueRow(id: "su-tunnel-state", symbol: tunnelAllowed ? "checkmark.circle.fill" : "circle.dashed", title: tunnelAllowed ? "Allowed" : "Not allowed yet", value: tunnelAllowed ? "Done" : "Needed", statusColor: tunnelAllowed ? Theme.good : Theme.warn)
                ActionRow(id: "su-tunnel", symbol: "link", title: tunnelBusy ? "Checking\u{2026}" : (tunnelAllowed ? "Check it again" : "Allow the private link"),
                          info: "To switch JIT on, Porthole reaches your device's own debug service through a small private link that exists only inside your device.\n\niOS will ask whether Porthole may add a VPN configuration. That is how iOS describes this link. It is not a real VPN: nothing goes over the internet and none of your other traffic is touched. Tap Allow.\n\niOS allows one VPN at a time, so another VPN app pauses for a few seconds; Porthole asks first and helps you turn it back on.",
                          chevron: false, prominent: !tunnelAllowed) {
                    guard !tunnelBusy else { return }
                    tunnelBusy = true; tunnelMessage = nil
                    Task {
                        do { try await TunnelManager.shared.connect(); TunnelManager.shared.disconnect(); tunnelAllowed = true }
                        catch { tunnelMessage = error.localizedDescription }
                        tunnelBusy = false
                    }
                }
                if let tunnelMessage { Text(tunnelMessage).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
            }
            }
        }
    }

    private var downloadsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Windows components", info: "Many games need Microsoft's Visual C++ runtime. Porthole downloads it straight from Microsoft (about 25 MB), checks that it is the genuine file, and keeps it on this device. Without it some games won't start. You can also do this later in Settings \u{203A} Advanced.", infoTitle: "Why download this?")
            VCRuntimePanel()
        }
    }

    private var gamesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Add your games", info: "Bring in the games you already own, from a store or from Files. You can do any of them, all of them, or none now; they are always available from the home screen and the Stores tab later.", infoTitle: "Adding games")
            SettingsGroup(title: "Steam") {
                ValueRow(id: "su-steam-state", symbol: steam.signedIn ? "checkmark.circle.fill" : "circle.dashed", title: steam.signedIn ? "Signed in" : "Not signed in", value: steam.signedIn ? "Done" : "Optional", statusColor: steam.signedIn ? Theme.good : Theme.textDim)
                ActionRow(id: "su-steam", symbol: "arrow.down.circle.fill", tint: .blue, title: steam.signedIn ? "Open your Steam library" : "Sign in to Steam",
                          info: "Download the games you own on Steam straight to this device. Your password is encrypted before it leaves the device and is never saved.", chevron: false, prominent: !steam.signedIn) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openSteam() } }
            }
            SettingsGroup(title: "Epic Games") {
                ValueRow(id: "su-epic-state", symbol: epic.signedIn ? "checkmark.circle.fill" : "circle.dashed", title: epic.signedIn ? "Signed in" : "Not signed in", value: epic.signedIn ? "Done" : "Optional", statusColor: epic.signedIn ? Theme.good : Theme.textDim)
                ActionRow(id: "su-epic", symbol: "arrow.down.circle.fill", tint: .indigo, title: epic.signedIn ? "Open your Epic Games library" : "Sign in to Epic Games",
                          info: "Download the games you own on Epic Games straight to this device. You sign in on Epic's own page; Porthole never sees your password.", chevron: false, prominent: false) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openEpic() } }
            }
            SettingsGroup(title: "GOG") {
                ValueRow(id: "su-gog-state", symbol: gog.signedIn ? "checkmark.circle.fill" : "circle.dashed", title: gog.signedIn ? "Signed in" : "Not signed in", value: gog.signedIn ? "Done" : "Optional", statusColor: gog.signedIn ? Theme.good : Theme.textDim)
                ActionRow(id: "su-gog", symbol: "arrow.down.circle.fill", tint: .purple, title: gog.signedIn ? "Open your GOG library" : "Sign in to GOG",
                          info: "Download the games you own on GOG straight to this device. You sign in on GOG's own page; Porthole never sees your password.", chevron: false, prominent: false) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openGog() } }
            }
            SettingsGroup(title: "itch.io") {
                ValueRow(id: "su-itch-state", symbol: itch.signedIn ? "checkmark.circle.fill" : "circle.dashed", title: itch.signedIn ? "Signed in" : "Not signed in", value: itch.signedIn ? "Done" : "Optional", statusColor: itch.signedIn ? Theme.good : Theme.textDim)
                ActionRow(id: "su-itch", symbol: "arrow.down.circle.fill", tint: .red, title: itch.signedIn ? "Open your itch.io library" : "Sign in to itch.io",
                          info: "Download the games you bought, claimed or collected on itch.io. You make a personal API key on itch.io and paste it here; it stays in this device's Keychain.", chevron: false, prominent: false) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openItch() } }
            }
            SettingsGroup(title: "Amazon Games") {
                ValueRow(id: "su-amazon-state", symbol: amazon.signedIn ? "checkmark.circle.fill" : "circle.dashed", title: amazon.signedIn ? "Signed in" : "Not signed in", value: amazon.signedIn ? "Done" : "Optional", statusColor: amazon.signedIn ? Theme.good : Theme.textDim)
                ActionRow(id: "su-amazon", symbol: "arrow.down.circle.fill", tint: .orange, title: amazon.signedIn ? "Open your Amazon Games library" : "Sign in to Amazon Games",
                          info: "Download the games you bought on Amazon or claimed with Prime Gaming. You sign in on Amazon's own page; Porthole never sees your password.", chevron: false, prominent: false) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openAmazon() } }
            }
            SettingsGroup(title: "Files") {
                ValueRow(id: "su-files-state", symbol: model.games.isEmpty ? "circle.dashed" : "checkmark.circle.fill", title: model.games.isEmpty ? "No games added yet" : "\(model.games.count) game\(model.games.count == 1 ? "" : "s") added", value: model.games.isEmpty ? "Optional" : "Done", statusColor: model.games.isEmpty ? Theme.textDim : Theme.good)
                ActionRow(id: "su-import", symbol: "folder.badge.plus", title: "Import a game", info: "Pick a game's folder in Files and it is copied into Porthole, or run a Windows installer.", chevron: false) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openAdd() } }
            }
        }
    }

    private var tipsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Good to know", info: "A few things that save people time. None of them needs anything from you now.", infoTitle: "Good to know")
            SettingsGroup {
                RowBase(id: "su-tip-first", symbol: "hourglass", tint: .orange, title: "The first start takes longer", subtitle: "Later starts of the same game are quicker.",
                        info: "The first time a game starts, everything has to be set up, and some games prepare their graphics as they run. The first start can take a minute or more, and the first frames may stutter. Keep Porthole open and the screen on while it loads.", action: {}) { EmptyView() }
                RowBase(id: "su-tip-swap", symbol: "memorychip.fill", tint: .blue, title: "Big games may need Swap", subtitle: "If a game closes or stutters, give it more Swap.",
                        info: "iOS closes an app that uses too much memory. Swap lets Porthole use storage as extra memory. If a game closes by itself or stutters, open the game, then its settings, and raise Swap. The Stats button while you play shows how full it is, and Porthole warns you when memory is nearly full.", action: {}) { EmptyView() }
                RowBase(id: "su-tip-pad", symbol: "gamecontroller.fill", tint: Theme.good, title: "Controllers work out of the box", subtitle: "PlayStation, Xbox and other controllers iOS supports.",
                        info: "Pair a controller in iOS Settings \u{203A} Bluetooth. While one is in use, the on-screen controls hide. If a game doesn't see it, open the game's settings and try the DualSense (HID) and Xbox option. A game can also use the controller as a keyboard and mouse, and each game's controller buttons can be remapped.", action: {}) { EmptyView() }
                RowBase(id: "su-tip-power", symbol: "bolt.fill", tint: .yellow, title: "Performance mode goes up to 120 FPS", subtitle: "On iPads and iPhones with ProMotion screens.",
                        info: "Choose the power mode with the Power button in the in-game menu. Performance mode uses more battery and makes the device warmer; Balanced and Battery saver do the opposite.", action: {}) { EmptyView() }
            }
        }
    }

    private var donePage: some View {
        let ready = jitReady && (!tunnelNeeded || tunnelAllowed)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").font(.system(size: short ? 28 : 42)).foregroundStyle(ready ? Theme.good : Theme.warn).shadow(color: (ready ? Theme.good : Theme.warn).opacity(0.5), radius: 14)
                if short { header(ready ? "You're all set" : "Almost there") }
            }
            if !short { header(ready ? "You're all set" : "Almost there") }
            if !ready { Text("Games won't start until full speed is set up.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            SettingsGroup {
                summaryRow(.speed, jitReady && (!tunnelNeeded || tunnelAllowed) ? "Full speed: \(method.title)" : (jitReady ? "Private link not allowed" : "Full speed isn't set up"))
                summaryRow(.downloads, runtimeReady ? "Windows components ready" : "Windows components missing")
                summaryRow(.games, anyStore || !model.games.isEmpty ? "Games: \([steam.signedIn ? "Steam" : nil, epic.signedIn ? "Epic Games" : nil, gog.signedIn ? "GOG" : nil, itch.signedIn ? "itch.io" : nil, amazon.signedIn ? "Amazon Games" : nil, model.games.isEmpty ? nil : "\(model.games.count) imported"].compactMap { $0 }.joined(separator: ", "))" : "No games added yet")
            }
        }
    }

    private func summaryRow(_ s: Step, _ text: String) -> some View {
        RowBase(id: "su-sum-\(s.rawValue)", symbol: complete(s) ? "checkmark.circle.fill" : "circle.dashed", tint: complete(s) ? Theme.good : Theme.warn, title: text, action: { if !complete(s) { step = s } }) {
            if !complete(s) { Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.textDim) }
        }
    }

    private func tag(_ s: String, good: Bool = false) -> some View {
        Text(s).font(.caption2.weight(.bold)).foregroundStyle(good ? Theme.good : Theme.textDim)
            .padding(.horizontal, 8).padding(.vertical, 3).background((good ? Theme.good : Theme.textDim).opacity(0.15), in: Capsule())
    }
}

/// "What's this?" for the signing certificate: what it is, what the person gains and risks by adding it, and what happens if they don't.
struct SigningExplainerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()

    var body: some View {
        KitSheet(title: "Signing certificate", closeTitle: "Done", closeSymbol: "checkmark", scope: scope, close: { dismiss() }) {
            VStack(alignment: .leading, spacing: 14) {
                section("What is it?", Theme.text, [
                    "Apps that don't come from the App Store have to be digitally signed with a certificate tied to an Apple account, or iOS refuses to open them. The service or account that installed this app gave you two files for that: a certificate (a .p12 file protected by a password) and a profile (a .mobileprovision file).",
                    "If you give this app those two files, it can sign new versions of itself on your device."])
                section("If you add them", Theme.good, [
                    "\u{2713} Update from inside the app, with no computer.",
                    "\u{2713} Your games, settings and store sign-ins stay where they are.",
                    "\u{2713} The files stay on this device, in the encrypted Keychain."])
                section("The catches", Theme.warn, [
                    "\u{2022} You need the files. Some signing services don't let you export them.",
                    "\u{2022} A certificate and its password are powerful: only add them if you are comfortable with that. The app never sends them anywhere.",
                    "\u{2022} Profiles run out (7 days with a free Apple account, about a year with a paid one).",
                    "\u{2022} New versions must be signed by the same account that installed the app."]
                    // A build that was made with an update server needs nothing more; one without it has to be told where it is.
                    + (BuiltIn.defaultHubURL == nil ? ["\u{2022} You also need the update server's address from whoever shared the app."] : []))
                section("If you don't", Theme.text, [
                    "Everything else works the same. To update, install the newer .ipa yourself the way you installed this one; your games and settings are kept (use the same account).",
                    "Not sure? Say No for now. You can add the files later in Settings \u{203A} Updates."])
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    private func section(_ head: String, _ color: Color, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(head).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(color)
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 14)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}
