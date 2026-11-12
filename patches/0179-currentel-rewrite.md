# 0179: `mrs xN, CurrentEL` in a native ARM64 image's copy becomes `movz xN, #0`

`vendor/Madeira/build/ntdll-unix/virtual_ios.c`: new `ios_jit_patch_currentel`, called where an image's copy is x18-patched (the same place, before the trampoline budget).

**Why.** MSVC's ARM64 runtime puts a start-up stub in every DLL that reads `CurrentEL` and the ID registers, to see whether the CPU has atomic instructions. At EL0 on iOS that read is an
illegal instruction. `ill_handler` emulated it (result 0) and resumed through `ios_fixup_x18_for_return`, which loads **x17 with the resume address** and jumps through the x18 trampoline.
The stub keeps the DLL's data page in x17 across that instruction, so its final `str w16, [x17, #0x90]` (the flag 0x80000000) landed at resume address + 0x90, over the next instructions of
the copy. In Blender 5.2.3's native Arm build that destroyed the start of `tbb12.dll`'s stack-cookie check (`+0x1704`, `ldr x16, [sp, #8]`), which then trapped and failed the DLL's
initialisation with status c000001d. (Found in the 2026-11-05 log: faulting address 0x13378d704 = the `mrs` at 0x13378d670, +4, +0x90.)

**What.** The emulated result is always 0, so the instruction is rewritten in the copy to produce 0 directly. Nothing traps and x17 is never changed. Words in the literal-data map and
`xzr` destinations are left alone. Log line: `[currentel] porthole-0179: N ... rewritten`. `PORTHOLE_NO_CURRENTEL_PATCH=1` turns it off.

**Not fixed here.** `ios_fixup_x18_for_return` still clobbers x17 for every other emulated instruction or store resumed from the pool; any code that keeps x17 live across such an instruction
(only linker/compiler stubs do) can hit the same thing.

Rebuild: `BASE=<current libntdll_unix.a> OUT=$F4_BUILD_ROOT/ntdll-lib-130 tools/rebuild_ntdll_object.sh virtual`, then stage it (`stage-130` here).
