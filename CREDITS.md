# Credits

Porthole stands on other people's work. This list is kept up to date as things are added; if you used an idea or code from a project and it is
missing here, add it.

## The runtime (Madeira)
The Windows-on-iPhone backend is **[Madeira](https://github.com/willfaust/Madeira)**, pinned as the submodule `vendor/Madeira` (see `docs/SOURCE.md`).
- Its forks of [Wine](https://github.com/willfaust/wine) (ARM64EC, the LGPL branch), [FEX-Emu](https://github.com/willfaust/FEX) and [DXMT](https://github.com/willfaust/dxmt) (D3D11 → Metal, with DXMT's Direct3D 9 frontend).
- **[Madeira Dock](https://github.com/willfaust/madeira-dock)** (Steam licence-checked launching).
- **Madeira's hardware keyboard and mouse layer** (`app/Madeira/HardwareInput.swift`, `docs/KEYBOARD_MOUSE.md`): `app/Sources/Core/HardwareInput.swift` is a port of it (raw key and mouse events, focus rules, the pointer lock, the drawn cursor); the pointer-capture rules in it are adapted from BCD 0.1.614 by thebcd69, as Madeira says.
- The Madeira Steam client (`SwiftSteam`) is **not** used here: Porthole's own Steam sign-in, library and downloads (`app/Sources/Steam`) were written for this project from Steam's public protocol (see `docs/STEAM_CLIENT.md`).
  (Madeira Discord, 2026-09-22).
- The JIT script `madeira-jit.js` (Madeira, GPL-3.0).
- Upstream projects Madeira is built from: [Wine](https://gitlab.winehq.org/wine/wine) (LGPL-2.1+), [FEX-Emu](https://github.com/FEX-Emu/FEX) (MIT), [DXMT](https://github.com/3Shain/DXMT) (MIT),
  [rpmalloc](https://github.com/mjansson/rpmalloc), [GnuTLS](https://github.com/gnutls/gnutls), [Nettle](https://github.com/gnutls/nettle), [GMP](https://gmplib.org),
  [FFmpeg](https://github.com/FFmpeg/FFmpeg), [{fmt}](https://github.com/fmtlib/fmt), [xxHash](https://github.com/Cyan4973/xxHash), Cephes,
  [Berkeley SoftFloat](https://github.com/ucb-bar/berkeley-softfloat-3), [Zstandard](https://github.com/facebook/zstd) (educational decoder), [LLVM](https://github.com/llvm/llvm-project).
  See `vendor/Madeira/THIRD-PARTY-NOTICES.md` and `docs/LICENSING.md`.

## JIT
- **[Iridium](https://github.com/intraducine/iridium)**: the idea and technique of enabling JIT from inside the app with a helper app extension (`F4JITHelper`, `BuiltinJIT`, `JITExtensionLauncher`).
  Studied from Iridium's source (`docs/JIT-in-app.md`); the code here is our own.
- **[StikDebug](https://github.com/StikDebug/StikDebug) / [StikJIT](https://github.com/StikDebug/StikJIT)** and **[idevice](https://github.com/jkcoxson/idevice)**: `StikJIT.xcframework` (MPL-2.0) runs the debugger; its `universal.js`/`legacy.js` come from StikDebug (AGPL-3.0). Also the JIT-enabling approach in general.

## OpenGL
- **[A Madeira fork with OpenGL support](https://github.com/c-gow/Madeira)**: the OpenGL support (a WGL driver for Wine on iOS with an OpenGL ES backend and a desktop OpenGL backend through Mesa Zink on MoltenVK, 32-bit OpenGL
  thunks, LuaJIT substitution for LOVE games). The fork's author notes it was written with AI assistance. Ported here as patches 0082 and 0083 (`docs/OPENGL.md`).
- **[Mesa](https://gitlab.freedesktop.org/mesa/mesa)** (OSMesa, Zink; MIT), **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** (Khronos; Apache-2.0) with [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross), [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) and [cereal](https://github.com/USCiLab/cereal), and **[LuaJIT](https://github.com/LuaJIT/LuaJIT)** (MIT).

## Madeira pull requests taken on 2026-10-12 (patches 0119, 0120)
Open pull requests of <https://github.com/willfaust/Madeira>, taken with their authors' names (each is GPL-3.0-or-later with Madeira's converter exception): **#235 external SSD Steam
library** (David Brookes; `docs/EXTERNAL_STORAGE.md`), **#207 Epic Games** (125hz, a port of [Legendary](https://github.com/derrod/legendary) by derrod and contributors; `docs/EPIC.md`),
**#248** (Ash Hopkins: multi-process fixes, RWX writes, log privacy), **#219** and **#229** (spitefulowl: low-RAM swap tier, Final Fantasy Tactics), **#222** (TheHadesc: mouse-look and pointer
lock), **#214/#215** (Kesavamoorthig06: tar extraction hardening), **#210** (MiraiSubject: the x87 toggle), **#240**, **#241**, **#242-#244**, **#237**, **#246** (125hz) and **#227/#228**
(c-gow). The list of what each one changed is in `patches/0119-*.md`.

## On-device pairing file (iOS 27)
- **[idevice](https://github.com/jkcoxson/idevice)** documented the remote-pairing "pairable host" conversation; **[StikPair](https://github.com/StikDebug/StikPair)** (MIT non-commercial) showed it working on iPhones.
  Our implementation (`app/Sources/Pairing`) is a separate Swift rewrite and uses none of their code.

## Our own
- App, Library, setup guide, installers, game importer, Steam store/downloads UI, tunnel, updater: this project. The on-device signer and update pipeline (`Packages/LauncherCore`) were written for this author's companion signing app and are included here.

## Store logos
The Steam and Epic Games marks on game cards (`app/Assets.xcassets/StoreSteam.imageset`, `StoreEpic.imageset`) are the logos of **Valve Corporation** and **Epic Games, Inc.**, shown only to say which store a game was
downloaded from. They are trademarks of their owners and are not covered by this project's licence.

## Not affiliated
Steam and the Steam artwork belong to Valve; Epic Games, GOG, Factorio (Wube Software) and every game or launcher you run belong to their owners.
This project is not affiliated with or endorsed by any of them. Games and launchers are never bundled.
