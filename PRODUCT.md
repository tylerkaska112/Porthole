# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Today: enthusiasts who can already sideload an app, switch on JIT and tweak settings per game, using an iPhone or iPad (iOS 18 or later) to play Windows PC games they already own. They open Porthole to pick a game, start it, and, when it misbehaves, to adjust it or find out what worked for other people on the same device model.

Next: broader gamers who just want their PC library on an iPhone or iPad and have no wish to learn the technical parts. The product is expected to grow toward this person; early work still assumes the first group. (Stated by the maintainer, not yet evidenced by user research.)

## Product Purpose

Porthole runs Windows PC games on iPhone and iPad. It is the app around the Madeira runtime (Wine, FEX and DXMT): a game library with art, play time and per-game settings; sign-in and downloads for Steam, Epic Games, GOG, itch.io, Amazon Games and the EA app; game folders and installers copied in from Files; JIT set-up; on-device updating; controls (touch layouts, controllers, keyboard and mouse); and an optional community layer (compatibility reports, shared key binds and touch layouts, Discord).

Success is a person going from "I own this game on a PC store" to "it runs and feels right on my device" with as little effort and as few surprises as the hardware allows, and being told plainly when it will not.

## Positioning

Two things set it apart, as confirmed by the maintainer:
- Everything in one app: several stores' libraries, downloads, controls, Discord, compatibility reports and shared on-screen controls together, instead of a separate tool for each step.
- Community knowledge per game: compatibility reports from other players on the same device model, and key binds or touch layouts that others made and shared for that specific game.

## Operating Context

- Used on a phone (held upright or sideways) and on an iPad, with touch, a game controller, or a Bluetooth keyboard and mouse. Navigation works by touch and by controller (D-pad, shoulder buttons to switch sections).
- Not distributed through the App Store; it needs a way to sign and install an app yourself, and JIT switched on for the app. First-run setup takes several minutes.
- Games are the person's own, from the stores above or copied in as folders and installers; Porthole contains no games.
- A game runs full screen with Porthole's own menu, on-screen controls and overlays above it.
- An optional update server and community server are set at build time; the source build has no server address.
- Releases are numbered and named (a nautical phrase per release) and ship through a private updates channel; public releases are a separate, deliberate step.

## Capabilities and Constraints

- Requires iOS 18 or later (arm64); tested on iOS 26 and 27. More device memory means more games run.
- Some games cannot run: larger than the device's memory, kernel-level anti-cheat, very large executables (roughly 450 MB and up), and some needing unimplemented Windows features. Some Unity games only work when started through Steam.
- Steam games are started through Valve's own client files, which check the licence; nothing bypasses licence checks or copy protection. Porthole is unofficial and not affiliated with the stores or publishers.
- Store sign-ins are tokens kept in the iOS Keychain; passwords are not stored. No analytics and no Porthole account.
- Controls: built-in layouts (mouse and keys, first person, gamepad), a per-game editor, shared bind sets, real controllers, and (since 1.4.51) a default controls choice for every game.
- The app is currently dark only, and that is not a requirement: the maintainer is open to a light appearance. The accent colour is the person's choice among presets or a custom colour.
- No visual direction is set. The maintainer's only stated wish is something pleasing and modern; no references, palette, typeface or style are binding.
- Status stated in the README: early, made and tested by one person on a few devices.
- Terminology: "bind set" (controller binds and/or a touch layout for a game), "on-screen controls", "default controls", "JIT", "pairing file", "compatibility report".

## Brand Commitments

- The name Porthole and its nautical theme: a porthole window as the logo mark and nautical release names (for example "Full Steam Ahead", "Autumn Tide").
- A plain, honest voice: it says what works and what does not (for example "Not yet tested", "Runs rough"), and is direct about limits instead of hyping.

## Evidence on Hand

- README.md (what it does, what to expect, privacy), docs/INSTALL.md and the other files under docs/, CREDITS.md, CHANGELOG.json and the per-release changelog files.
- The community compatibility list and site at portholehq.site.
- Real screenshots of the app taken on the maintainer's iPhone and iPad during development (in the working conversation, not committed here).
- Absences future work must not fabricate: no App Store listing or ratings, no user counts, no published testimonials, no benchmarks beyond those in the README (for example Factorio at around 57 fps on an iPad Pro M4).

## Product Principles

1. Be honest about what runs: show real status and limits, never promise a game will work.
2. Put the effort where the person is: setup, controls and per-game fixes should be reachable in one app, with the community's knowledge for that game close at hand.
3. Lower the cost of the first success: enthusiasts first, but each step (install, JIT, sign in, controls, first game) should get easier for someone with no technical background.
4. The person's choices stick: a default made once applies everywhere, and each game can still have its own.
5. Everything stays on the device unless the person chooses to share it.
