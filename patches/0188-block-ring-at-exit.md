# 0188: the block ring is also dumped when the program exits by itself

`MADEIRA_BLOCK_RING` (engine option, Settings > Advanced > Engine options) records the last 4096 x86 blocks each thread entered; until now it was only written when the thread faulted
fatally or a memory watch hit. A program whose protection stub ends the run on purpose (Umamusume: Pretty Derby calls `ExitProcess(0)` from its own `.bind` section a second after launch,
problem report #34) never faults, so there was nothing to read. 0188 writes the calling thread's ring (1536 entries, the x86 bytes of each block, oldest first) from `NtTerminateProcess`
next to the existing `[term-stack]` lines, `[block-ring] ml1205 (exit)`. It does nothing unless the ring is switched on for the thread, and writes at most twice per process.

Files: `build/ntdll-unix/signal_arm64_ios.c` (`ios_block_ring_dump_current`), `build/ntdll-unix/process_ios.c` (the call). Rebuild: `tools/rebuild_ntdll_object.sh process signal_arm64`
(BASE = the library already in use), then link it into the stage's `lib/`. No change to how games run, so `tools/engine.sh accept`.
