# 0193: image hold (opt-in, `env.MADEIRA_IMAGE_HOLD = 1`)

`build/ntdll-unix/virtual_ios.c` (`ios_image_hold_*`). Call of Duty: Black Ops Cold War's copy protection unmaps its own 533 MB executable image and builds it again at the same base with `NtAllocateVirtualMemory`, piece by piece. Every pseudo-process shares one address
space here, so the range freed by the unmap went to whoever asked next: Steam's service mapped and unmapped one page at 0x7047d20000 over and over, and the game's reserve there failed with `STATUS_CONFLICTING_ADDRESSES` (`[alloc-fail] ml814 ... status=c0000018`, 2026-11-08 log). The protection took
that for tampering and never rebuilt its code; the first read of the missing image raised an access violation whose unwinding read the same missing image again, 1.9 million times, until the stack ran out (exit 0xC00000FD, `[fault-rgn] history: view ... DELETED by tid ...`).

* `unmap_view_of_section`: when the process unmaps its main image (PEB ImageBaseAddress, at least 64 MB) the view is deleted as before and the same range becomes a **free placeholder view** (`map_fixed_area` PROT_NONE + `create_view(VPROT_PLACEHOLDER | VPROT_FREE_PLACEHOLDER)`), so no other process's allocation can land in it. `[image-hold] ... held for it`.
* `allocate_virtual_memory`: a `MEM_RESERVE` at an address inside a hold first takes the part it covers out of the placeholder (`free_pages`, under `virtual_mutex`, so nothing slips in between); the ordinary reservation follows. `[image-hold] ... piece(s) taken out of the placeholder, status ...`.
* A hold ends after 900 s (looked at the next time a hold is made or carved), giving the remaining placeholder pieces back. Up to 4 holds.
* Off unless `MADEIRA_IMAGE_HOLD=1`; nothing changes for any other game. The app sets it for Steam app 1985810 (GameFixes).

Not verified on a device when written. Rebuild: `build/ntdll-unix/build.sh` (writes `app/Madeira/libntdll_unix.a`, which the stage links). `tools/engine.sh accept`.

**1.3.101 (first device log of 1.3.100, 2026-11-08 22:01):** the hold worked: `[image-hold] ... held for it`, then two reserves carved fine (0x704cc40000+0x400000, +0x10000), but the third, the rest of the image (0x704d060000+0x1f83f000, MEM_RESERVE|MEM_COMMIT), failed c0000018. A view's size is a multiple of 4 KB and the host page is 16 KB, so the carve rounded the end of the last piece DOWN to a 16 KB boundary and left a 12 KB tail of the placeholder; the game's map ran into it.
A request that reaches the end of a placeholder now takes it to its exact end.
