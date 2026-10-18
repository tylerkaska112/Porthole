// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Every page is built from the kit's rows, so the D-pad reaches everything and the short explanations live behind the (i).

// MARK: - Theme and colours

struct AppearancePage: View {
    @State private var theme = ThemeStore.shared

    private var customColor: Binding<Color> {
        Binding(get: { Color(hex: theme.customAccent) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            theme.customAccent = UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255)
            theme.presetID = "custom"
        })
    }

    var body: some View {
        PageScaffold(title: "Theme and colours", symbol: "paintpalette.fill") {
            SettingsGroup(title: "Colour scheme") {
                AdaptiveGrid(minWidth: 108, spacing: 12) {
                    ForEach(Palette.presets) { swatch($0) }
                    swatch(Palette.custom(accent: theme.customAccent))
                }
                HStack {
                    Image(systemName: "eyedropper.halffull").foregroundStyle(Theme.accent)
                    Text("Your own colour").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    ColorPicker("", selection: customColor, supportsOpacity: false).labelsHidden()
                }
                .padding(.horizontal, 14).frame(minHeight: 56)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
            SettingsGroup(title: "Glow and motion") {
                ChoiceRow(id: "ap-glow", symbol: "sparkles", title: "Glow", info: "How strong the light around the selected thing is. Off turns the glow and the soft lights in the background down.",
                          options: GlowLevel.allCases.map { ($0, $0.title) }, selection: Binding(get: { theme.glow }, set: { theme.glow = $0 }))
                ToggleRow(id: "ap-motion", symbol: "wind", title: "Moving background", info: "The soft coloured lights behind every screen drift slowly. Turn this off to save a little battery.",
                          isOn: Binding(get: { theme.animatedBackground }, set: { theme.animatedBackground = $0 }))
            }
        }
    }

    private func swatch(_ p: Palette) -> some View {
        let selected = theme.presetID == p.id
        return Button { theme.presetID = p.id } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LinearGradient(colors: [Color(hex: p.bgTop), Color(hex: p.bgBottom)], startPoint: .top, endPoint: .bottom))
                    Circle().fill(LinearGradient(colors: [Color(hex: p.accent), Color(hex: p.accent2)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 30, height: 30)
                        .shadow(color: Color(hex: p.accent).opacity(0.7), radius: 8)
                }
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Color(hex: p.accent) : Theme.line, lineWidth: selected ? 3 : 1))
                Text(p.name).font(.footnote.weight(selected ? .bold : .regular)).foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
        .focusTarget("theme-\(p.id)", radius: 16, scale: 1.05) { theme.presetID = p.id }
        .accessibilityLabel(p.name)
    }
}

// MARK: - Display

struct DisplayPage: View {
    @State private var resolution = LaunchSettings.globalResolution
    private let aspect = LaunchSettings.screenAspect

    var body: some View {
        PageScaffold(title: "Display", symbol: "display") {
            SettingsGroup(title: "Picture") {
                ChoiceRow(id: "dp-res", symbol: "rectangle.expand.vertical", title: "Resolution",
                          info: "The size of the screen games see. Higher is sharper but needs more memory and a faster device; lower is faster. Games that pick their own resolution can choose any size up to this one, and the picture is scaled to your screen. Each game can have its own on its page. Applies the next time a game starts.",
                          options: DisplayResolution.allIDs.map { ($0, DisplayResolution.title(id: $0, screenAspect: aspect)) },
                          selection: Binding(get: { resolution }, set: { id in resolution = id; LaunchSettings.globalResolution = id; LogStore.shared.log("[settings] resolution=\(id)") }))
            }
        }
    }
}

// MARK: - Performance

struct PerformancePage: View {
    @State private var power = PowerManager.shared.userMode
    @State private var keepWhenHot = PowerManager.shared.ignoreHeat
    @State private var swapMB = LaunchSettings.globalSwapMB
    @State private var swapCoverage = LaunchSettings.globalSwapCoverage
    @State private var vramMB = LaunchSettings.globalVramMB
    @AppStorage(SessionController.preciseMathKey) private var preciseMath = false
    @AppStorage("f4.advanced") private var advanced = false

    var body: some View {
        PageScaffold(title: "Performance", symbol: "speedometer") {
            SettingsGroup(title: "Power") {
                ChoiceRow(id: "pf-power", symbol: "bolt.fill", title: "Power mode",
                          info: "\(power.detail). By default a game drops to Battery saver (30 FPS and Eco) by itself when the device gets hot. Each game can pick its own on its page.",
                          options: PowerMode.allCases.map { ($0, $0.title) }, selection: Binding(get: { power }, set: { power = $0; PowerManager.shared.set($0) }))
                ToggleRow(id: "pf-hot", symbol: "thermometer.high", title: "Keep my mode when hot",
                          info: "Stops the automatic drop when the device gets hot. Eco mode puts the game on the slow cores, so loading can crawl; this keeps full speed instead, and the device may get hotter and drain faster.",
                          isOn: Binding(get: { keepWhenHot }, set: { keepWhenHot = $0; PowerManager.shared.setIgnoreHeat($0) }))
            }
            if advanced {
                SettingsGroup(title: "Graphics") {
                    ToggleRow(id: "pf-math", symbol: "function", title: "Precise shader math", info: "Exact lighting math instead of fast approximations. Off is faster.", isOn: $preciseMath)
                }
                SettingsGroup(title: "Memory") {
                    ChoiceRow(id: "pf-swap", symbol: "internaldrive.fill", title: "Swap",
                              info: "iOS has no swap and closes an app that uses too much memory. Swap keeps big chunks of game data in a file on the device's storage instead, where iOS doesn't count them, so a memory-hungry game can survive. It uses storage and can be slower.",
                              options: [(0, "Off"), (1024, "1 GB"), (2048, "2 GB"), (3072, "3 GB"), (4096, "4 GB")],
                              selection: Binding(get: { swapMB }, set: { swapMB = $0; LaunchSettings.globalSwapMB = $0; LogStore.shared.log("[settings] swap-mb=\($0)") }))
                    if swapMB > 0 {
                        ChoiceRow(id: "pf-cover", symbol: "square.stack.3d.up.fill", title: "What swap covers",
                                  options: [("", "Large (8 MB+)"), ("blocks", "All 1 MB+"), ("wide", "1 MB+ and overflow"), ("broad", "Broad")],
                                  selection: Binding(get: { swapCoverage }, set: { swapCoverage = $0; LaunchSettings.globalSwapCoverage = $0; LogStore.shared.log("[settings] swap-coverage=\($0.isEmpty ? "classic" : $0)") }))
                    }
                    ChoiceRow(id: "pf-vram", symbol: "memorychip.fill", title: "Video memory",
                              options: [(0, "Automatic"), (512, "512 MB"), (1024, "1 GB"), (1536, "1.5 GB"), (2048, "2 GB"), (3072, "3 GB"), (4096, "4 GB")],
                              selection: Binding(get: { vramMB }, set: { vramMB = $0; LaunchSettings.globalVramMB = $0; LogStore.shared.log("[settings] vram-mb=\($0)") }))
                }
            }
        }
    }
}

// MARK: - Controls and sound

struct ControlsPage: View {
    @State private var look = LaunchSettings.globalLookSensitivity

    var body: some View {
        PageScaffold(title: "Controls", symbol: "hand.tap.fill") {
            SettingsGroup(title: "Controller") {
                ValueRow(id: "ct-pad", symbol: "gamecontroller.fill", title: "Connected controller",
                         value: ControllerInput.shared.kind == .none ? "None" : ControllerInput.shared.kind.displayName,
                         statusColor: ControllerInput.shared.kind == .none ? Theme.textDim : Theme.good)
                Text(ControllerInput.shared.kind == .none
                     ? "Pair a controller in the iOS Bluetooth settings. Porthole names its buttons the way they are printed on it."
                     : "Buttons are named as printed on this controller (\(ControllerInput.shared.kind.glyph("A")) select, \(ControllerInput.shared.kind.glyph("B")) back, \(ControllerInput.shared.kind.glyph("LB")) \(ControllerInput.shared.kind.glyph("RB")) switch section). Hold \(ControllerInput.shared.kind.menuChordName) in a game to open Porthole's menu.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            SettingsGroup(title: "First person") {
                SliderRow(id: "ct-look", symbol: "scope", title: "Look sensitivity",
                          info: "How fast dragging on the screen turns the view in first-person games. A game can set its own on its page, and the in-game Menu has quick Faster and Slower buttons.",
                          value: Binding(get: { look }, set: { look = $0; LaunchSettings.globalLookSensitivity = $0 }), range: LaunchSettings.lookRange, step: 0.1,
                          format: { String(format: "%.1f\u{00D7}", $0) })
            }
        }
    }
}

struct SoundPage: View {
    @AppStorage(SessionController.audioCushionKey) private var audioCushion = 80

    var body: some View {
        PageScaffold(title: "Sound", symbol: "speaker.wave.2.fill") {
            SettingsGroup(title: "Audio") {
                ChoiceRow(id: "sd-buffer", symbol: "waveform", title: "Audio buffer",
                          info: "Extra buffered sound, in milliseconds. Bigger means fewer crackles but effects lag a little more. Applies on the next game start.",
                          options: [(0, "Off"), (40, "40 ms"), (80, "80 ms"), (160, "160 ms"), (300, "300 ms")], selection: $audioCushion)
            }
        }
    }
}

// MARK: - Your install

/// What this install contains and what it was signed with: the answer to "why won't it start" without reading a log.
struct InstallCheckGroup: View {
    var body: some View {
        let items = InstallCheck.findings().filter { $0.level != .info || $0.id.hasSuffix("-absent") }
        SettingsGroup(title: "Your install") {
            ValueRow(id: "ic-layout", symbol: "shippingbox.fill", title: InstallCheck.layoutTitle,
                     value: InstallCheck.attention.isEmpty ? "All good" : "Needs a look", statusColor: InstallCheck.attention.isEmpty ? Theme.good : Theme.warn)
            Text(InstallCheck.layoutSummary).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            ForEach(items) { f in
                let color: Color = f.level == .problem ? Theme.bad : f.level == .warning ? Theme.warn : f.level == .good ? Theme.good : Theme.textDim
                ActionRow(id: "ic-\(f.id)", symbol: f.level == .good ? "checkmark.circle.fill" : f.level == .info ? "info.circle.fill" : "exclamationmark.triangle.fill",
                          tint: color, title: f.title, subtitle: f.level == .good ? nil : f.detail, info: f.detail, chevron: false) {}
            }
        }
    }
}

// MARK: - JIT and tunnel

struct ConnectionPage: View {
    @EnvironmentObject private var session: SessionController
    @State private var jitMethod = JITMethod.current
    @State private var hasPairing = BuiltinJIT.hasPairing
    @State private var pickPairing = false
    @State private var pairHere = false
    @State private var pairingMessage: String?
    @State private var resetDone = false
    @AppStorage("f4.advanced") private var advanced = false
    @AppStorage(TunnelManager.useLocalDevVPNKey) private var useLocalDevVPN = false
    @AppStorage(VPNGuard.askKey) private var vpnAsk = true
    @AppStorage(VPNGuard.shortcutKey) private var vpnShortcut = ""
    @AppStorage(VPNGuard.earlyKey) private var vpnEarly = true
    @AppStorage(CellularGuard.enabledKey) private var cellularAuto = true
    private let tunnel = TunnelManager.shared

    var body: some View {
        PageScaffold(title: "JIT and tunnel", symbol: "bolt.horizontal.fill") {
            InstallCheckGroup()
            SettingsGroup(title: "How JIT is switched on") {
                ChoiceRow(id: "cn-method", symbol: "bolt.fill", title: "JIT method", info: jitMethod.summary,
                          options: JITMethod.available.map { ($0, $0.title) }, selection: Binding(get: { jitMethod }, set: { jitMethod = $0; JITMethod.current = $0 }))
            }
            if jitMethod == .inApp {
                SettingsGroup(title: "Pairing file") {
                    ValueRow(id: "cn-pair-state", symbol: "key.fill", title: "Pairing file", value: hasPairing ? "Imported" : "Needed", statusColor: hasPairing ? Theme.good : Theme.warn)
                    ActionRow(id: "cn-pair-import", symbol: "square.and.arrow.down", title: hasPairing ? "Replace the pairing file" : "Import a pairing file",
                              info: "With a pairing file, Play turns the tunnel on, enables JIT, and turns the tunnel off again as soon as JIT is ready. It replaces any other VPN only during that short time.") { pickPairing = true }
                    if OnDevicePairing.isSupported {
                        ActionRow(id: "cn-pair-here", symbol: "iphone.gen3.radiowaves.left.and.right", title: "Get a pairing file on this device") { pairHere = true }
                    }
                    if let pairingMessage { Text(pairingMessage).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                }
            }
            if InstallCheck.hasTunnel {
            SettingsGroup(title: "Tunnel") {
                ToggleRow(id: "cn-localdev", symbol: "network", title: "Use LocalDevVPN instead",
                          info: "Does not start this app's own tunnel. LocalDevVPN (or another VPN with the same 10.7.0.x addresses) has to be switched on before you press Play; it keeps running while the game does. Turn this on if the app's own tunnel sometimes fails to come up. Off: the app starts and stops its own tunnel, which replaces any other VPN while it is on.",
                          isOn: $useLocalDevVPN)
            }
            SettingsGroup(title: "Your own VPN") {
                ToggleRow(id: "cn-vpn-ask", symbol: "questionmark.bubble.fill", title: "Ask before pausing it",
                          info: "iOS runs one VPN at a time, so Porthole's tunnel switches yours off while a game starts or an update installs. With this on, Porthole asks first.",
                          isOn: $vpnAsk)
                TextFieldRow(id: "cn-vpn-shortcut", symbol: "arrow.uturn.backward.circle.fill", title: "Shortcut to turn it back on", placeholder: "none",
                             info: "iOS does not let an app start another app's VPN. To get it back automatically: open the Shortcuts app, make a shortcut with one action, Set VPN (choose your VPN, then Connect), and type its exact name here. When your game closes or the update is done, Porthole runs it, then returns here. Leave this empty and Porthole just reminds you. A VPN with Connect On Demand switched on in its own app comes back by itself.",
                             text: $vpnShortcut)
                ToggleRow(id: "cn-vpn-early", symbol: "bolt.horizontal.circle.fill", title: "Turn it back on as soon as JIT is on",
                          info: "With a shortcut above, your VPN comes back right after JIT is switched on, before the game starts, instead of when the game closes. Use this on a network that blocks Steam, so the game's Steam sign-in goes through your VPN. Porthole leaves the app for a moment to run the shortcut, as it does for cellular data.",
                          isOn: $vpnEarly)
                ActionRow(id: "cn-vpn-make", symbol: "wand.and.stars", title: "Make the shortcut",
                          subtitle: "Opens Shortcuts. Add the action Set VPN, choose your VPN and Connect, then name it \u{201C}Porthole VPN\u{201D}.",
                          info: "Shortcuts can't be created for you: iOS only accepts shortcut files signed by Apple, and the Set VPN action has to point at your own VPN, which only you can pick. This opens a new, empty shortcut. Tap Add Action, search for Set VPN, choose your VPN and set it to Connect, then tap the name at the top and call it Porthole VPN. Porthole fills in that name for you.") {
                    if vpnShortcut.trimmingCharacters(in: .whitespaces).isEmpty { vpnShortcut = "Porthole VPN" }
                    if let url = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(url) }
                }
            }
            SettingsGroup(title: "Cellular data") {
                ToggleRow(id: "cn-cell-auto", symbol: "antenna.radiowaves.left.and.right", title: "Switch cellular data off when needed",
                          info: "Porthole's private connection (JIT, and installing an update on this device) does not work while cellular data is the network in use. It needs no internet, so with this on, Porthole asks, switches cellular data off for a few seconds with a Shortcut, and switches it back on as soon as it is done. On Wi-Fi nothing happens.",
                          isOn: $cellularAuto)
                ActionRow(id: "cn-cell-add", symbol: "square.and.arrow.down", title: "Add the two shortcuts",
                          subtitle: "In the share sheet choose Shortcuts, then Add Shortcut. Once for \u{201C}\(CellularGuard.offName)\u{201D}, once for \u{201C}\(CellularGuard.onName)\u{201D}.",
                          info: "iOS only lets an app switch cellular data through a Shortcut with the action Set Cellular Data. These two are bundled with Porthole, signed so iOS accepts them, and contain only that one action. Do not rename them.") {
                    CellularGuard.shared.addShortcuts()
                }
                ActionRow(id: "cn-cell-test", symbol: "play.circle", title: "Test the shortcuts",
                          subtitle: "Switches cellular data off and straight back on, once. Shortcuts may ask you to allow it the first time.",
                          info: "A quick check that both shortcuts are added and allowed, so the first real use does not stop to ask. It works on Wi-Fi too.") {
                    Task { await CellularGuard.shared.selfTest() }
                }
                ValueRow(id: "cn-cell-state", symbol: "checkmark.circle.fill", title: "Shortcuts",
                         value: CellularGuard.shared.paused ? "Cellular data is off" : (CellularGuard.shared.shortcutsHaveRun ? "Worked before" : "Not tried yet"),
                         statusColor: CellularGuard.shared.paused ? Theme.warn : (CellularGuard.shared.shortcutsHaveRun ? Theme.good : Theme.textDim))
                if let problem = CellularGuard.shared.lastProblem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            }
            }
            if InstallCheck.hasTunnel {
            SettingsGroup(title: "Troubleshooting") {
                ActionRow(id: "cn-reset", symbol: "arrow.counterclockwise", title: "Reset the tunnel", detail: resetDone ? "Done" : nil,
                          info: "If Play says the tunnel won't connect, this deletes the app's VPN setting and makes a fresh one. Your games and settings are not touched. iOS asks you to allow the VPN again.") {
                    Task {
                        await tunnel.resetConfiguration()
                        tunnel.message = "Reset. The next time you press Play, iOS asks you to allow the VPN again."
                        resetDone = true
                    }
                }
                if resetDone, let message = tunnel.message { Text(message).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
            }
            if advanced {
                SettingsGroup(title: "Status") {
                    ValueRow(id: "cn-jit", symbol: "bolt.fill", title: "JIT", value: session.jitEnabled ? "Enabled" : "Not enabled", statusColor: session.jitEnabled ? Theme.good : Theme.warn)
                    if !session.jitEnabled { ActionRow(id: "cn-jit-on", symbol: "power", title: "Enable JIT") { session.enableJIT() } }
                    ValueRow(id: "cn-tunnel", symbol: "network", title: "Tunnel", value: tunnel.statusText, statusColor: tunnel.isConnected ? Theme.good : Theme.textDim)
                    if tunnel.isConnected { ActionRow(id: "cn-tun-off", symbol: "power", title: "Turn the tunnel off") { tunnel.disconnect() } }
                    else { ActionRow(id: "cn-tun-on", symbol: "power", title: "Turn the tunnel on") { Task { do { try await tunnel.connect() } catch { tunnel.message = error.localizedDescription } } } }
                    if let message = tunnel.message { Text(message).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                }
            }
        }
        .sheet(isPresented: $pickPairing) {
            FilePickerSheet(onPick: { urls in
                pickPairing = false
                do { try BuiltinJIT.importPairing(from: urls[0]); pairingMessage = nil } catch { pairingMessage = "That is not a valid pairing file." }
                hasPairing = BuiltinJIT.hasPairing
            }, onCancel: { pickPairing = false })
        }
        .sheet(isPresented: $pairHere, onDismiss: { hasPairing = BuiltinJIT.hasPairing }) { PairOnDeviceView() }
    }
}

// MARK: - Steam

struct SteamSettingsPage: View {
    @ObservedObject private var steam = SteamStore.shared
    @Environment(AppRouter.self) private var router
    @AppStorage(SessionController.dockDesktopKey) private var dockDesktop = true
    @AppStorage(SessionController.cloudDownloadKey) private var cloudDownload = true
    @AppStorage("f4.advanced") private var advanced = false
    @State private var clientInstalled = MadeiraDock.clientInstalled
    @State private var clientBusy = false
    @State private var clientStatus: String?
    @State private var confirmSignOut = false
    @ObservedObject private var storage = ExternalLibrary.shared
    @AppStorage(ExternalLibrary.newDownloadsKey) private var newToSSD = false
    @State private var pickingFolder = false
    @State private var storageBusy = false
    @State private var storageError: String?

    private var storageState: String {
        if storage.checking { return "Checking\u{2026}" }
        switch storage.availability {
        case .available: return "Connected"
        case .readOnly: return "Read-only"
        case .disconnected: return "Not connected"
        case .permissionDenied: return "Access needed"
        case .identityMismatch: return "Different drive"
        }
    }

    var body: some View {
        PageScaffold(title: "Steam", symbol: "arrow.down.circle.fill") {
            SettingsGroup(title: "Account") {
                if steam.signedIn {
                    ValueRow(id: "st-account", symbol: "person.fill", title: "Signed in as", value: steam.accountName ?? "your account")
                    ActionRow(id: "st-library", symbol: "books.vertical.fill", title: "Open your Steam library") { router.openSteam() }
                    ActionRow(id: "st-out", symbol: "rectangle.portrait.and.arrow.right", title: "Sign out", destructive: true, chevron: false) { confirmSignOut = true }
                } else {
                    ValueRow(id: "st-account", symbol: "person.fill", title: "Account", value: "Not signed in")
                    ActionRow(id: "st-in", symbol: "person.badge.key.fill", title: "Sign in to Steam") { router.openSteam() }
                }
            }
            SettingsGroup(title: "Steam client") {
                ActionRow(id: "st-client", symbol: clientInstalled ? "checkmark.seal.fill" : "shield.lefthalf.filled", tint: clientInstalled ? Theme.good : Theme.warn,
                          title: "Steam client", subtitle: clientBusy ? (clientStatus ?? "Working\u{2026}") : (clientInstalled ? "Installed" : "Needed to start Steam games"),
                          detail: clientInstalled || clientBusy ? nil : "Download",
                          info: "Valve's own client files start your Steam games and check your licence. About 73 MB from Valve; nothing else is installed.", chevron: false) {
                    if !clientInstalled && !clientBusy { downloadClient() }
                }
                .disabled(!MadeiraDock.enabled)
            }
            SettingsGroup(title: "Steam Cloud") {
                ToggleRow(id: "st-cloud", symbol: "icloud.and.arrow.down.fill", title: "Download my cloud saves before a game starts",
                          info: "Before a game starts through Steam, Porthole downloads your own Steam Cloud files for it (such as world saves) if they are missing here. It only reads from Steam: nothing is uploaded, and a newer file on this device is never replaced.",
                          isOn: $cloudDownload)
            }
            SettingsGroup(title: "Game storage") {
                if let ssd = storage.external {
                    ValueRow(id: "st-ssd", symbol: "externaldrive.fill", title: ssd.name, value: storageState,
                             statusColor: storage.availability == .available ? Theme.good : Theme.warn)
                    if let problem = storage.problem, storage.availability != .available {
                        ValueRow(id: "st-ssd-why", symbol: "exclamationmark.triangle.fill", title: "Why", value: problem, statusColor: Theme.warn)
                    }
                    ToggleRow(id: "st-ssd-new", symbol: "arrow.down.to.line", title: "New downloads go to the SSD",
                              info: "A game you download from now on is saved on the SSD instead of the device. A game that is already installed (or half downloaded) stays where it is; Windows, Steam's client files and the usual Windows user folders stay on the device.",
                              isOn: $newToSSD)
                    ActionRow(id: "st-ssd-check", symbol: "arrow.triangle.2.circlepath", title: "Check the SSD connection", chevron: false) { Task { await storage.check() } }
                        .disabled(storage.checking || storageBusy)
                    ActionRow(id: "st-ssd-again", symbol: "folder.badge.gearshape", title: "Select the library folder again",
                              info: "Renews access to the same folder (after iOS forgot it). Choosing a different folder does not bring these games back.") { pickingFolder = true }
                        .disabled(storageBusy)
                } else {
                    ActionRow(id: "st-ssd-choose", symbol: "externaldrive.badge.plus", title: "Choose an SSD library folder",
                              info: "Pick a folder on a drive plugged into the device (a dedicated folder). Steam games you download to it keep their files, download progress and caches there. Cloud folders and network shares are not supported. If you unplug the drive during a game, the game ends.") { pickingFolder = true }
                        .disabled(storageBusy)
                }
                if let storageError { ValueRow(id: "st-ssd-err", symbol: "xmark.octagon.fill", title: "Problem", value: storageError, statusColor: Theme.warn) }
            }
            EpicSettingsGroup()
            if advanced {
                SettingsGroup(title: "Steam games window") {
                    ToggleRow(id: "st-desktop", symbol: "macwindow", title: "Use Wine's desktop display",
                              info: "On (recommended): Steam games run on a Wine virtual desktop, and touch and rotation work. Off is an experiment that draws the game straight into the app's game view. Applies the next time a game starts.",
                              isOn: $dockDesktop)
                }
            }
        }
        .confirm("Sign out of Steam?", message: "Your downloaded games stay on this device.", confirmTitle: "Sign out", destructive: true, isPresented: $confirmSignOut) { steam.signOut() }
        .sheet(isPresented: $pickingFolder) {
            ExternalFolderPicker { result in
                pickingFolder = false
                switch result {
                case .success(let url):
                    storageBusy = true
                    Task {
                        defer { storageBusy = false }
                        do { try await storage.register(url); storageError = nil; await storage.scan() }
                        catch { storageError = error.localizedDescription }
                    }
                case .failure(let failure): if !(failure is CancellationError) { storageError = failure.localizedDescription }
                }
            }
        }
        .task { if storage.external != nil { await storage.check() } }
    }

    private func downloadClient() {
        clientBusy = true; clientStatus = "Starting\u{2026}"
        Task {
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: AppModel.prefix) { text in await MainActor.run { clientStatus = text } }
                clientInstalled = MadeiraDock.clientInstalled
                clientStatus = clientInstalled ? nil : "The download finished but the client files are not in place."
            } catch { clientStatus = error.localizedDescription }
            clientBusy = false
        }
    }
}

// MARK: - Setup guide

struct SetupPage: View {
    @Environment(AppRouter.self) private var router
    @AppStorage("f4.setupDone") private var setupDone = false

    var body: some View {
        PageScaffold(title: "Setup guide", symbol: "checklist") {
            SettingsGroup {
                ValueRow(id: "su-state", symbol: "checkmark.circle.fill", title: "Status", value: setupDone ? "Finished" : "Not finished", statusColor: setupDone ? Theme.good : Theme.warn)
                ActionRow(id: "su-go", symbol: "play.circle.fill", title: setupDone ? "Go through setup again" : "Continue setup",
                          info: "A short walk-through of everything the app needs: JIT, the tunnel, signing for updates, and adding your first game.") { router.showSetup = true }
            }
        }
    }
}

/// Tips and guides: turn the short explanations on or off, show them again, or open one by hand.
struct GuidesPage: View {
    @State private var center = GuideCenter.shared

    var body: some View {
        @Bindable var center = center
        PageScaffold(title: "Tips and guides", symbol: "lightbulb.fill") {
            SettingsGroup(title: "Tips") {
                ToggleRow(id: "gd-on", symbol: "lightbulb.fill", title: "Show tips",
                          info: "A short explanation appears the first time you open a screen, and when you start your first game. The question mark at the top of every screen opens it again.", isOn: $center.enabled)
                ActionRow(id: "gd-reset", symbol: "arrow.counterclockwise", title: "Show all tips again",
                          info: "Every screen explains itself again the next time you open it, and the next game you start shows its short tour.", chevron: false) { center.resetAll() }
            }
            SettingsGroup(title: "Open a guide") {
                ForEach(GuideCatalog.all.filter { $0.id != GuideCatalog.inGame.id }) { guide in
                    ActionRow(id: "gd-\(guide.id)", symbol: guide.symbol, title: guide.title) { center.show(guide.id) }
                }
                ActionRow(id: "gd-ingame", symbol: GuideCatalog.inGame.symbol, title: "Playing a game", subtitle: "The tour shown before your first game", chevron: false) { center.tourReplay = true }
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @AppStorage("f4.advanced") private var advanced = false
    @AppStorage("f4.dumpSurfaces") private var dumpSurfaces = false
    @AppStorage("f4.wineDebug") private var wineDebug = ""
    @AppStorage(ExecutableWindow.defaultsKey) private var releaseExeWindow = true
    @AppStorage(ShortcutRouter.remoteKey) private var remoteLinks = false
    @AppStorage(ShortcutRouter.confirmKey) private var confirmLinks = true
    @State private var installer = VCRuntimeInstaller.shared

    var body: some View {
        PageScaffold(title: "Advanced", symbol: "wrench.and.screwdriver.fill") {
            SettingsGroup(title: "Windows components") {
                ActionRow(id: "ad-vc", symbol: installer.available ? "checkmark.seal.fill" : "shippingbox.fill", tint: installer.available ? Theme.good : Theme.warn,
                          title: "Visual C++ runtime", subtitle: vcSubtitle, detail: !installer.available && !installer.busy ? "Download" : nil,
                          info: "Microsoft's runtime that many games need. About 25 MB, downloaded from Microsoft's own installer and checked against a fixed fingerprint before anything is used. Without it some games won't start.", chevron: false) {
                    if !installer.available && !installer.busy { Task { await installer.install() } }
                }
                if case .downloading(let fraction) = installer.state { ProgressView(value: fraction).tint(Theme.accent).padding(.horizontal, 8) }
                if installer.installed {
                    ActionRow(id: "ad-vc-remove", symbol: "trash", title: "Remove the downloaded copy", destructive: true, chevron: false) { installer.remove() }
                }
            }
            SettingsGroup(title: "Options") {
                ToggleRow(id: "ad-tech", symbol: "slider.horizontal.3", title: "Show technical options",
                          info: "Shows swap and video memory, shader math, tunnel and JIT status, and technical readouts. Most people never need them.", isOn: $advanced)
                ToggleRow(id: "ad-pool", symbol: "memorychip", title: "Bigger code pool when the game allows it",
                          info: "The emulator keeps a stretch of memory free for the rare game that can only load at one fixed address. When none of a game's programs needs it, this gives it back so the code pool can be larger (fewer freezes in big games). Turn it off to go back to the previous behaviour if a game that started before no longer does.",
                          isOn: $releaseExeWindow)
            }
            SettingsGroup(title: "Links") {
                ToggleRow(id: "ad-confirm-link", symbol: "link.badge.plus", title: "Ask before a link starts a game",
                          info: "A porthole://play link (a Home Screen shortcut, a web page, another app) starts a game that is in your library. With this on, Porthole asks first, so a link you did not expect cannot start one. Links from a computer you have paired are not asked.",
                          isOn: $confirmLinks)
            }
            SettingsGroup(title: "Debugging") {
                ToggleRow(id: "ad-remote", symbol: "antenna.radiowaves.left.and.right", title: "Allow remote-control links",
                          info: "Lets porthole:// links stop an ended game, change one setting line of a game, or install the newest update. For testing from a computer (tools/ipad.sh). Leave off normally: any app or web page that can open a link could use them.",
                          isOn: $remoteLinks)
                ToggleRow(id: "ad-pics", symbol: "photo.on.rectangle", title: "Save window pictures",
                          info: "Saves a picture of every Windows window about every 2 seconds to Files > Porthole > surfdump. Use them to report a window that looks wrong. Leave off normally.", isOn: $dumpSurfaces)
                TextFieldRow(id: "ad-debug", symbol: "terminal.fill", title: "Wine debug channels", placeholder: "for example +msg",
                             info: "Advanced: records extra Wine messages in the log (for example +msg for window messages). Leave empty normally.", monospaced: true, text: $wineDebug)
            }
        }
    }

    private var vcSubtitle: String {
        switch installer.state {
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .unpacking: return "Checking and unpacking\u{2026}"
        case .failed(let message): return message
        case .idle: return installer.installed ? "Installed" : (installer.available ? "Included with this app" : "Not installed")
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @State private var licences = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        PageScaffold(title: "About and credits", symbol: "info.circle.fill") {
            SettingsGroup(title: "About Porthole") {
                ValueRow(id: "ab-version", symbol: "app.badge.fill", title: "Version", value: "\(version) (\(build))")
                ValueRow(id: "ab-bundle", symbol: "shippingbox.fill", title: "Bundle", value: Bundle.main.bundleIdentifier ?? "?")
                ActionRow(id: "ab-licences", symbol: "doc.plaintext.fill", title: "Licences and source code", subtitle: "Free software, GPL-3.0-or-later") { licences = true }
            }
            SettingsGroup(title: "Built on other people's work") {
                credit("madeira", "Madeira", "https://github.com/willfaust/Madeira", "The Windows-on-iPhone runtime this app is built on: Wine, FEX-Emu and DXMT, and Madeira Dock.")
                credit("iridium", "Iridium", "https://github.com/intraducine/iridium", "The idea of switching JIT on from inside the app with a helper extension.")
                credit("stik", "StikDebug", "https://github.com/StikDebug/StikDebug", "The debugger that enables JIT, with the StikJIT library.")
                credit("idevice", "idevice", "https://github.com/jkcoxson/idevice", "The device protocols behind pairing and installing.")
                credit("pair", "StikPair", "https://github.com/StikDebug/StikPair", "Showed how a pairing file can be made on the device itself.")
                credit("gl", "OpenGL support for Madeira", "https://github.com/c-gow/Madeira", "A Madeira fork whose OpenGL work Porthole builds on.")
                Text("Steam and its artwork belong to Valve. Epic Games, GOG, and every game or launcher you run belong to their owners. This app is not affiliated with or endorsed by any of them.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
        }
        .sheet(isPresented: $licences) { LicencesSheet() }
    }

    /// A project we took inspiration from: the row opens its page on GitHub.
    private func credit(_ id: String, _ name: String, _ link: String, _ what: String) -> some View {
        RowBase(id: "ab-\(id)", symbol: "heart.fill", tint: .pink, title: name, subtitle: what,
                action: { if let url = URL(string: link) { UIApplication.shared.open(url) } }) {
            Image(systemName: "arrow.up.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.textDim)
        }
    }
}
