# 0181: a native ARM64 program's TLS index is synced into its JIT-pool copy

`vendor/Madeira/wine/dlls/ntdll/loader.c`, `alloc_tls_slot`: the `unix_ios_sync_pe_write` call (copies the loader's `_tls_index` into the JIT-pool copy of the image) was compiled only for `__arm64ec__`.
The native `aarch64-windows/ntdll.dll` (used by native ARM64 programs and by Wine's own helper programs) did not have it, so an image's copy kept `_tls_index = 0` and every library read the main
program's TLS block (the loader's own comment: "every DLL uses the main EXE's TLS[0]").

**Symptom (Blender 5.2.3 native Arm, 2026-11-05):** MSVC thread-safe statics (`if (guard > _Init_thread_epoch) construct`) read `_Init_thread_epoch` from the wrong block (0 instead of 0x80000000), concluded
the object was already built, and used an empty table: `OpenImageIO_Util.dll` crashed with a null read in `ustring::make_unique` (`ustring_table()` returned zeroed memory) and failed to initialise (c0000005). The register dump
(patch 0180) showed the table object as zeros with only the lock count 1 that this very function had just added.

**What.** `#ifdef __arm64ec__` becomes `#if defined(__arm64ec__) || defined(__aarch64__)`. The unix call number already exists for both builds (append-only enum in `unixlib.h`).

Rebuild: `cd vendor/Madeira/wine/build-aarch64-r27 && make dlls/ntdll/aarch64-windows/ntdll.dll`, then `aarch64-w64-mingw32-strip` (no padding: the shipped file is the stripped build, 1,048,576 bytes). The result has the same sections and the same 1,465 exports as the shipped file.
Stage it as `Resources/aarch64-windows/ntdll.dll` (stage-130 holds a real copy of that folder with this file replaced).
