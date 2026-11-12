# 0190: the on-device shader converter is built with NDEBUG (assert() off), as upstream's builds are

`build/dxmt-ios/build.sh` compiled airconv (the DXBC-to-Metal converter) and the DXBC parser for the device with `-O2` and no `-DNDEBUG`, so every `assert()` in them was live. Upstream builds
(meson, release) define NDEBUG and Madeira's own tested lists were made with those. 2026-11-08, GTA V Legacy (1.3.85, log GTA5.exe-2026-11-08_05-41-30): the game started, opened its window and
ended 9 s later with exit code 0x80000101 right after `Assertion failed: (0 && "Unexpected/unhandled geometry shader siv"), function handle_signature_gs, file dxbc_signature.cpp, line 1054.`
(a geometry shader declaring an input system value other than position; with NDEBUG the case is simply skipped, which is how Madeira's list ran the game at 38-60 FPS).

Change: `AIRCONV_DEFS` in `build/dxmt-ios/build.sh` gains `-DNDEBUG`. Rebuild: `touch dxmt/shader-headers/* build/dxmt-ios/shader-headers/*` (the Metal compiler of this Xcode refuses to regenerate air_tessellation's header), `bash build/dxmt-ios/build.sh`
(refreshes libdxmt_combined.a in place and copies it to app/Madeira), then build-root/r29-winemetal.sh (patches 0183-0187 into a copy). The library before: backups/libdxmt_combined.before-ndebug.a.
Affects every game that reaches an assert in the converter (it used to end the process, now the case is skipped): `tools/engine.sh bump`.
