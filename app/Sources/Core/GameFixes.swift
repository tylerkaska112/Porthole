// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Known problems with particular games, and the small, reversible workaround for each. Applied just before the game starts (see SessionController.start).
/// A workaround here only ever hides a file in that game's own folder; nothing of the game is changed or deleted. docs/GAME_FIXES.md lists them.
enum GameFixes {
    struct Fix: Equatable {
        let steamAppID: Int
        let title: String
        /// Files, relative to the folder the game's program is in, that are set aside (renamed with `disabledSuffix`) before the game starts.
        var hide: [String]
        /// Files an earlier build of this fix set aside and that must come back (the workaround turned out to do harm); put back on every launch.
        var formerlyHidden: [String] = []
        let why: String
        /// Libraries Wine must refuse to load for this game (`WINEDLLOVERRIDES=name=`). Refused before anything is copied into the emulator's code pool.
        var blockLoading: [String] = []
        /// A program in the same folder to start instead of the one Steam lists (a launcher the game does not need), when the game is started without Steam.
        var directProgram: String? = nil
        /// The game cannot work through Steam's launch (its launcher needs software Porthole does not have), so it always starts directly.
        var alwaysDirect = false
        /// When started without Steam, tell the game its own Steam app id and install folder instead of the fixed placeholder identity the runtime otherwise publishes.
        var ownSteamIdentity = false
        /// A program in the same folder to start NEXT TO Valve's signed-in client instead of asking the client to launch the game (Steam stays up, the program finds it).
        /// For a game whose listed program cannot run here but whose own program can. The Dock host only accepts a .exe inside the app's verified install folder.
        var steamProgram: String? = nil
        /// The game's Chromium helper programs (a launcher's web UI) want a 32 GB address-space pool aligned to 32 GB; this moves the emulator's band out of the
        /// way so they can have one (patch 0105, `pa-pool32-soft`). Only for games that need it: it changes the address-space layout.
        var paPool32 = false
        /// Rockstar's launcher only: its web host (SocialClubHelper.exe) runs as one process (`MADEIRA_ROCKSTAR_SINGLE_PROCESS`). Other games with Chromium inside do not need it.
        var singleProcessWeb = false
        /// Chromium's allocator inside the game itself (BeamNG.drive): the game's own process gets the glued PartitionAlloc pools Social Club's helper gets
        /// (`MADEIRA_SC_PA_POOLS = 1` moves the emulator's arena at start; patch 0152, `MADEIRA_GLUED_MAIN`).
        var gluedPools = false
        /// Lines added to the game's own madeira.cfg text (the game's own lines win where both set a key). The app reads some of them before the runtime starts.
        var configLines: [String] = []
        /// Automatic mode keeps the Xbox pad for this game even when a PlayStation controller is held (no DualSense identity): its input layer reads Xbox gamepads only.
        var xboxPad = false

        /// The value for WINEDLLOVERRIDES, e.g. "avrt=;foo=".
        var overridesValue: String { blockLoading.map { $0 + "=" }.joined(separator: ";") }
    }

    static let disabledSuffix = ".porthole-disabled"

    static let known: [Fix] = [
        Fix(steamAppID: 242760, title: "The Forest",
            hide: ["TheForest_Data/Plugins/OVRPlugin.dll", "TheForest_Data/Mono/OVRPlugin.dll"],
            why: "The emulator's code pool (624 MB) only gets space back when a whole emulated process exits. Unity tried to load the Oculus VR plugin six times (it can never load here) at about 28 MB each, and its short-lived threads each load and unload avrt.dll (about 0.5 MB each, hundreds of times), until the pool was full and the game froze.",
            blockLoading: ["avrt"]),
        Fix(steamAppID: 244210, title: "Assetto Corsa",
            hide: [],
            why: "AssettoCorsa.exe, the program Steam lists, is a .NET launcher. Porthole has no .NET (Wine reports \"Wine Mono is not installed\" and the program exits at once), and Steam's own launch hits the same program. The game itself is acs.exe in the same folder, so Porthole starts that directly.",
            directProgram: "acs.exe", alwaysDirect: true, ownSteamIdentity: true),
        Fix(steamAppID: 252490, title: "Rust",
            hide: [],
            why: "Valve's client starts Rust.exe, which starts Easy Anti-Cheat; that does not run here. RustClient.exe is the game itself and plays on servers that do not require Easy Anti-Cheat. Steam's own client stays signed in (so the game's Steam library finds it) and RustClient.exe is started next to it, the way double-clicking it with Steam open does on a PC. Started without Steam at all, the game stalled at 99 % loading.",
            steamProgram: "RustClient.exe"),
        Fix(steamAppID: 1174180, title: "Red Dead Redemption 2",
            hide: [],
            why: "Rockstar's launcher shows its pages with Chromium (SocialClubHelper.exe). Its memory allocator wants a 32 GB address-space pool aligned to 32 GB, which the emulator's band at the top of the address space prevents: every helper stopped at start and the launcher said it timed out loading its content. The band is moved so the pool fits.",
            paPool32: true, singleProcessWeb: true),
        Fix(steamAppID: 3405340, title: "Megabonk",
            hide: [],
            why: "Megabonk is Unity (IL2CPP): its garbage collector stops the game's other threads, which needs real thread suspension (MADEIRA_REAL_SUSPEND); without it the game does not start. Its controller input is Rewired with the Windows.Gaming.Input plugin, which only asks for gamepads and found none (the Xbox pad had no HID device, a DualSense is a raw game controller), so the host pads are listed as gamepads (MADEIRA_WGI_HOST_PADS, also set for every Rewired game, see usesRewiredWindowsGamingInput).",
            configLines: ["env.MADEIRA_REAL_SUSPEND = 1", "env.MADEIRA_WGI_HOST_PADS = 1"], xboxPad: true),
        Fix(steamAppID: 284160, title: "BeamNG.drive",
            hide: [], formerlyHidden: ["Bin64/D3DCOMPILER_47.dll"],
            why: "BeamNG.drive has Chromium's allocator inside the game (its user interface). That allocator asks for a 32 GB pool aligned to 32 GB, frees the three answers it cannot use because they are only 16 GB aligned, asks for 64 GB less 64 KB to align it itself, and the game stops with 0x80000003 (STATUS_BREAKPOINT) when that is refused. The game program has its own switch for this (read from its 0.39.4 program, 2026-10-16: -forceUltralight makes it build its menus on Ultralight, a one-process renderer, and never start Chromium), so Madeira appends it to the game's command line (MADEIRA_CHILD_ARGS). Before that: with --single-process the game's Chromium still started a GPU process, which is refused (one Chromium process is all the address space holds), and Chromium then ended with \"GPU process isn't usable\" (2026-10-16 02:31): the same switches Madeira gives Rockstar's and Ubisoft's launchers (--disable-gpu, --disable-gpu-compositing) did not stop it (2026-10-16 02:37: the GPU process and the network and storage services were still started as children, and refused), so the GPU runs in the process (--in-process-gpu) and the network and storage services are asked to as well. Its helper processes (the interface runs in several, each a full copy of the 47 MB game program) filled the emulator's code pool at the fifth one (EXHAUSTED, 0xc0000017, 2026-10-16 02:19), so plain 64-bit programs now run from their loaded image without a pool copy (MADEIRA_X64_IMAGE_NOCOPY, part of Madeira's Red Dead Redemption 2 recipe). The game now gets the layout Madeira built for Rockstar's Social Club (also Chromium with several allocators in one process): a real slot for each 32 GB block, the emulator's arena moved 4 GB up and the JIT pool's alias moved, all at start. (The other layout, pa-pool32-soft, was tried on a device on 2026-10-16 and refuses the ask sooner.) (Wine's own shader compiler cannot read the game's material shaders, so the game keeps its own.)",
            gluedPools: true, configLines: ["env.MADEIRA_SC_PA_POOLS = 2", "env.MADEIRA_X64_IMAGE_NOCOPY = 1", "env.MADEIRA_CAGE_RELEASE = 1", "env.MADEIRA_LOCK_ORPHAN = 0", "env.MADEIRA_CHILD_ARGS = BeamNG.drive.x64.exe -forceUltralight -flushLogErrors -logeverything", "env.MADEIRA_SC_CEF_FLAGS = --in-process-gpu --disable-gpu --disable-gpu-compositing --enable-features=NetworkServiceInProcess,NetworkServiceInProcess2 --disable-features=PartitionAllocBackupRefPtr,StorageServiceOutOfProcess"]),
    ]

    /// The game is a Unity game with Rewired's Windows.Gaming.Input plugin (`<name>_Data/Plugins/x86_64/Rewired_WindowsGamingInput.dll`). Rewired asks Windows.Gaming.Input for
    /// `Gamepad` objects only, which Wine lists for HID devices alone; the pad Porthole publishes is an XInput slot, so the game saw no controller in any mode but keyboard and mouse
    /// (Megabonk, 2026-10-16). Such a game gets `env.MADEIRA_WGI_HOST_PADS = 1` (every XInput slot is also a gamepad) and the Xbox pad instead of the DualSense identity.
    static func usesRewiredWindowsGamingInput(program: URL?, fileManager fm: FileManager = .default) -> Bool {
        guard let folder = program?.deletingLastPathComponent(), let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        for data in names where data.lowercased().hasSuffix("_data") {
            for plugins in ["Plugins/x86_64", "Plugins/x86", "Plugins"] {
                let dir = folder.appendingPathComponent(data).appendingPathComponent(plugins)
                if let files = try? fm.contentsOfDirectory(atPath: dir.path), files.contains(where: { $0.caseInsensitiveCompare("Rewired_WindowsGamingInput.dll") == .orderedSame }) { return true }
            }
        }
        return false
    }

    static func fix(forSteamAppID id: Int?) -> Fix? {
        guard let id, id > 0 else { return nil }
        return known.first { $0.steamAppID == id }
    }

    /// Sets the fix's files aside inside `folder`. Returns what was done, one line each, for the log. Safe to run on every launch: files already set aside are left alone,
    /// and a file that came back (the game was updated or verified) is set aside again. Paths that would leave `folder` are refused.
    @discardableResult
    static func hide(_ fix: Fix, in folder: URL, fileManager fm: FileManager = .default) -> [String] {
        var done: [String] = []
        let root = folder.standardizedFileURL.path
        for relative in fix.hide {
            let url = resolvedIgnoringCase(relative, in: folder, fileManager: fm).standardizedFileURL
            guard url.path.hasPrefix(root + "/") else { done.append("refused \(relative): outside the game folder"); continue }
            guard fm.fileExists(atPath: url.path) else { continue }
            let aside = URL(fileURLWithPath: url.path + disabledSuffix)
            do {
                if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
                try fm.moveItem(at: url, to: aside)
                done.append("set aside \(relative)")
            } catch {
                done.append("couldn't set aside \(relative): \(error.localizedDescription)")
            }
        }
        return done
    }

    /// `relative` under `folder`, with each part matched to the real name on disk ignoring case (Windows would; the game folder's files keep the case Steam wrote).
    static func resolvedIgnoringCase(_ relative: String, in folder: URL, fileManager fm: FileManager = .default) -> URL {
        var url = folder
        for part in relative.split(separator: "/").map(String.init) {
            if let names = try? fm.contentsOfDirectory(atPath: url.path),
               let hit = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                url = url.appendingPathComponent(hit)
            } else {
                url = url.appendingPathComponent(part)
            }
        }
        return url
    }

    /// The file called `name` in the same folder as `program`, if it exists (compared ignoring case, as Windows would).
    static func sibling(named name: String, of program: URL, fileManager fm: FileManager = .default) -> URL? {
        let folder = program.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
              let hit = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return folder.appendingPathComponent(hit)
    }

    /// `windowsPath` with its last component replaced ("C:\\a\\b.exe" + "c.exe" -> "C:\\a\\c.exe").
    static func windowsPath(replacingLastComponentOf windowsPath: String, with name: String) -> String {
        var parts = windowsPath.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return windowsPath }
        parts[parts.count - 1] = name
        return parts.joined(separator: "\\")
    }

    /// Puts back the files an earlier build set aside for this game (`formerlyHidden`).
    @discardableResult
    static func restoreFormer(_ fix: Fix, in folder: URL, fileManager fm: FileManager = .default) -> [String] {
        guard !fix.formerlyHidden.isEmpty else { return [] }
        var copy = fix; copy.hide = fix.formerlyHidden
        return restore(copy, in: folder, fileManager: fm)
    }

    /// Puts the fix's files back.
    @discardableResult
    static func restore(_ fix: Fix, in folder: URL, fileManager fm: FileManager = .default) -> [String] {
        var done: [String] = []
        for relative in fix.hide {
            let aside = resolvedIgnoringCase(relative + disabledSuffix, in: folder, fileManager: fm)
            let url = URL(fileURLWithPath: String(aside.path.dropLast(disabledSuffix.count)))
            guard fm.fileExists(atPath: aside.path), !fm.fileExists(atPath: url.path) else { continue }
            do { try fm.moveItem(at: aside, to: url); done.append("restored \(relative)") }
            catch { done.append("couldn't restore \(relative): \(error.localizedDescription)") }
        }
        return done
    }
}
