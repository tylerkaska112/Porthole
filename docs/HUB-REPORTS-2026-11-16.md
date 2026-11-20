# Hub reports, read in full (2026-11-16)

Every problem report (21) and every game report (312, 244 with a log) on the Hub, whether pending, approved or rejected, read from a copy of the databases. This is what they say, what 1.4.77 fixes, and what is left.

**Where the reports come from.** Almost all are from the public builds: 1.2.1 (159), 1.3.0 (57), 1.3.1 (19), 1.2.0 (13). About 170 private builds have shipped since 1.3.1, and many of the problems below were already fixed in them. The next public release carries those fixes.

## What the game reports show

| | great | broken | note |
|---|---|---|---|
| Steam games | 79 of 261 | 140 | the bulk of the data |
| **Epic games** | **0 of 24** | **22** | 17 never start. Needs its own look. |
| GOG / itch / other | few | | too few to say |
| Install can use the large address space | 47% great, 35% broken (40 reports) | | |
| Install cannot ("Large address space is not allowed") | 21% great, 63% broken (204 reports) | | 84% of reports come from such installs |
| Extra memory not allowed | 10% great, 86% broken (37) | | |
| 4 GB and 6 GB devices | 0% / 9% great | 87% / 81% broken | memory kills |

The install a person signs decides more than any game setting. Porthole already warns about it (Home note, install check, the `address-space-entitlement` rule); it cannot fix it.

## Failure families, by number of reports

| Family | Reports | Status |
|---|---|---|
| JIT helper "has no signature" (install check) | 48 | the person's install: reinstall so the helper is signed |
| Private link "profile has no VPN permission" | 31 | **1.4.77**: JIT now says what to do |
| Steam: "has not signed in after 40 s" | 21 | network or Steam client; not changed |
| "Porthole has to close and open again before the next game" | 19 | by design (one game per app launch); not changed |
| Game ended with no marker, memory red zone | 22 (+44 with critical warnings) | hardware limit on 4 to 6 GB; auto-fix suggests swap |
| JIT "device is not ready for debugging" | 12 | **1.4.77** |
| JIT pool too small at start | 11 | message already says to close and reopen |
| "Relaunch before another JIT attempt" | 11 | reworded 2026-11-14 (in 1.4.x) |
| Dock could not complete the Steam launch | 9 | engine/Steam client; not changed |
| Steam client files not installed | 7 | message exists; fixed by downloading the client |
| Cannot debug (no get-task-allow) | 4 | the person's install |
| Epic games that never start | 17 | open (see below) |

## Exit codes of the runs that ended on their own

0xC0000005 access violation (5), 0xC0000135 DLL not found (2: Jurassic World Evolution could not map its program, an address-space limit on a Lightest install), 0xC00000FD stack overflow (2: Cat Quest II, Phasmophobia), 0xC0000094 divide by zero (1), 0x80000003 breakpoint (1: Age of Wonders 4), 0xDEADC0DE (1: PUBG's anti-cheat), **53 (3)**, 0 shortly after start (14: games that quit themselves, many from a store launcher).

Exit 53 is two games set to Run directly (Green Hell, Ultimate Marvel vs. Capcom 3) whose Steamworks start-up said it "did not locate a running instance of Steam". 1.4.77 adds an automatic fix for exactly that.

## Fixed in 1.4.77

1. **JIT failure causes.** The helper only says "the device is not ready for debugging", often after 6 to 106 seconds. With this install unable to start its own tunnel (31 reports) the message now names the missing VPN permission and the LocalDevVPN setting; with "Use LocalDevVPN instead" on and no VPN up (5 reports) it says to open LocalDevVPN. If there is no own tunnel and no VPN at all it fails immediately. `Sources/Core/JITFailureHint.swift`, tests in `Tests/JITHint`.
2. **Setups hid the real reason.** A GOG or itch.io setup whose JIT failed showed only "The installer did not install the game" (problem report #55, and every retry after it), because the launch screen is off for setups. The setup page now shows the reason. `SessionController.takeFailure()`.
3. **Pairing gave up at about 35 s** ("The app ran out of background time", 8 reports; #35 and #55 succeeded on the second try) although the silent sound was still keeping the app alive. It now carries on while the sound plays. Not verified on a device.
4. **New automatic fix, "It needs Steam to be running".** Offers Through Steam for a game set to Run directly. Reports #275 and #277; Crash Bandicoot (#330, started through Steam) has both log lines too, and the rule does not apply to it. `Tests/AutoFix`.

## Already fixed before this release (in 1.3.x / 1.4.x, not yet public)

Civilization VI "error 40" depot (problem #35, 1.3.45); a vague "pool request was not answered" crash (#45, now a clear failure); Steam Cloud saves not found or overwritten (#43, 1.3.2, 1.3.146); external storage (#51, 1.3.118 to 1.3.130 and 1.4.3 to 1.4.9); VC++ runtime (#31, installed automatically); Steam client missing (#36, #37, message); Subliminal VC++ marker (1.3.27); Steep (1.3.32); the .NET one-file patcher (1.3.139 to 1.3.141); GTA V Social Club (1.3.83 to 1.3.91); and many more (see CHANGELOG.json).

## Problem reports, one by one

| # | What | Disposition |
|---|---|---|
| 31 | how to install VC redist | answered and fixed (auto install) |
| 32, 49 | FINAL FANTASY RESONANCE crash | engine pool/AVRT; existing rules; open |
| 33 | Idleon crash | answered (swap); rules exist |
| 34 | Umamusume exits in a second | engine; the maintainer is adding a trace log; waiting for a run |
| 35 | Civ VI depot key error 40 | fixed in 1.3.45 |
| 36, 37 | Poppy Playtime, Steam client missing | answered, message exists |
| 42, 50 | JIT failed with LocalDevVPN on | **1.4.77** (names the cause) |
| 43 | saves not loading | fixed in 1.3.x |
| 44, 54, 57 | crashes on a 4 GB iPhone 13 | memory limit (red zone, 13 to 75 MB free) |
| 45 | game starts without JIT | fixed after 1.2.1 |
| 47 | JIT helper has no signature (SideStore) | the install; reinstall |
| 48 | Guitar Hero World Tour crash, hot phone | thermal state "serious", no fix here |
| 51 | choose external storage | feature added |
| 53 | Rivals of Aether crash (11 GB) | engine; open |
| 55 | GOG installer stops | **1.4.77** (JIT failure was hidden) |
| 56 | iPad 7th generation | not supported (A10) |

## Epic games (1.4.78)

24 reports, 22 broken, none great. It is not one bug. Reading the 21 logs: Fall Guys (Easy Anti-Cheat, twice) and PUBG (BattlEye) cannot run; Jurassic World Evolution and Cat Quest II were on a "Lightest" install with no large address space; Fallout 1 starts a Bethesda launcher that ends by itself; Horizon Chase Turbo plays; G.I. Joe and Black Widow ran at 60 fps for thousands of frames, and G.I. Joe's own log shows Epic's servers refusing the game's login (`corrective_action_required`, 18206). 23 of the 24 were on installs without the large address space, so the install and the game cannot be told apart in this data.

What Porthole did differently from Epic's own launcher, found by reading Legendary's `get_launch_parameters`: it omitted `-epicsandboxid=<namespace>`, the ownership token (`-epicovt=<file>`, for games whose catalog entry says `OwnershipToken = true`) and the catalog's `AdditionalCommandLine`. 1.4.78 adds all three, looked up at launch (best effort, a failed lookup never stops a game). The cloud-save probe used a host that no longer exists (13 of 15 logs). Nothing in the logs proves the new arguments help: they are alignment with the reference launcher. Please read the log line `[epic] launch arguments: sandbox yes, ownership token ..., extra arguments ...` after the next Epic run.

Also new: an anti-cheat warning on the Epic game page from the manifest's file list (before the download), and an automatic-fix advice for the EOS account error.

Not done: a game whose registered program is a wrapper that ends by itself (Fallout 1's launcher); the Epic overlay; anything inside the engine.

## Still open (not for the app to fix)

- **Epic games**: see the Epic section above; the games that are not anti-cheat or install-limited still need runs with 1.4.78's log line.
- Windows stack overflow (0xC00000FD) in Phasmophobia and Cat Quest II: both on installs with neither the large address space nor extra memory.
- Age of Wonders 4 breakpoint (0x80000003).
- Steam "has not signed in after 40 s" (21).
- One game per app launch (19 reports hit the restart message).

## Notes on the data

- The compat logs hold the game's own run, so an install with no JIT helper ("Lightest install") shows the same failures as a broken game.
- "Last run ended unexpectedly" is written at the next start, so it is not a crash marker by itself.
- A search for log lines common to broken runs and rare in good ones found almost nothing (2 lines with at least 4 reports): broken games do not share one signature, so most fixes are per game or per install.
