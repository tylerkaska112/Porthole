# 0195: who owns the address FEX could not decode, and what its RW alias holds

`ill_handler` (signal_arm64_ios.c): after 0194's `[ill-guest-bytes]`, the `[fault-rgn]` explanation of the guest rip (wine view, page protections, view history) and `[ill-rw-alias-bytes]` (32 bytes of the anonymous-JIT RW alias, or "no alias"). Diagnostic only; `tools/engine.sh accept`.

Why: Black Ops Cold War (1.3.102 log, 2026-11-08 23:03): the bytes at the guest rip 0x707159ecda are ARM64 code (`ret`, `add sp, sp, #0x90`, `str x30, [sp, #-16]!`, `adrp`/`ldrb`), not x64. The game rebuilt its image (0193 holds the range), then jumps into memory (its own 508 MB temporary region at 0x7071450000, freed and refilled
from a file read) that holds code of the emulator or of an ARM64 module. The two new lines say whether another module sits at that address or the RX copy and the RW alias disagree.
