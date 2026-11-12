# 0182: LdrFindEntryForAddress also finds a module by an address in its JIT-pool copy (native ARM64)

`vendor/Madeira/wine/dlls/ntdll/loader.c`: when the module tree has no entry for an address, the native aarch64 build asks `xlate_ios_jit_rev` (the pool-to-image hook the unwinder already uses) for the address in the image
and looks that up.

**Why (Blender 5.2.3 native Arm, 2026-11-05).** Native ARM64 code runs from a copy in the JIT pool, so the address a function computes for itself (`adrp`/`add` of one of its own functions) is a pool address. USD's
`Arch_ConstructorInit` passes such an address to `GetModuleHandleExW( FROM_ADDRESS | UNCHANGED_REFCOUNT )`, got no module, and read the PE header at null + 0x3c (`usd_ms.dll+0x40bd4`), failing the DLL's initialisation. `GetModuleHandleExW`
and `RtlPcToFileHeader` both end in `LdrFindEntryForAddress`.

Only the failing lookup changes: an address that is in a module's own range is found exactly as before. Rebuild as for 0181 (same tree, same strip, no padding). The result keeps the section layout and the 1,465 exports.
