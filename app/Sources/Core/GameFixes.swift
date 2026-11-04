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
        /// Madeira's own Social Club layout for Rockstar's launcher (`MADEIRA_SC_PA_POOLS`, 1 or 2): the web helper's Chromium pools are real memory, set aside when the runtime
        /// starts. It is what Madeira's tested Red Dead Redemption 2 list uses (layout 2); Porthole's earlier soft pools (`paPool32`) are bypassed once that handling is on.
        var scPaPools: Int? = nil
        /// Lines added to the game's own madeira.cfg text (the game's own lines win where both set a key). The app reads some of them before the runtime starts.
        var configLines: [String] = []
        /// Keep the 128 MB executable window at 0x140000000 (patch 0016 would give it back for a bigger pool). Madeira's own list for the game (pool-low, pool-split, pool-mid) is built
        /// around the window being held: with it given back the app ended seconds after launch (1.2.8 and 1.2.20); with it held BCD 0.1.573's log has the game running (2026-10-19 08:01).
        var keepExeWindow = false
        /// Folders under drive_c (Windows paths) deleted before every start, for state a program saves in its first successful run that breaks the next one. Red Dead Redemption 2
        /// (2026-10-30): after Rockstar's launcher and Social Club had saved their sign-in state the game said "Activation error: your Social Club account is not entitled" although Rockstar's
        /// servers answered yes; with these folders gone the first start worked. The launcher asks for the Social Club sign-in anyway, so nothing is lost but its cached pages.
        var freshFolders: [String] = []
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
            why: "Rockstar's launcher shows its pages with Chromium (SocialClubHelper.exe). Its memory allocator wants a 32 GB address-space pool aligned to 32 GB and V8 asks for a 16 GB sandbox; without them every helper stops at start (exit 0x80000003) and the launcher restarts it every 5 seconds and never starts the game. Madeira's own Social Club layout (MADEIRA_SC_PA_POOLS = 2, with the 8 GB address-space hold of its tested list) gives the helper real pools. Porthole's earlier soft pools stopped working once the engine took Madeira's Social Club handling (the helper no longer reaches them: device logs 2026-10-19), so they are off for this game.",
            scPaPools: 2, configLines: [
                          // 2026-10-19 (1.2.26): Madeira's own tested list for this game as BCD 0.1.573 ships it (recommended/recommendations.json, rdr2-steam v10), whose log
                          // (08:01) has the game running on this iPad, with the executable window held (keepExeWindow) so pool-low / pool-split / pool-mid have the layout they
                          // were written for. 1.2.8 used the same keys with the window given back and ended seconds after launch; 1.2.9-1.2.25 used a few of them one by one.
                          "d3d12-caps-log = 2", "d3d12-shader-pack = 1", "replay-split = 1", "ring-share = 1",
                          "pool = 896", "pool-low = 1", "pool-mid = 1", "pool-page-fit = 1", "pool-split = 1",
                          "vram-mb = 2304", "swap-mb = 8192", "swap-mode = 2", "swap-min-mb = 1", "swap-images = 1",
                          "pso-warm = 2", "fence-chain = 6", "avail-phys = 1", "indirect-fast = 1", "ind-probe = 0", "fullscreen-window = 1",
                          "env.WINE_D3D_CONFIG = renderer=no3d", "env.FEX_VECTORTSOENABLED = 0", "env.MADEIRA_BAND_CENSUS = 1",
                          "env.MADEIRA_SC_PA_POOLS = 2", "env.MADEIRA_RDR2_VA_HOLD = 1", "env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216",
                          "env.MADEIRA_THREAD_STACK_SPILL = 1", "env.MADEIRA_SMALL_STACK_EXES = RDR2.exe",
                          "env.MADEIRA_D3D11_SRC = 1", "env.MADEIRA_DXGI_SRC = 1", "env.MADEIRA_DXGI_BUDGET_EVENTS = 1",
                          "env.MADEIRA_DOCK_GAME_SCM = 1", "env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;RDR2.exe",
                          "env.DXMT_WSI_MONITOR_IDENTITY = 1", "env.DXMT_WSI_MODE_TABLE = 1", "env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe",
                          "env.MADEIRA_EXECREQ_LEAVE = 1", "env.MADEIRA_LOCK_ORPHAN = stamped", "env.MADEIRA_PIN_GRAPHICS_DLLS = 1",
                          "env.MADEIRA_PRELOAD_DLLS = xinput1_4.dll",
                          "env.MADEIRA_POOL_HEAD_RESERVE_MB = 128", "env.MADEIRA_POOL_LOW_IMAGES = 1", "env.MADEIRA_POOL_RECYCLE_IMAGES = 1",
                          "env.MADEIRA_TOUCH_MOUSE = 1", "env.MADEIRA_WOW_MIN_FREE_GB = 2", "env.MADEIRA_X64_GRAPHICS_ENTRY = 1", "env.MADEIRA_X64_IMAGE_NOCOPY = 1",
                          "env.WINEDLLOVERRIDES = video64=",
                          // Ours, not in their list: dllhost.exe and the game's crash reporter are refused (arena: ~1 GB / ~10 threads), the per-thread lookup cache reserves 2 MB
                          // (patch 0168), and the launcher's, Social Club's and the helper's logs are mirrored into the session log (up to 4000 lines).
                          "env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist;dllhost.exe;crashpad_handler",
                          "env.MADEIRA_FEX_HOTL1 = 0",
                          // Diagnostic (1.2.66): the pixel shader of the game's text draws; a frame capture (in-game menu > Tools) then also logs the descriptor tables of up to 8 such draws and
                          // puts every texture they sample on the contact sheet, to see whether the UI's textures are empty or the sampling is wrong. Costs nothing outside a capture.
                          "capture-ps = mdc_187416feb2fb7a9e",
                          "env.MADEIRA_GUEST_LOG = all", "env.MADEIRA_GUEST_LOG_LIMIT = 4000"], keepExeWindow: true),
        Fix(steamAppID: 311210, title: "Call of Duty: Black Ops III",
            hide: [],
            why: "Not playable yet. Its copy protection (Arxan) needs the 491 MB exe at its own address 0x140000000, where the engine's code pool sits. Moved elsewhere it either spins forever in a closed ring (header says the old address) or, with the header corrected (MADEIRA_FIX_IMAGEBASE=blackops3.exe, patch 0170), runs about 20 s and jumps through absolute addresses that were never adjusted (blackops3.exe+0x14deaea1 in logs of 2026-10-22). Fixing it means loading the exe at 0x140000000 with a smaller pool around it.",
            configLines: []),
        Fix(steamAppID: 3405340, title: "Megabonk",
            hide: [],
            why: "Megabonk is Unity (IL2CPP): its garbage collector stops the game's other threads, which needs real thread suspension (MADEIRA_REAL_SUSPEND); without it the game does not start. Its controller input is Rewired with the Windows.Gaming.Input plugin, which only asks for gamepads and found none (the Xbox pad had no HID device, a DualSense is a raw game controller), so the host pads are listed as gamepads (MADEIRA_WGI_HOST_PADS, also set for every Rewired game, see usesRewiredWindowsGamingInput).",
            configLines: ["env.MADEIRA_REAL_SUSPEND = 1", "env.MADEIRA_WGI_HOST_PADS = 1"], xboxPad: true),
        Fix(steamAppID: 3259780, title: "FINAL FANTASY RESONANCE",
            hide: [],
            why: "FINAL FANTASY RESONANCE and its demo run the same way. The first program (FFRS.exe) is an x64 Unreal Engine start-up that checks for Microsoft's Visual C++ 2015-2022 runtime. Windows reports an ARM64 machine here, so it asks for the ARM64 version and stops with \"The following component(s) are required to run this program: Microsoft Visual C++ 2015-2022 Redistributable (arm64)\". `env.MADEIRA_VCRT_ARM64_KEY = 1` writes the marker that says it is installed (for the session only, nothing is saved in the prefix). The program it then starts, FFRS/Binaries/Win64/FFRS-Win64-Shipping.exe, is 487 MB, loads at 0x140000000 and has no relocations, so the executable window there has to stay with it (ExecutableWindow now reads the folders below the main program too; before, the demo ended with status c0000018 \"failed to create main module\"), and `env.MADEIRA_X64_IMAGE_NOCOPY = 1` keeps a pool copy of it out of the code pool, as Madeira's tested list for the demo does. With the window kept, the largest single stretch left for the code pool is 400 to 630 MB depending on where iOS put the main thread's stack on that start (a Steam game needs 640 MB: 'iOS left too little room', 416 MB of 896 MB), so `pool-split = 1`, as Madeira's lists for Minecraft Dungeons II and Red Dead Redemption 2 use, adds a second stretch above the stack to make up the rest. From a user's logs (2026-11-03): the full game on 1.1.0 stopped at the dialog; the demo on 1.2.86 got past it and then failed to map the program. Not yet confirmed on a device after the change.",
            configLines: ["env.MADEIRA_VCRT_ARM64_KEY = 1", "env.MADEIRA_X64_IMAGE_NOCOPY = 1", "pool-split = 1"]),
        Fix(steamAppID: 4474710, title: "FINAL FANTASY RESONANCE DEMO",
            hide: [],
            why: "The demo of FINAL FANTASY RESONANCE, which starts and runs exactly like the full game (same program, same two workarounds): see the entry above.",
            configLines: ["env.MADEIRA_VCRT_ARM64_KEY = 1", "env.MADEIRA_X64_IMAGE_NOCOPY = 1", "pool-split = 1"]),
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
