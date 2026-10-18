# Porthole

Porthole runs Windows PC games on iPhone and iPad. It is the app around the [Madeira](https://github.com/willfaust/Madeira) runtime (Wine, FEX
and DXMT), with a game library, sign-in and downloads for Steam, Epic Games, GOG and itch.io, JIT set-up, on-device updating, and an optional community compatibility list
([portholehq.site](https://portholehq.site)).

**Status: early.** It is made and tested by one person on a few devices. Plenty of games do not run, and some that do run need tweaking.
Read [what to expect](#what-to-expect) before you spend an evening on it.

> **Unofficial.** Porthole is not affiliated with or endorsed by Valve, Steam, Microsoft, Apple, Epic, GOG or any game publisher. It does not
> bypass any licence check or copy protection: Steam games are started through Valve's own Steam client files, which check your licence
> exactly as they do on a PC, and Porthole contains no games. Game, store and company names belong to their owners.

## What you need

- An iPhone or iPad with **iOS 18 or later** (arm64). It is developed and tested on iOS 26 and 27; iOS 18 to 25 should work but have not been tested. More memory is better: games that need more than the device has cannot run.
- A way to **sign and install an app yourself**. Porthole is not on the App Store and cannot be, because it uses private iOS interfaces to
  start its helper. The routes, best first:
  - **A paid Apple Developer account**, or **a third-party certificate service**: both can provide every capability Porthole asks for (*Network Extension
    (packet tunnel)*, *Personal VPN*, *Increased Memory Limit*, *Extended Virtual Addressing* and *get-task-allow*). Recommended.
  - **A free Apple ID** works too, for the core of the app (library, stores, downloads, games), but it cannot carry some of those capabilities: no
    Network Extension (use LocalDevVPN for the private link) and no Increased Memory Limit (memory-hungry games are more likely to run out), and its signing
    expires after about a week. See [Install](docs/INSTALL.md#fewer-app-ids-optional) for the lighter install.
- A way to switch on **JIT** for the app (see [Install](docs/INSTALL.md)). Porthole can do it by itself after a one-time "pairing file";
  on iOS 27 or later the device can make that file on its own, on earlier versions it is made once on a computer.
- Games you own: from Steam, Epic Games, GOG or itch.io (sign in inside the app), or game folders and installers you copy in from the Files app.

Step by step: **[docs/INSTALL.md](docs/INSTALL.md)**.

## What Porthole does

- **Library:** your games with art, play time, per-game settings and an optional on-screen controller layout.
- **Stores:** sign in to Steam (password with Steam Guard, or a QR code), Epic Games or GOG (on the store's own page, so Porthole never sees your
  password) or itch.io (with a personal API key you make there), see the games you own, and download them straight to the device. Downloads adapt
  to your connection and resume after interruptions. One **Downloads** page shows what every store is downloading, with pause, resume and
  "download now"; its round button stays at the bottom right of the Stores tab.
- **Controllers:** PlayStation, Xbox and other controllers iOS supports work without setup. The on-screen controls hide while one is in use, a
  controller can act as keyboard and mouse, and each game's controller buttons can be remapped.
- **Windows components:** many games need Microsoft's Visual C++ runtime. Porthole downloads Microsoft's own installer from Microsoft,
  checks it against a fixed fingerprint and unpacks the files itself. Nothing of Microsoft's is included in the app.
- **JIT:** the iOS feature the speed of everything depends on. Built-in method, StikDebug, or another tool: your choice in the setup guide.
- **Updating:** Porthole can update itself on the device (download, sign with your own certificate, install) from an update server whose address
  is set when the app is built, or you install new IPAs by hand. A build that carries the maintainer's release key installs only updates signed with
  the matching private key. This source has no server address; a build with one is described under Privacy.
- **Compatibility reports and shared key binds (optional):** after playing you can report how a game ran, see how it ran for others on your
  model, and share or download key-bind sets for a game. These need the same build-time server address.

## What to expect

- Works well for some games: for example Factorio ran at around 57 fps on an iPad Pro (M4).
- Out of reach for others: games larger than the device's memory, games with kernel-level anti-cheat, very large executables (the runtime
  copies the program into a fixed memory area, so programs of roughly 450 MB and up cannot load), and some that need Windows features not
  implemented yet. Some Unity games only work when started through Steam.
- The first run takes several minutes of setup; the game library and settings are yours and stay on the device.
- The community list at [portholehq.site/compat.html](https://portholehq.site/compat.html) shows what others have reported.

## Privacy

Everything you set up stays on the device. Store sign-ins (tokens, never passwords) are kept in the iOS Keychain, for this device only, and are sent
only to the store itself. Porthole goes online to download what you ask for (Microsoft's components, Valve's client files, your games from the
four stores, updates). A build made with a community server address (a build setting; none is in this source) also asks that server which
update is newest, which compatibility badges apply to your games and which shared key binds exist, and sends something only when you choose to:
a compatibility report (a random per-install key, the game, your device model and your answers) or a key-bind set you share (the same random key,
the game and the set itself). Never your name, account or any device identifier. Details: [portholehq.site/privacy.html](https://portholehq.site/privacy.html).
A problem report you choose to send includes the app's log, cleaned of account names, e-mail addresses and public IP addresses first; you can read
it before it goes. There is no analytics and no account with Porthole.

## Building from source

The app builds with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) on a Mac. The Madeira runtime is a git submodule
(`vendor/Madeira`, pinned to the commit it was built from) and its native libraries are built with the scripts in `tools/` and Madeira's
`build/` folders. The exact versions, the patches applied, the order of the build and the steps for replacing a statically linked library
are in **[docs/SOURCE.md](docs/SOURCE.md)**. That sequence has not yet been repeated on a clean machine from scratch; if a step is wrong,
that is a bug in the document.

```bash
cd Packages/LauncherCore && swift test        # signer, update catalog, vault, transport (no device needed)
app/Tests/Steam/run.sh                        # the Steam client against a stand-in for Steam's servers (STEAM_LIVE=1 also uses the real ones)
cp app/Config/Local.xcconfig.example app/Config/Local.xcconfig     # your bundle id, and optionally your own server
```

`app/Config/Local.xcconfig` and `tools/local.env` hold your own identity and machine paths and are never committed.

## Built with AI
Porthole was built with the help of AI. A large part of the code, the documentation, the website and the artwork was written by an AI coding
assistant (Claude, from Anthropic) working with the maintainer, who directs the project, reviews the changes and tests them on real devices.
The code therefore contains AI-written code, and, like any software, it may contain mistakes.

## Licence and credits

Porthole's own code is free software under the **GNU General Public License, version 3 or (at your option) any later version**
([LICENSE](LICENSE)), with an additional permission for the Apple Metal Shader Converter ([LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md)).
Parts taken from other projects keep their own licences; [CREDITS.md](CREDITS.md) says who made what, [docs/COMPLIANCE.md](docs/COMPLIANCE.md)
lists what each part requires, and the app shows the licences under Settings ▸ About and credits ▸ Licences. There is no warranty.

Porthole stands on the work of the projects it is built on: Madeira (Wine, FEX-Emu, DXMT and Madeira Dock), StikDebug and idevice,
and others listed in the credits.
