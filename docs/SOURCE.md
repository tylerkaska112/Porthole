# Source code and how to rebuild it

Porthole is free software under the GNU General Public License, version 3 or later (`LICENSE`), with an additional permission for the
Apple Metal Shader Converter (`LICENSE-EXCEPTION.md`). You are entitled to the complete source code of the version you have, and to
rebuild and replace the parts that the licences let you replace. This file says where that source is and how it fits together.

## What is where

| Part | Where | Licence |
|---|---|---|
| Porthole (app, library, setup, installers, tunnel, updater, signer) | this repository, `app/`, `Packages/LauncherCore/`, `tools/`. Each release is the tag `v<version>`. | GPL-3.0-or-later |
| Madeira runtime glue (`app/Runtime`) | copied from Madeira (below) with our patches in `patches/` on top | GPL-3.0-or-later (Madeira) |
| Steam sign-in, library, downloads (`app/Sources/Steam`) | this repository; see `docs/STEAM_CLIENT.md` | GPL-3.0-or-later |
| Madeira (Wine, FEX, DXMT, Dock, build scripts) | the git submodule `vendor/Madeira`, pinned to the commit below | GPL-3.0-or-later with its own converter exception; each part keeps its own licence |
| StikJIT 1.5.0 (JIT) | downloaded by `tools/prepare_stikjit.py`, checked against a fixed SHA-256 | MPL-2.0 (idevice MIT, about 130 permissive Rust libraries; see `docs/notices/StikJIT.md`) |

## Pinned upstream commits

| Component | Repository | Commit |
|---|---|---|
| Madeira | https://github.com/willfaust/Madeira | `5fda6a0e9543e5de1df010aff35748ab913fd0d9` |
| Wine (LGPL branch) | https://github.com/willfaust/wine | `80c859a76e1073bd41095b1b0abc43135efdd475` |
| FEX | https://github.com/willfaust/FEX | `1dc6ed4932bd231df1c53dd7b8043ffdee0ac34a` |
| DXMT | https://github.com/willfaust/dxmt | `1f617cd5bbe7a71bc0ad9083589cb44c747cdc9b` |
| Madeira Dock | https://github.com/willfaust/madeira-dock | `67780ba92e60dbfac4fe80eaf2ce34b9ea1a1c60` |
| StikJIT release | https://github.com/StikDebug/StikJIT/releases/tag/1.5.0 | SHA-256 `444b8d439df8455c34afbb51e279fd225265279195475f9b3fdbcf3a71a27e85` |

Those are the commits Madeira records at its commit `5fda6a0` (Madeira pins the other four itself, in `vendor/Madeira/.gitmodules`; this repository's gitlink for
`vendor/Madeira` is that Madeira commit).

**The engine Porthole 1.2.0 ships (engine id `3af3467-r1`) is those five commits plus our changes**, which are these files in `patches/`:

| Patch | Applies in | What it is |
|---|---|---|
| `0172-engine-r28-madeira.patch` | the Madeira checkout (`vendor/Madeira`) | our changes to Madeira's own sources (`build/ntdll-unix`, `build/win32u-unix`, `build/wineserver`, `build/wine-pe`, `build/dock-patches`) |
| `0173-engine-r28-fex.patch` | `vendor/Madeira/FEX` | our changes to FEX |
| `0174-engine-r28-wine.patch` | `vendor/Madeira/wine` | our changes to Wine |
| `0175-engine-r28-dxmt.patch` | `vendor/Madeira/dxmt` | our changes to DXMT |
| `0176-engine-r28-madeira-dock.patch` | `vendor/Madeira/madeira-dock` | our changes to Madeira Dock |
| `0172-engine-r28-binaries.sha256` | | the SHA-256 of the 75 binary files that differ from Madeira's snapshot. They are built from the sources above (see Rebuilding and `docs/REBUILD.md`), not patched; a rebuild is normally not byte-identical. |

Each patch applied to its pinned commit gives exactly the tree the shipped engine was built from (checked file by file when the patches were made). `3af3467` is the name of
the local merge commit of that same tree, which is why the engine id is not one of Madeira's commits. The older numbered patches (`0001` to `0171`) are the history of our changes to
earlier snapshots: the changes they made to Madeira, FEX, Wine and DXMT are part of the five patches above, so do not apply them again to those trees. The patches that touch the glue
under `app/Runtime` are still applied by `tools/vendor_glue.sh`. Where the old and new patches disagree, the five above match what ships.

## Rebuilding

Needs a Mac with Xcode (27) and its Metal toolchain, `xcodegen`, and the build tools Madeira's scripts ask for.

```bash
git clone --recurse-submodules <this repository> && cd <it>
# 0. Our changes to the engine trees (Madeira 5fda6a0 and the four repos it pins, see "Pinned upstream commits"):
git -C vendor/Madeira apply --whitespace=nowarn ../../patches/0172-engine-r28-madeira.patch
git -C vendor/Madeira/FEX apply --whitespace=nowarn ../../../patches/0173-engine-r28-fex.patch
git -C vendor/Madeira/wine apply --whitespace=nowarn ../../../patches/0174-engine-r28-wine.patch
git -C vendor/Madeira/dxmt apply --whitespace=nowarn ../../../patches/0175-engine-r28-dxmt.patch
git -C vendor/Madeira/madeira-dock apply --whitespace=nowarn ../../../patches/0176-engine-r28-madeira-dock.patch
# 1. The native libraries (Wine's unix side, wineserver, DXMT, FEX, FFmpeg, FreeType, GnuTLS), with our patches:
tools/build_wineserver_base.sh                      # the base archive Madeira's wineserver script starts from
tools/build_dxmt_shader_headers.sh && tools/apply_dxmt_patch.sh
tools/apply_madeira_patch.sh
tools/build_fex_ios.sh
#    ...then the build/<name>/build.sh scripts in vendor/Madeira (ntdll-unix, win32u-unix, wineserver, dxmt-ios, ffmpeg, freetype-ios, gnutls-ios)
# 2. Stage them for the Xcode project (also adds our gdiplus.dll, patches/0001):
tools/stage_runtime.sh
# 3. The app:
cp app/Config/Local.xcconfig.example app/Config/Local.xcconfig     # set your own bundle id
cd app && xcodegen generate
xcodebuild -project Porthole.xcodeproj -scheme Porthole -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Wine, GnuTLS, FFmpeg and other LGPL parts are linked statically. Because the steps above rebuild them, you can change any of them and
produce a working app with your modified version, then sign it yourself (Porthole can do that on the device).

Microsoft's Visual C++ runtime is not part of this source or of the app: the app downloads it from Microsoft (Settings > Advanced > Windows components),
so a build needs no copy of it. (A private test build can still bundle a local copy: put the DLLs in `VCRUNTIME_DIR` and package with `F4_BUNDLE_VCRUNTIME=1`.)
Apple's Metal Shader Converter comes from Apple under its own agreement (`d3d12/` in the app).

**Honest status:** this sequence is assembled from the scripts we use. A rebuild from scratch on a clean machine, following only this
file, has not been done yet; if a step is missing or wrong, that is a bug in this document and we want to hear about it.
