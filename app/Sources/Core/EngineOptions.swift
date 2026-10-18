// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// One engine switch kept in madeira.cfg, shown on Settings > Engine options.
///
/// Nothing here is written until the person changes that row, and "Default" removes only that one key, so a line someone put in madeira.cfg by hand
/// stays exactly as it is until they touch its row. These keys are all ones Porthole did not offer before; the settings Porthole already has
/// (swap, what swap covers, video memory, audio buffer, precise math, resolution, power) are not in this list and are never written from here.
struct EngineOption: Identifiable {
    let key: String                                   // madeira.cfg key; "env.NAME" for an environment switch
    let title: String
    let symbol: String
    let info: String
    let choices: [(value: String, label: String)]     // value "" = the engine's own default (the key is removed)
    var id: String { key }

    static func on(_ label: String = "On") -> (String, String) { ("1", label) }
}

struct EngineOptionGroup: Identifiable {
    let title: String
    let options: [EngineOption]
    var id: String { title }
}

enum EngineOptions {
    // MARK: Storage

    /// The value in madeira.cfg ("" when unset).
    static func value(_ key: String) -> String { (MadeiraConfig.get(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Writes (or, for "", removes) one key. Called only from a row the person changed.
    static func set(_ key: String, _ value: String) {
        _ = MadeiraConfig.set(key, value.isEmpty ? nil : value)
        LogStore.shared.log("[engine-options] \(key) = \(value.isEmpty ? "(default)" : value)")
    }

    // MARK: The catalogue

    static let groups: [EngineOptionGroup] = [
        EngineOptionGroup(title: "Starting a game", options: [
            EngineOption(key: "env.MADEIRA_FAST_SERVER_START", title: "Start games sooner", symbol: "bolt.fill",
                         info: "Wine starts as soon as its server is ready, normally within a fraction of a second, instead of after a fixed 2 second pause. Off restores the pause.",
                         choices: [("", "Default (on)"), ("1", "On"), ("0", "Off")]),
            EngineOption(key: "pool", title: "JIT code pool", symbol: "memorychip",
                         info: "The memory reserved at launch for translated x86 code. The standard is 896 MB. A smaller pool leaves more memory for the game but large games can run out of room for code; a larger one needs a gap that the device may not have. Applies to the next start.",
                         choices: [("", "Default (896 MB)"), ("256", "256 MB"), ("512", "512 MB"), ("640", "640 MB"), ("768", "768 MB"), ("1024", "1 GB"), ("1152", "1.1 GB")]),
        ]),
        EngineOptionGroup(title: "Memory", options: [
            EngineOption(key: "totalphys", title: "Memory reported to games", symbol: "gauge.with.dots.needle.33percent",
                         info: "Some games size themselves from the physical memory Windows reports. This changes what they are told, not what the device has: a number above the real memory can make a game ask for more than it can get.",
                         choices: [("", "Default (the device)"), ("2048", "2 GB"), ("3072", "3 GB"), ("4096", "4 GB"), ("6144", "6 GB"), ("8192", "8 GB")]),
            EngineOption(key: "swap-min-mb", title: "Smallest block swap keeps", symbol: "square.stack.3d.down.right",
                         info: "The smallest allocation the swap file backs. Smaller values move more of a game's memory out of iOS's memory count but cost speed. 0 uses the engine's choice for each coverage mode.",
                         choices: [("", "Default"), ("1", "1 MB"), ("2", "2 MB"), ("4", "4 MB"), ("8", "8 MB"), ("16", "16 MB")]),
            EngineOption(key: "env.MADEIRA_SWAP_FEX", title: "Swap also keeps the emulator's memory", symbol: "externaldrive.badge.plus",
                         info: "The emulator's own working memory can reach 2 GB in a heavy game, nearly all of it cold, and iOS counts it against the app even when it sits compressed. Automatic starts using the swap file for it only once the app's memory reaches about 3 GB, so the game runs at full speed until it needs the room (a server world loading, say). On always puts it in the file from the start, which saves the most memory and slows the game the most. Both need Swap covers set to Wide and a big enough swap size (set swap-mb on the game's Engine page for more than 4 GB). If a game gets slower, stutters or stops working, turn it off. Applies to the next start.",
                         choices: [("", "Default (off)"), ("auto", "Automatic (when memory is tight)"), ("1", "Always (needs Wide)")]),
            EngineOption(key: "buffer-swap-kb", title: "Graphics buffers in the swap file", symbol: "externaldrive.fill.badge.icloud",
                         info: "Experimental. A game's meshes and other buffers are normally allocated by Metal and all counted against the app's memory limit (Rust: about 2 GB). This gives buffers at least this big memory backed by a file instead, which iOS does not count the same way. Needs a swap size (swap-mb) too. Smaller values move more buffers. Whether the graphics driver keeps the pages counted is what the first runs show: look for [bufswap] lines in the log.",
                         choices: [("", "Default (off)"), ("16", "16 KB and up"), ("32", "32 KB and up"), ("64", "64 KB and up"), ("256", "256 KB and up")]),
            EngineOption(key: "eco-qos", title: "Eco mode priority", symbol: "leaf.fill",
                         info: "The scheduling class game threads drop to while Eco mode is on. Background saves the most battery and heat and slows the game the most.",
                         choices: [("", "Default (utility)"), ("background", "Background"), ("initiated", "User initiated")]),
            EngineOption(key: "env.MADEIRA_X64_IMAGE_DATA", title: "Big x64 programs in the code pool", symbol: "memorychip.fill",
                         info: "Normally every x64 program file a game loads is also copied into the code pool, which spends pool space the size of the file (Far Cry 6's main file is 534 MB of it) on a copy nothing runs. Keep out of the pool leaves the copy out, so the pool has room for translated code and helper programs. Experimental: if a game stops working with it on, turn it off. Applies to the next start.",
                         choices: [("", "Default (copy into the pool)"), ("1", "Keep out of the pool (saves memory)")]),
            EngineOption(key: "env.MADEIRA_LAA_HIGH_IMAGES", title: "32-bit system libraries", symbol: "square.split.2x1",
                         info: "By default the 32-bit Windows system libraries (ntdll, kernel32 and the rest) load in the top half of a 32-bit program's address space, which leaves the lower half free for the program. Windows keeps them below 2 GB, and a program that patches system functions (some launchers do) can fail when they are not there. Below 2 GB takes address space from the program. Applies to 32-bit programs, from the next start.",
                         choices: [("", "Default (above 2 GB)"), ("0", "Below 2 GB (as on Windows)")]),
            EngineOption(key: "cpu-count", title: "CPU cores reported", symbol: "cpu",
                         info: "How many processor cores Windows programs are told about. Some games size their worker threads from it. A game with its own choice under Engine on its page uses that instead.",
                         choices: [("", "Default (the device)"), ("1", "1"), ("2", "2"), ("4", "4"), ("6", "6")]),
        ]),
        EngineOptionGroup(title: "OpenGL", options: [
            EngineOption(key: "gl-backend", title: "OpenGL driver", symbol: "cube.transparent",
                         info: "How games that draw with OpenGL are shown. Desktop OpenGL runs Mesa's Zink on MoltenVK (OpenGL 3.3 and up, needed by most games and by 32-bit ones). OpenGL ES uses Apple's own OpenGL ES 3.0 and fails games that insist on desktop OpenGL. Automatic picks desktop OpenGL when its files are in the app and falls back to OpenGL ES by itself if it cannot start. Applies to the next start.",
                         choices: [("", "Default (automatic)"), ("zink", "Desktop OpenGL (Zink)"), ("gles", "OpenGL ES")]),
            EngineOption(key: "env.MADEIRA_NO_GL", title: "OpenGL", symbol: "power",
                         info: "Off restores the engine's old behaviour: OpenGL calls fail and a game that needs OpenGL cannot draw. Use it to see whether OpenGL is what breaks a game. Applies to the next start.",
                         choices: [("", "Default (on)"), ("1", "Off")]),
            EngineOption(key: "env.MADEIRA_THIN_RESERVE", title: "Large address reservations", symbol: "rectangle.compress.vertical",
                         info: "Some games reserve address space in 1 GB blocks and use a few MB of each; after 8 GB of those the device runs out of address space. On gives the later ones only a small real part (the rest is never mapped, so a game that really uses it fails instead). Off keeps them whole.",
                         choices: [("", "Default (off)"), ("1", "On")]),
            EngineOption(key: "env.MADEIRA_AUDIO_IO_MS", title: "Audio buffer length", symbol: "waveform",
                         info: "How much sound iOS asks the app for at a time. A short buffer (5 ms) stops the gaps some games make when they send sound in small pieces, at a small cost in battery. Default leaves iOS's own length.",
                         choices: [("", "Default (iOS's own)"), ("5", "Short (5 ms)"), ("10", "10 ms"), ("20", "20 ms")]),
        ]),
        EngineOptionGroup(title: "Direct3D 12", options: [
            EngineOption(key: "ags-rewrite", title: "AMD 64-bit atomics rewrite", symbol: "arrow.triangle.2.circlepath",
                         info: "Rewrites the 64-bit atomic operations that games compiled for AMD cards use, so they run on this GPU. On by default; turn it off only to see whether it is what breaks a game.",
                         choices: [("", "Default (on)"), ("0", "Off")]),
            EngineOption(key: "async-submit", title: "Asynchronous submission", symbol: "rectangle.stack.badge.play",
                         info: "Submits command lists on a worker thread so the game can start its next frame sooner. Experimental.",
                         choices: [("", "Default (off)"), ("1", "On")]),
            EngineOption(key: "fence-chain", title: "GPU synchronisation", symbol: "link",
                         info: "How the GPU's work is ordered. The default is the accurate mode. Barrier-driven and fragment-stage are lighter; no fences is a test mode that flickers. In the game's menu the same setting can be changed live.",
                         choices: [("", "Default (accurate)"), ("6", "Barrier-driven"), ("5", "Fragment stage"), ("0", "No fences (test)")]),
            EngineOption(key: "d3d12-typed-uav-load", title: "Typed UAV loads", symbol: "square.grid.3x3.square",
                         info: "Tells games the GPU can read from typed unordered-access textures. Some engines need it; on others it moves the game onto a different render path.",
                         choices: [("", "Default (off)"), ("1", "On")]),
            EngineOption(key: "upload-swap", title: "Upload buffers on swap memory", symbol: "externaldrive.badge.icloud",
                         info: "Keeps Direct3D 12 upload buffers in the file-backed swap memory so they do not count against iOS's memory limit. On by default.",
                         choices: [("", "Default (on)"), ("0", "Off")]),
            EngineOption(key: "d3d12-core-dll", title: "Load d3d12core.dll", symbol: "shippingbox",
                         info: "For games that expect the Agility SDK's file layout and look for d3d12core.dll. Off by default because it changes how every Direct3D 12 game starts.",
                         choices: [("", "Default (off)"), ("1", "On")]),
        ]),
        EngineOptionGroup(title: "Graphics and media", options: [
            EngineOption(key: "d3d9", title: "Direct3D 9 for 32-bit games", symbol: "square.3.layers.3d",
                         info: "Emulated (the default) runs the Direct3D 9 layer translated like the game. Native runs it as native ARM code, which is faster but newer. Only 32-bit programs are affected.",
                         choices: [("", "Default (emulated)"), ("native", "Native ARM64")]),
            EngineOption(key: "env.MADEIRA_WG_VIDEO", title: "MP4 video in 32-bit games", symbol: "film",
                         info: "By default MP4 video with H.264 or HEVC plays through the device's video decoder. Off limits the media layer to MP3 and WAV, which is what to try if a game hangs on an intro video.",
                         choices: [("", "Default (on)"), ("0", "MP3 and WAV only")]),
            EngineOption(key: "env.MADEIRA_PROMOTE", title: "Hold the screen at its top refresh rate", symbol: "display",
                         info: "Keeps a ProMotion screen at 120 Hz for the whole game even when the game is capped at 60, which lets frames land sooner. Costs battery.",
                         choices: [("", "Default (off)"), ("1", "On")]),
        ]),
        EngineOptionGroup(title: "Controllers", options: [
            EngineOption(key: "env.MADEIRA_XINPUT", title: "Send controllers to games", symbol: "gamecontroller.fill",
                         info: "Game controllers paired with the device appear to games as Xbox controllers. Off hides every controller from games.",
                         choices: [("", "Default (on)"), ("0", "Off")]),
            EngineOption(key: "env.PORTHOLE_RUMBLE", title: "Controller rumble", symbol: "waveform.path",
                         info: "When a game asks a controller to vibrate, the controller does. Light, medium and strong scale how hard. Off ignores the game's rumble. Needs a controller with haptics, such as an Xbox or PlayStation pad. Applies the next time a game starts. Rumble does not work when player 1 is set to a HID controller below.",
                         choices: [("", "Default (on)"), ("50", "Light (50%)"), ("75", "Medium (75%)"), ("150", "Strong (150%)"), ("0", "Off")]),
            EngineOption(key: "env.PORTHOLE_PAD_MENU", title: "Open the menu with the controller", symbol: "line.3.horizontal.circle",
                         info: "Hold two buttons for half a second during a game to open Porthole's menu: Menu + View (Options + Create on a DualSense) by default, both stick clicks, or the PS / Xbox button (iOS keeps that one for itself on some controllers). The two buttons are kept from the game while you hold them. Off removes the shortcut; the menu then opens only with a swipe in from the right edge.",
                         choices: [("", "Default (Menu + View)"), ("l3r3", "Both stick clicks"), ("home", "PS / Xbox button"), ("off", "Off")]),
            EngineOption(key: "env.PORTHOLE_PAD_POINTER", title: "Pointer for the controller", symbol: "cursorarrow",
                         info: "When a controller moves the mouse (keyboard and mouse mode), an arrow is drawn where the pointer is, since a game running directly shows none of its own. It appears the first time the stick moves the pointer and stays; Hide when idle fades it after three seconds. Off draws nothing. Applies at once.",
                         choices: [("", "Default (always shown)"), ("autohide", "Hide when idle"), ("0", "Off")]),
            EngineOption(key: "env.PORTHOLE_STEAM_OVERLAY", title: "Steam overlay", symbol: "square.stack.3d.up.slash",
                         info: "Steam's in-game overlay hooks a game's graphics and searches for free executable memory next to every hook, which the engine refuses; in one log that went on for minutes. Default leaves the overlay alone. Off renames its DLLs (never deleting them) before a game starts. Applies the next time a game starts.",
                         choices: [("", "Default (leave it)"), ("0", "Off")]),
            EngineOption(key: "env.PORTHOLE_HIDE_TOUCH_ON_PAD", title: "Hide on-screen controls when a controller is used", symbol: "hand.raised.slash",
                         info: "While a controller is connected and being used, the on-screen buttons and sticks step aside. Touching the game screen brings them back until the controller is used again. The menu, pencil and keyboard buttons stay. Off keeps them on screen. Applies at once.",
                         choices: [("", "Default (on)"), ("0", "Off")]),
            EngineOption(key: "env.PORTHOLE_PAD_POINTER_UP", title: "Pointer arrow: move up", symbol: "arrow.up",
                         info: "Moves the controller's pointer arrow up by this many points if it is drawn a little below where the game's pointer really is. Only the arrow moves; clicks do not change. Applies at once.",
                         choices: [("", "Default (0)"), ("2", "2 points"), ("4", "4 points"), ("6", "6 points"), ("8", "8 points"), ("12", "12 points"), ("16", "16 points"), ("24", "24 points")]),
            EngineOption(key: "env.MADEIRA_PAD_MODE", title: "Controller type for player 1", symbol: "gamecontroller",
                         info: "Xbox (the default) shows every controller as an Xbox pad. The HID choices show player 1 as a DualSense or a generic gamepad instead, which some games need for their own button prompts. Applies to the next start.",
                         choices: [("", "Default (Xbox)"), ("hid", "HID (DualSense when it is one)"), ("dualsense", "Always a DualSense"), ("generic", "Always a generic gamepad")]),
            EngineOption(key: "env.MADEIRA_HIDPAD_XINPUT", title: "HID mode: keep Xbox too", symbol: "gamecontroller.fill",
                         info: "With a HID controller on, player 1 is also still shown as an Xbox pad. Off by default so a game that reads both does not see the same controller twice.",
                         choices: [("", "Default (off)"), ("1", "On")]),
            EngineOption(key: "env.MADEIRA_DINPUT_PAD", title: "DirectInput joystick", symbol: "dpad.fill",
                         info: "Also shows the controller as a DirectInput joystick, for old games that only look for one. Off by default because a game that reads both would see two controllers.",
                         choices: [("", "Default (off)"), ("1", "On")]),
            EngineOption(key: "env.MADEIRA_PAD_KBM", title: "Offer controller as keyboard and mouse", symbol: "keyboard",
                         info: "Makes the Controller choice on each game's page available, so a controller can drive a game that has no controller support. Off removes it.",
                         choices: [("", "Default (on)"), ("0", "Off")]),
        ]),
    ]

    /// The choices of `option` with the value currently in madeira.cfg added when it is not one of them (written by hand, say).
    static func choices(for option: EngineOption, current: String) -> [(String, String)] {
        var list = option.choices.map { ($0.value, $0.label) }
        if !current.isEmpty, !list.contains(where: { $0.0 == current }) { list.append((current, current)) }
        return list
    }
}

// MARK: - A game's own engine settings

/// What one game asks of the engine, on top of the app-wide settings. Every field is optional and nil means "leave the engine's own default";
/// at launch they are exported (or unset, so a previous game's choice never carries over) and the game's own madeira.cfg lines are written.
struct GameEngine: Codable, Equatable {
    var avx: Bool?                  // AVX and AVX2 through FEX's 128-bit emulation (MADEIRA_FEX_AVX)
    var frameGeneration: Bool?      // experimental MetalFX frame interpolation (MADEIRA_FRAMEGEN)
    var cpuCount: Int?              // cores reported to the program (MADEIRA_CPU_COUNT)
    var anisotropy: Int?            // Direct3D 9 anisotropic filtering limit (DXMT_D9_ANISO_LIMIT)
    var reducedX87: Bool?           // reduced-precision x87 (FEX_X87REDUCEDPRECISION): nil = the engine's own default, which is ON for 32-bit programs, so Off is exported as 0
    var largeReservations: Bool?    // a reservation of 64 GB or more that the address map cannot hold is served in part (madeira.cfg oversize-reserve, patch 0119 / PR 229)
    var workDir: String?            // working folder, a C:\ path
    var config: String?             // the game's own lines in madeira.cfg's syntax
    var controllerMode: String?     // nil = automatic (an Xbox pad, or keyboard and mouse for a game that never reads it, see PadAuto), "xbox" = always an Xbox pad, "keys" = keyboard and mouse, "dinput" = also a DirectInput joystick
    var padAuto: String?            // what automatic mode decided last run: "keys" when the game never read the controller (so the next run starts in keyboard and mouse)
    var binds: [String: String]?    // controller input -> action id (PadActions) for keyboard-and-mouse mode
    var padMouseVertical: Double?   // vertical speed of the right-stick mouse relative to horizontal
    var padRemap: [String: String]? // physical button -> the button the game sees (PadRemap), for the modes where the pad reaches the game as a controller
    var isEmpty: Bool { self == GameEngine() }
}

/// Applies a game's engine settings right before it starts, and the app-wide ones that need the app's help.
enum EngineLaunch {
    /// Exports this game's choices. Every variable is set or unset, so nothing from an earlier game stays.
    static func apply(for game: Game) {
        let e = game.engine ?? GameEngine()
        func flag(_ name: String, _ on: Bool?) { if on == true { setenv(name, "1", 1) } else { unsetenv(name) } }
        flag("MADEIRA_FEX_AVX", e.avx)
        flag("MADEIRA_FRAMEGEN", e.frameGeneration)
        // Frame generation shows two pictures per game frame, which only works when the screen can: tell it how fast the screen can go (the engine skips a frame it cannot show twice).
        if e.frameGeneration == true { setenv("MADEIRA_FRAMEGEN_HZ", String(UIScreen.main.maximumFramesPerSecond), 1) } else { unsetenv("MADEIRA_FRAMEGEN_HZ") }
        // Both states are exported: the WoW64 backend turns reduced precision ON when nothing sets it (PR 210), so "Off" has to say 0 or it does nothing for 32-bit games.
        if let x87 = e.reducedX87 { setenv("FEX_X87REDUCEDPRECISION", x87 ? "1" : "0", 1) } else { unsetenv("FEX_X87REDUCEDPRECISION") }
        // DXMT's memory census reports from the encode thread several times a second in a 64-bit game (a third of the log); once every 10 s unless madeira.cfg chooses (PR 244).
        if MadeiraConfig.get("env.DXMT_CENSUS_THROTTLE") == nil { setenv("DXMT_CENSUS_THROTTLE", "1", 1) }
        if let n = e.cpuCount, (1..<64).contains(n) { setenv("MADEIRA_CPU_COUNT", String(n), 1) } else { unsetenv("MADEIRA_CPU_COUNT") }
        if let n = e.anisotropy, [1, 2, 4, 8].contains(n) { setenv("DXMT_D9_ANISO_LIMIT", String(n), 1) } else { unsetenv("DXMT_D9_ANISO_LIMIT") }
        // The DirectInput joystick: only when the game's Controller choice asks for it.
        if e.controllerMode == "dinput" { setenv("MADEIRA_DINPUT_PAD", "1", 1) } else if MadeiraConfig.get("env.MADEIRA_DINPUT_PAD") == nil { unsetenv("MADEIRA_DINPUT_PAD") }
        if MadeiraConfig.get("env.MADEIRA_DINPUT_TRACE") == nil { unsetenv("MADEIRA_DINPUT_TRACE") }
        // The d3d9 choice of madeira.cfg reaches the 32-bit shim through MADEIRA_D3D9.
        let d3d9 = EngineOptions.value("d3d9")
        if d3d9.isEmpty { unsetenv("MADEIRA_D3D9") } else { setenv("MADEIRA_D3D9", d3d9, 1); LogStore.shared.log("[engine] D3D9 frontend: \(d3d9)") }
        // The game's own madeira.cfg lines; a game without any unsets the previous game's.
        do {
            // The game's own lines, with the switch's lines first: the game's text wins where both set a key (as in Madeira's gameConfigText).
            var own = e.config ?? ""
            if e.largeReservations == true { own = "oversize-reserve = 1\nfft-arena-patch = 1" + (own.isEmpty ? "" : "\n" + own) }
            // A known game's own lines (GameFixes), first: the person's text wins where both set a key. The app reads some of them before the runtime starts.
            if let fix = GameFixes.fix(forSteamAppID: game.dockAppID ?? game.steamAppID), !fix.configLines.isEmpty { own = fix.configLines.joined(separator: "\n") + (own.isEmpty ? "" : "\n" + own) }
            // A Unity game with Rewired's Windows.Gaming.Input plugin sees no controller unless the host pads are also gamepads (see GameFixes.usesRewiredWindowsGamingInput).
            if GameFixes.usesRewiredWindowsGamingInput(program: AppModel.unixURL(forWindows: game.exe)), !own.contains("MADEIRA_WGI_HOST_PADS") {
                own = "env.MADEIRA_WGI_HOST_PADS = 1" + (own.isEmpty ? "" : "\n" + own)
                LogStore.shared.log("[engine] Rewired's Windows.Gaming.Input plugin found: the controller is also offered as a Windows.Gaming.Input gamepad")
            }
            let pairs = try MadeiraConfig.applyGame(own.isEmpty ? nil : own)
            if !pairs.isEmpty { LogStore.shared.log("[game-cfg] " + pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        } catch {
            LogStore.shared.log("[game-cfg] this game's config could not be written: \(error.localizedDescription)")
        }
        // The `dxmt` lines of madeira.cfg and of the game's own config become DXMT_CONFIG, which is where the Direct3D 11 layer reads its options
        // (d3d11.mipClampBC, d3d11.preferredMaxFrameRate...). Nothing exported it before, so a `dxmt = ...` line was read, logged and ignored.
        // An `env.DXMT_CONFIG` line is exported later by the engine and still wins.
        let dxmt = dxmtConfig(MadeiraConfig.get("dxmt"), MadeiraConfig.gameValue("dxmt"))
        if dxmt.isEmpty { unsetenv("DXMT_CONFIG") } else {
            setenv("DXMT_CONFIG", dxmt, 1)
            LogStore.shared.log("[engine] DXMT config: \(dxmt)", level: dxmt.utf16.count > 259 ? .error : .info)
            if dxmt.utf16.count > 259 { LogStore.shared.log("[engine] the DXMT options are \(dxmt.utf16.count) characters; DXMT reads at most 259 and drops all of them, so shorten the dxmt lines", level: .error) }
        }
        let chosen = [e.avx == true ? "avx" : nil, e.frameGeneration == true ? "framegen" : nil, e.reducedX87.map { $0 ? "x87" : "x87=off" },
                      e.largeReservations == true ? "large-reservations" : nil,
                      e.cpuCount.map { "cpus=\($0)" }, e.anisotropy.map { "aniso=\($0)" }, e.controllerMode.map { "pad=\($0)" }].compactMap { $0 }
        if !chosen.isEmpty { LogStore.shared.log("[engine] this game: " + chosen.joined(separator: " ")) }
    }

    /// The DXMT_CONFIG value for the `dxmt` lines of madeira.cfg and of the game's config ("a=b;c=d"; ";" or a new line separates, "#" starts a comment piece), the game's after the app's.
    static func dxmtConfig(_ app: String?, _ game: String?) -> String {
        [app, game].compactMap { $0 }
            .flatMap { $0.split(whereSeparator: { $0 == ";" || $0.isNewline }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: ";")
    }

    /// A batch file (.bat or .cmd) runs through cmd.exe. Returns the program and arguments to start, or nil when the game is an ordinary program.
    static func batchCommand(for game: Game) -> (exe: String, args: String)? {
        let path = game.exe.lowercased()
        guard path.hasSuffix(".bat") || path.hasSuffix(".cmd") else { return nil }
        let extra = game.args.trimmingCharacters(in: .whitespaces)
        return ("C:\\windows\\system32\\cmd.exe", "/c \"\(game.exe)\"" + (extra.isEmpty ? "" : " " + extra))
    }

    /// The working folder to start in: the game's own choice when it has one (a C:\ folder), else nil (the program's own folder, as before).
    static func workDir(for game: Game) -> String? {
        guard let d = game.engine?.workDir?.trimmingCharacters(in: .whitespaces), d.count >= 3, d.prefix(3).uppercased() == "C:\\", !d.contains("..") else { return nil }
        return d
    }

    /// Set by the session for a Dock start that runs a launcher with its own service (Rockstar's): its copies of the Steam client's libraries and its own fill 896 MB.
    nonisolated(unsafe) static var launcherNeedsRoom = false

    /// The JIT pool size in bytes: madeira.cfg's `pool` (256 to 1152 MB), else the standard 896 MB (1152 MB when `launcherNeedsRoom`).
    static func poolBytes() -> Int {
        let standard = launcherNeedsRoom ? 1152 : 896
        let mb = Int(EngineOptions.value("pool")) ?? standard
        let chosen = (256...1152).contains(mb) ? mb : standard
        if chosen != 896 { LogStore.shared.log("[engine] JIT pool \(chosen) MB (\(EngineOptions.value("pool").isEmpty ? "a launcher with its own service is running" : "Settings > Engine options"))") }
        return chosen * 1024 * 1024
    }

    /// Waits until the wineserver has loaded its registry (at most 2 seconds, the old fixed pause), unless the option was turned off.
    static func waitForWineserver() {
        guard MadeiraConfig.flag("MADEIRA_FAST_SERVER_START") else { Thread.sleep(forTimeInterval: 2.0); return }
        let start = CFAbsoluteTimeGetCurrent()
        while wineserver_is_ready() == 0, wineserver_is_running() != 0, CFAbsoluteTimeGetCurrent() - start < 2.0 { Thread.sleep(forTimeInterval: 0.01) }
        LogStore.shared.log(String(format: "[launch] wineserver ready after %.0f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
    }
}

extension EngineOptions {
    /// Broad swap coverage used to be an Engine options row (madeira.cfg `swap-mode = 2`); it is now the "Broad" choice of Swap covers (UserDefaults `f4.swapCoverage`).
    /// A line left by the old row would keep forcing Broad whatever Swap covers says, and nothing would show it, so it moves into the setting (when none was chosen)
    /// and the line goes. Returns true when a line was removed.
    @discardableResult
    static func migrateSwapMode(defaults: UserDefaults = .standard) -> Bool {
        guard MadeiraConfig.get("swap-mode") == "2" else { return false }
        if defaults.string(forKey: "f4.swapCoverage") == nil, (MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") ?? "").isEmpty {
            defaults.set("broad", forKey: "f4.swapCoverage")
        }
        return MadeiraConfig.set("swap-mode", nil)
    }
}
