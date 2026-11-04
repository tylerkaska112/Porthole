# 0168 FEX: the per-thread L1 lookup-cache reservation follows MADEIRA_FEX_HOTL1

`FEX/FEXCore/Source/Interface/Core/LookupCache.h/.cpp` (`git -C vendor/Madeira/FEX apply patches/0168-fex-l1-reserve-follows-hotl1.patch`, after 0166): `MAX_L1_SIZE` (always 512K entries x 16 B = 8 MB) became `MaxL1Size()`, which is 8 MB with the hot-thread growth on (default, unchanged) and 2 MB (128K entries, `MAX_L1_ENTRIES`) when `MADEIRA_FEX_HOTL1=0`, the existing kill switch that already keeps every thread's L1 at <= 128K entries. The reservation, the zero-scrub, the allocation name and the shrink/decommit length use it. `env.MADEIRA_FEX_HOTL1 = 0` only changes behaviour where it is set (RDR2's game lines).

Evidence (RDR2 through Rockstar's launcher, 2026-10-19): `[fex-va]` at the crash with ~310 threads: 231-274 views of 8 MB (flags 0x23) = the lookup caches, 1.8-2.2 GB of the 15 GB emulator band, for ~2 MB of L1 actually used per thread. 6 MB x ~300 threads = 1.8 GB back.

Rebuild: the cmake recipe of 0143, output `Bin/libarm64ecfex.dll` shipped as `ec-out/xtajit64.dll`. Unverified on a device.
