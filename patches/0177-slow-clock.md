# 0177 / 0178: a slower clock for named programs (1.2.133)

`madeira.cfg`: `slow-clock = Launcher.exe:0.4` (program : speed; several separated by `;`; 1.0 = real time; 0.05 to 1.0). Env fallback: `MADEIRA_SLOW_CLOCK`.

Why: Rockstar's Launcher gives its Social Club browser (SocialClubHelper.exe) about 31 s to show a window (`Timed out waiting for browser window`, `SC_INIT_ERR_WEBSITE_FAILED_LOAD`).
Under emulation the helper's first window comes 35-36 s after it starts (two runs of Grand Theft Auto V Enhanced, 2026-11-04), so the launcher gave up and never started the game.

What it does, for the named programs only (matched on the image's file name, per process):
* `NtQueryPerformanceCounter` returns a counter that runs at `speed` of real time (continuous: it starts from the real value when the program first asks).
* Every finite relative timeout of 1 s or more in `NtWaitForSingleObject`, `NtWaitForMultipleObjects`, `NtDelayExecution` and `NtWaitForAlertByThreadId` is stretched by 1/speed.
* Everything inside ntdll (the wait conversion in `server_wait`, `NtQueryTimer`) keeps the real clock through `ios_qpc_raw()`; the wineserver, the game and the helper are not touched.

What it cannot do: `GetTickCount` and friends read `user_shared_data` straight from memory, one page for every program, so they stay real. If the launcher times that wait with GetTickCount, this changes nothing: the log lines tell
(`[slow-clock] ... runs at 400/1000`, `... has read the performance counter N time(s)`, `... wait of 30000 ms becomes 75000 ms`).

Files: `build/ntdll-unix/server_ios.c` (0177, against the Madeira clone) and `wine/dlls/ntdll/unix/sync.c` (0178, against the Wine clone). Rebuild:
`OUT=$F4_BUILD_ROOT/ntdll-lib-r28b BASE=<engine>/app/Madeira/libntdll_unix.a tools/rebuild_ntdll_object.sh sync server`, stage with `LIB_OVERRIDES=$F4_BUILD_ROOT/ntdll-lib-r28b`.
