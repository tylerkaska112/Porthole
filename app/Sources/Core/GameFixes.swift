// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Known problems with particular games, and the small, reversible workaround for each. Applied just before the game starts (see SessionController.start).
/// A workaround here only ever hides a file in that game's own folder (nothing of the game is changed or deleted), or adds a line to a text file the game itself reads for start options (`textFiles`, GTA V Legacy's commandline.txt; the person's own lines stay). docs/GAME_FIXES.md lists them.
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
        /// Start options for `steamProgram` (put before the ones the person typed for the game).
        var steamProgramArgs: String? = nil
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
        /// Lines a program reads from a text file of its own in its folder (GTA V's `commandline.txt` takes its start options): path under the game folder -> the lines to be in it.
        /// A missing file is made, an existing one gets any of the lines it lacks appended; the person's own lines stay.
        var textFiles: [String: [String]] = [:]
        /// Lines an earlier build of the fix put into a text file that must go again (the rest of the file stays; a file left empty is deleted).
        var textLinesRemoved: [String: [String]] = [:]
        /// The swap file's coverage this game starts with when the person has not set one for the game (the app-wide choice does not override it). Grand Theft Auto V Enhanced: broad.
        var swapCoverage: String? = nil

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
        Fix(steamAppID: 3240220, title: "Grand Theft Auto V Enhanced",
            hide: [],
            why: "Like Red Dead Redemption 2 it starts through Rockstar's launcher, whose pages are shown by SocialClubHelper.exe. On 2026-11-04 the launcher's own page never loaded (\"Timed out waiting for browser window\", SC_INIT_ERR_WEBSITE_FAILED_LOAD) although Madeira's tested setup and the helper fix for Social Club 2.4.0.296 were in force; the Red Dead Redemption 2 launcher that does load has a few more launcher settings, added here as a test: small graphics rings for the launcher and its helper, the window-system tables, one FEX cache switch off and thread-stack spill. Madeira's tested setup for the game still applies (its own lines win where both set a key). 1.2.133 (the second run showed the same 31 s cut-off against a 35-36 s start): the launcher gets a slower clock (madeira.cfg slow-clock = Launcher.exe:0.4), which stretches its 31 s wait to about 75 s; the helper and the game are unchanged. 1.2.133 slowed only the system-call counter and the log showed the wait still ended after 30 s, because the Windows-side ntdll reads the processor's timer directly for QueryPerformanceCounter; 1.2.134 makes the named program use the system-call counter (env.MADEIRA_SLOW_CLOCK, read by ntdll.dll). Look for [slow-clock] lines in the log.",
            scPaPools: 2, configLines: [
                          "env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe",
                          "env.DXMT_WSI_MONITOR_IDENTITY = 1", "env.DXMT_WSI_MODE_TABLE = 1",
                          "env.MADEIRA_FEX_HOTL1 = 0", "env.MADEIRA_THREAD_STACK_SPILL = 1",
                          // 1.2.133: the launcher waits 31 s for the helper's first window and two runs (2026-11-04) showed the helper needs 35-36 s. The launcher's own clock and its waits of 1 s or more run at 0.4 (75 s); the helper and the game keep real time.
                          "slow-clock = Launcher.exe:0.4", "env.MADEIRA_SLOW_CLOCK = Launcher.exe:0.4",
                          // 2026-11-08 (three Enhanced logs, 1.3.90): this entry had no Social Club memory layout. Without it every SocialClubHelper.exe stopped at start in chrome_elf.dll (13-17 times),
                          // the launcher timed out, and each dead helper left memory behind until the app was at 5.9 GB and iOS closed it. With Madeira's own list applied (layout 2) the helper survived. These
                          // are the lines of Madeira's tested list (gta5e-steam v10) that concern the launcher, the code pool and threads, plus the thread-arena switches the Legacy entry uses.
                          "pool-low = 1", "pool-page-fit = 1", "pool-split = 1",
                          "env.FEX_VECTORTSOENABLED = 0",
                          "env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye",
                          "env.MADEIRA_DOCK_GAME_SCM = 1", "env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5_Enhanced.exe",
                          "env.MADEIRA_EXECREQ_LEAVE = 1", "env.MADEIRA_KMT_ADAPTER = 1", "env.MADEIRA_LOCK_ORPHAN = stamped", "env.MADEIRA_PIN_GRAPHICS_DLLS = 1",
                          "env.MADEIRA_POOL_HEAD_RESERVE_MB = 128", "env.MADEIRA_POOL_LOW_IMAGES = 1", "env.MADEIRA_POOL_RECYCLE_IMAGES = 1",
                          "env.MADEIRA_SC_PA_POOLS = 2",
                          "env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist",
                          "env.MADEIRA_TOUCH_MOUSE = 1", "env.MADEIRA_WOW_MIN_FREE_GB = 2",
                          "env.MADEIRA_X64_GRAPHICS_ENTRY = 1", "env.MADEIRA_X64_IMAGE_NOCOPY = 1", "env.WINEDLLOVERRIDES = video64=",
                          "env.MADEIRA_FREE_DELAY_MS = 2000", "env.MADEIRA_CTX_CPU_AREA = 2", "env.MADEIRA_WAIT_CHILDREN = 1", "env.MADEIRA_JIT_DUMP = 0",
                          "d3d12-caps-log = 2", "d3d12-core-dll = 1", "d3d12-msaa8 = 1", "d3d12-tile-based = 0", "d3d12-tiled-resources = 1", "d3d12-typed-uav-load = 1",
                          "pso-warm = 2", "pso-async = 1", "pso-archive = 1", "ring-share = 1",
                          "env.MADEIRA_WOW_ARENA_HOLD_GB = 0", "env.MADEIRA_SMALL_STACK_EXES = GTA5_Enhanced.exe",
                          "env.MADEIRA_GUEST_LOG = all", "env.MADEIRA_GUEST_LOG_LIMIT = 4000"],
            keepExeWindow: true,
            // 2026-11-08 (two runs, same route, 1.3.94): wide left 15 of 60 samples at or below 12 FPS and read more than 5 MB from the swap file in 31 % of the samples; broad had none at or below 12 FPS, 19 %, and a median 54 FPS, but ended at 6.0 GB with 11 MB free (the memory warning came up once). Texture Quality Normal gives it room.
            swapCoverage: "broad"),
        Fix(steamAppID: 271590, title: "Grand Theft Auto V Legacy",
            hide: [],
            why: "Starts through Rockstar's launcher like Red Dead Redemption 2, whose pages are shown by SocialClubHelper.exe (Chromium): on 2026-11-08 every helper stopped at start in chrome_elf.dll (exit 0x80000003) and the launcher gave \"Timed out waiting for browser window\" (SC_INIT_ERR_WEBSITE_FAILED_LOAD). Madeira's tested list for this game (gta5l-steam v1: it played Story Mode at 38-60 FPS on community build 547) has the same Social Club memory layout as Red Dead Redemption 2's (MADEIRA_SC_PA_POOLS = 2), the executable window kept and the pool switches built around it. Without any of it the game got only the defaults.",
            scPaPools: 2, configLines: [
                          "pool-low = 1", "pool-page-fit = 1", "pool-split = 1",
                          "env.FEX_VECTORTSOENABLED = 0",
                          "env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye",
                          "env.MADEIRA_DOCK_GAME_SCM = 1", "env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5.exe",
                          "env.MADEIRA_EXECREQ_LEAVE = 1", "env.MADEIRA_KMT_ADAPTER = 1", "env.MADEIRA_LOCK_ORPHAN = stamped",
                          "env.MADEIRA_POOL_HEAD_RESERVE_MB = 128", "env.MADEIRA_POOL_LOW_IMAGES = 1", "env.MADEIRA_POOL_RECYCLE_IMAGES = 1",
                          "env.MADEIRA_SC_PA_POOLS = 2",
                          "env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist",
                          "env.MADEIRA_TOUCH_MOUSE = 1", "env.MADEIRA_WOW_MIN_FREE_GB = 2",
                          "env.MADEIRA_X64_GRAPHICS_ENTRY = 1", "env.MADEIRA_X64_IMAGE_NOCOPY = 1", "env.MADEIRA_EC_HOOK_TRACE = 0",
                          "env.DXMT_WSI_MONITOR_IDENTITY = 1", "env.DXMT_WSI_MODE_TABLE = 1", "env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe",
                          "env.WINEDLLOVERRIDES = video64=",
                          "env.MADEIRA_FREE_DELAY_MS = 2000", "env.MADEIRA_CTX_CPU_AREA = 2", "env.MADEIRA_WAIT_CHILDREN = 1", "env.MADEIRA_JIT_DUMP = 0",
                          // Ours (2026-11-08, 1.3.86 log): every Wine process shares one emulator arena (9 GB usable, 3 GB of its 12 held back for a 32-bit program). Steam's client (91 threads),
                          // Rockstar's launcher (79) and the game (131) took about 340 threads' worth (~26 MB each: 8 MB call-return stack, 8 MB lookup cache, code buffers) and then
                          // `[callret] RESERVE FAILED ... thread cannot start`: eight game threads ended with STATUS_NO_MEMORY, the main thread waited for them (Sleep(0) at 12-50k/s) and the loading
                          // screen stayed on "Initializing" (the audio engine's threads failing is the likely cause of the earlier "Failed to initialize audio"). The 3 GB hold is given back (no
                          // 32-bit program is needed: the launcher's 32-bit dllhost cannot boot anyway), and the thread-stack switches Red Dead Redemption 2's list uses are set for GTA5.exe.
                          "env.MADEIRA_WOW_ARENA_HOLD_GB = 0", "env.MADEIRA_THREAD_STACK_SPILL = 1", "env.MADEIRA_SMALL_STACK_EXES = GTA5.exe",
                          // 2026-11-08 (1.3.87 log: threads start now, no RESERVE FAILED, but the loading screen still sits on "Initializing" with one game thread polling timeGetTime + Sleep(0) at 50k/s):
                          // the one switch of Madeira's tested list for this game (gta5l-steam: fastSync + semaphoreFastPath) that was not set here.
                          "env.MADEIRA_FASTSYNC_SEM = 1",
                          // Ours: the launcher's, Social Club's and the helper's logs are mirrored into the session log (up to 4000 lines).
                          "env.MADEIRA_GUEST_LOG = all", "env.MADEIRA_GUEST_LOG_LIMIT = 4000"], keepExeWindow: true,
            // 1.3.89 put -scOfflineOnly into commandline.txt to test whether the wait was the online part: it was not (two logs, Social Club "Offline: offline", same hang), so it is taken out again.
            textLinesRemoved: ["commandline.txt": ["-scOfflineOnly"]]),
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
        Fix(steamAppID: 292030, title: "The Witcher 3: Wild Hunt",
            hide: [],
            why: "The current (next-generation) version runs AVX instructions in witcher3.exe without asking whether the CPU has them. With AVX off (Porthole's default, FEX reports no AVX) it ended on the first one, c000001d, three seconds after the window opened (compatibility report #139, an iPhone 17 Pro, 2026-11-07). AVX is switched on for this game.",
            configLines: ["env.MADEIRA_FEX_AVX = 1"]),
        Fix(steamAppID: 534380, title: "Dying Light 2 Stay Human",
            hide: [],
            why: "DyingLightGame_x64_rwdi.exe runs AVX instructions (a `c5 fc 10 ..` vmovups) without asking whether the CPU has them. With AVX off it ended on the first one, c000001d (compatibility report #146, an iPhone 17 Pro, 2026-11-07). AVX is switched on for this game.",
            configLines: ["env.MADEIRA_FEX_AVX = 1"]),
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
        Fix(steamAppID: 2670630, title: "Supermarket Simulator",
            hide: [],
            why: "A Unity game with hundreds of block-compressed (BC) textures. An iPad with an A15 or A16 chip cannot sample those, so the engine decodes every one to uncompressed RGBA, four to eight times its size. On a 6 GB iPad (the app may use about 4 GB) pressing Continue grew the footprint from 1.5 GB to 4.1 GB in 21 seconds and iOS closed the app (compatibility report 109, 2026-11-05, 1.2.1). The engine's automatic texture saver drops the top detail level of large textures once the app is within 1.5 GB of its limit, but it is only on by default in the 32-bit build; this switches it on for this game.",
            configLines: ["env.MADEIRA_MIP_CLAMP_AUTO = 1"]),
        Fix(steamAppID: 2300840, title: "Subliminal",
            hide: [],
            why: "An Unreal Engine game whose start-up checks that Microsoft's Visual C++ 2015-2022 Redistributable (arm64) is installed. Porthole has no installer for it and needs none: the check only reads a registry marker, and without it the game shows \"The following component(s) are required to run this program: Microsoft Visual C++ 2015-2022 Redistributable (arm64)\" and stops (problem report 31, 2026-11-04, 1.2.0). The engine's own switch writes that marker for this game, the same one FINAL FANTASY RESONANCE needs.",
            configLines: ["env.MADEIRA_VCRT_ARM64_KEY = 1"]),
        // 2026-11-08 (log BlackOpsColdWar.exe, 1.3.99): the game's copy protection unmaps its own 533 MB executable and builds it again at the same base; Steam's service took pages of the
        // freed range in between, the game's reserve there failed (c0000018) and the protection ended the process with a stack overflow (0xC00000FD). The image hold (patch 0193) keeps
        // the range for the game while it does that. Whether anything else stands in the way is not known yet: read the [image-hold] lines.
        Fix(steamAppID: 1985810, title: "Call of Duty: Black Ops Cold War",
            hide: [],
            why: "Its copy protection unmaps the game's own executable and builds it again at the same address. All programs of a session share one address space here, so another program's allocation could land in the gap and the protection's reserve at its old address failed (c0000018), which ended the game with a stack overflow after about a minute. env.MADEIRA_IMAGE_HOLD = 1 (patch 0193) keeps the freed range for the game while it rebuilds. Experimental: the next stop is not known yet.",
            configLines: ["env.MADEIRA_IMAGE_HOLD = 1"]),
        // 2026-11-08 (logs BeamNG.drive.arm64.exe and BeamNG.drive.exe, 1.3.97 and 1.3.98): a newer BeamNG (0.40.5) ships a native ARM64 build (BinArm64/BeamNG.drive.arm64.exe) and its
        // launcher (BeamNG.drive.exe) starts that one, with `-gfx d3d12 -gfxfallback`, because the machine reports ARM64. It is a plain ARM64 process, which the engine's ARM64 farm
        // (136 DLLs) cannot serve: D3DCOMPILER_47.dll is not in it (error c000007b, then c0000135), the game ended in under a second with a blank window. Setting BinArm64 aside (1.3.98)
        // did not help: the launcher does not fall back, it stops with "Application executable not found". So the launcher is left out: the x64 build in Bin64 is started next to Valve's
        // signed-in client (steamProgram), the way Rust's own program is, with the options the launcher would have given it and the ones this fix's other lines are written for
        // (glued Chromium pools, Ultralight, the game's own D3DCOMPILER).
        Fix(steamAppID: 284160, title: "BeamNG.drive",
            hide: [], formerlyHidden: ["Bin64/D3DCOMPILER_47.dll", "BinArm64"],
            why: "BeamNG.drive has Chromium's allocator inside the game (its user interface). That allocator asks for a 32 GB pool aligned to 32 GB, frees the three answers it cannot use because they are only 16 GB aligned, asks for 64 GB less 64 KB to align it itself, and the game stops with 0x80000003 (STATUS_BREAKPOINT) when that is refused. The game program has its own switch for this (read from its 0.39.4 program, 2026-10-16: -forceUltralight makes it build its menus on Ultralight, a one-process renderer, and never start Chromium), so Madeira appends it to the game's command line (MADEIRA_CHILD_ARGS). Before that: with --single-process the game's Chromium still started a GPU process, which is refused (one Chromium process is all the address space holds), and Chromium then ended with \"GPU process isn't usable\" (2026-10-16 02:31): the same switches Madeira gives Rockstar's and Ubisoft's launchers (--disable-gpu, --disable-gpu-compositing) did not stop it (2026-10-16 02:37: the GPU process and the network and storage services were still started as children, and refused), so the GPU runs in the process (--in-process-gpu) and the network and storage services are asked to as well. Its helper processes (the interface runs in several, each a full copy of the 47 MB game program) filled the emulator's code pool at the fifth one (EXHAUSTED, 0xc0000017, 2026-10-16 02:19), so plain 64-bit programs now run from their loaded image without a pool copy (MADEIRA_X64_IMAGE_NOCOPY, part of Madeira's Red Dead Redemption 2 recipe). The game now gets the layout Madeira built for Rockstar's Social Club (also Chromium with several allocators in one process): a real slot for each 32 GB block, the emulator's arena moved 4 GB up and the JIT pool's alias moved, all at start. (The other layout, pa-pool32-soft, was tried on a device on 2026-10-16 and refuses the ask sooner.) (Wine's own shader compiler cannot read the game's material shaders, so the game keeps its own.)",
            steamProgram: "Bin64/BeamNG.drive.x64.exe", steamProgramArgs: "-forceUltralight -flushLogErrors -logeverything",
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

    /// Puts the fix's lines into its text files inside `folder`. One log line per file changed. Paths that would leave `folder` are refused.
    @discardableResult
    static func writeTextFiles(_ fix: Fix, in folder: URL, fileManager fm: FileManager = .default) -> [String] {
        var done: [String] = []
        let root = folder.standardizedFileURL.path
        for (relative, lines) in fix.textFiles.sorted(by: { $0.key < $1.key }) {
            let url = resolvedIgnoringCase(relative, in: folder, fileManager: fm).standardizedFileURL
            guard url.path.hasPrefix(root + "/") else { done.append("refused \(relative): outside the game folder"); continue }
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let have = Set(existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let missing = lines.filter { !have.contains($0.lowercased()) }
            guard !missing.isEmpty else { continue }
            let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + missing.joined(separator: "\n") + "\n"
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                done.append("\(existing.isEmpty ? "wrote" : "added to") \(relative): \(missing.joined(separator: ", "))")
            } catch {
                done.append("couldn't write \(relative): \(error.localizedDescription)")
            }
        }
        for (relative, lines) in fix.textLinesRemoved.sorted(by: { $0.key < $1.key }) {
            let url = resolvedIgnoringCase(relative, in: folder, fileManager: fm).standardizedFileURL
            guard url.path.hasPrefix(root + "/"), let existing = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let drop = Set(lines.map { $0.lowercased() })
            let all = existing.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let kept = all.filter { !drop.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            guard kept.count != all.count else { continue }
            let body = kept.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            do {
                if body.isEmpty { try fm.removeItem(at: url) } else { try (kept.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8) }
                done.append("took \(lines.joined(separator: ", ")) out of \(relative)")
            } catch {
                done.append("couldn't change \(relative): \(error.localizedDescription)")
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
        // A name with slashes ("Bin64/Game.x64.exe") is a program below the game's folder; it must stay inside it.
        if name.contains("/") {
            guard !name.split(separator: "/").contains("..") else { return nil }
            let url = resolvedIgnoringCase(name, in: folder, fileManager: fm)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
              let hit = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return folder.appendingPathComponent(hit)
    }

    /// `own`'s path below `program`'s folder, in Windows form ("Bin64\\Game.x64.exe"); just the file name when it is beside the program.
    static func windowsRelative(_ own: URL, to program: URL) -> String {
        let base = program.deletingLastPathComponent().standardizedFileURL.path + "/"
        let path = own.standardizedFileURL.path
        guard path.hasPrefix(base) else { return own.lastPathComponent }
        return String(path.dropFirst(base.count)).replacingOccurrences(of: "/", with: "\\")
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
