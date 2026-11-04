# What the 2026-11-03 Madeira merge brought that Porthole does not use yet

Written 2026-11-04 from a static comparison of Madeira c2c1b03..1608a25 (192 commits, `vendor-engine`) with this app: the 109 changed or new files under `app/`, and the 176 new options in
`ConfigCatalog.generated.swift` matched by name against `app/Sources` and `app/Runtime`. Nothing here was run on a device. "Not referenced" means the option's key or its
`MADEIRA_*` name does not appear in Porthole's sources; the engine still reads it from a game's engine lines, so it is reachable by hand, just not from a setting.

## Update 2026-11-04: four of these are now in (private builds 1.2.110 to 1.2.113, none run on a device)

* **Wine Gecko** (1.2.110): vendored `WineGecko.swift`; offered in the setup guide and Settings > Advanced > Windows components. Porthole asks first; Madeira downloads it by itself on Wi-Fi.
* **32-bit Visual C++ runtime** (1.2.111): vendored `VCRedist.swift` + `CabinetReader.c/h`, cut to the x86 package only (the 64-bit runtime stays Porthole's own installer).
* **Steam Big Picture** (1.2.112): experimental, `Core/SteamBigPicture.swift`, Settings > Stores > Steam. Madeira ships it compiled out as unfinished. Not ported: listing Madeira's Steam libraries in the client.
* **GOG Galaxy services** (1.2.113): `Gog/Galaxy/*` and `Gog/GogGalaxy.swift`, a toggle in Settings > Stores > GOG. Correction to item 4 below: `madeira-galaxy-service.exe` IS in the stage
  (`aarch64-windows` is symlinked from the vendor tree), so nothing had to be added there.

## A. Features that are not in the app at all (as of the first audit)

1. **Background running** (upstream `BackgroundRun.swift`, `Winios/BackgroundCPUCap.c`, `Winios/MetalBackgroundGate.m`; options `background-run`, `background-download`, `background-cpu`,
   `background-gpu-gate`, `background-sound`). A game keeps loading for N minutes after you switch apps or lock the screen, with its sound muted, its CPU held under 50% of a core
   (iOS ends an app that averages more) and GPU work held until you are back (iOS refuses it in the background). Porthole has none of this for games. It only keeps *downloads*
   alive (`SteamBackground`, `EpicBackground`). Risk to check on a device: Porthole declares the `audio` background mode, so a game that is playing audio when you leave
   may keep its threads running with no GPU gate; whether iOS then ends the app is untested.
2. **Wine Gecko** (`WineGecko.swift`). The engine bridge already links Gecko's MSIs into a prefix if the app downloaded them (`madeira_link_wine_gecko`), but Porthole has no downloader
   (the way it has for Wine Mono), so a program that needs Wine's HTML engine (many launchers and installers) gets Wine's own download window or fails.
3. **Microsoft x86 Visual C++ runtime** (`VCRedist.swift`, option `MADEIRA_VCREDIST_X86`). The engine overlays it onto 32-bit programs from `Documents/vcruntime32`. Porthole's
   `VCRuntimeInstaller` only downloads the x64 runtime, so 32-bit programs keep Wine's own C++ runtime.
4. **GOG Galaxy services** (`SwiftGOG/Galaxy/*`, `madeira-galaxy-service.exe`, `MADEIRA_GOG_GALAXY`): sign-in, achievements, stats and leaderboards for GOG games, answered on 127.0.0.1:9977.
   Porthole's GOG store says Galaxy features are unsupported, and `madeira-galaxy-service.exe` is not in the r28 stage.
5. **Steam LAN peer downloads** (`SteamLANPeer.swift`). Not ported; Porthole has its own Steam downloader.
6. **Localization** (`Localizable.xcstrings`). Porthole's interface is English only.
7. Not applicable to Porthole's design: upstream's library grid and its settings pages (`Library*`, `SettingsPages.swift`), the Big Picture options (`MADEIRA_BIG_PICTURE_*`), `ClaudeHelp.swift`,
   `SigningRefresh.swift`.

## B. Options with no setting (the engine honours them; only a hand-typed engine line sets them)

Of the 176 new options, 7 are referenced in Porthole. The ones a player would notice, in the order I would add them:

* **Audio**: game volume at the output, 10-200% (`MADEIRA_AUDIO_GAIN`); bring game audio back after a call, Siri or an alarm (`MADEIRA_AUDIO_RESUME`, off by default, so today the sound stays off until the game restarts).
* **Pipeline archive** (`pso-archive`, `MADEIRA_PSO_ARCHIVE_INLINE`, `_MB`, `_PER_BUILD`, `pso-async`): compiled graphics pipelines kept between runs, which cuts first-run stutter. Only Madeira's
  "tested setups" switch it on today.
* **Display**: size a tiny game window to the screen (`MADEIRA_TINY_WINDOW_FIX`), keep display sync (`MADEIRA_DISPLAY_SYNC`), the address space a game is told it has (`MADEIRA_USER_VA_GB`).
* **Controllers**: other pads as a generic HID gamepad (`MADEIRA_HIDPAD_AUTO_GENERIC`), re-read a controller's profile (`MADEIRA_XINPUT_PROFILE_CHECK`).
* **Direct3D 12 compatibility**: claim feature level 12_1, report shader model 6.7, a ray-tracing tier (experiment), 64-bit atomics by GPU, timestamp queries, and about twenty more switches.
* **Memory**: the donor pool's kind, guard and margin (`donor-pool-kind`, `donor-pool-guard`, `donor-only`, `MADEIRA_DONOR_*`), the swap tier for 32-bit programs (`swap-wow64`).
* **Epic**: start Epic games under the Epic client's name (`MADEIRA_EPIC_LAUNCHER_PARENT`, on by default; `EpicGamesLauncher.exe` is in the stage) and the fixed Steam identity for games from other stores.
* **Vulkan routes**: DXVK and vkd3d-proton options passed through as environment variables.

## C. In the app, but never run on a device

The EA app store, Donor memory and its extension, gyro aim and turbo, Madeira's tested setups, share a game's setup, .7z installs for itch.io, and the Dock game session (service manager,
guest-window hold). See CHANGELOG-1.2.0.txt, KNOWN LIMITS.
