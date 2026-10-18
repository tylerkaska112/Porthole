# 0158 Wineserver: look diagnostics (log lines only)

`vendor/Madeira/build/wineserver/queue_ios.c` (the wineserver's input queue, linked into the app as libwineserver.a): two kinds of log line, nothing that changes behaviour.

* `[look-diag] ml1400 raw input registered by pid ...: usage ... flags ... target ...`: what a program asked for with RegisterRawInputDevices (`update_rawinput_devices`).
* `[look-diag] ml1400 relative moves=N net dx dy |dx| cursor=(x,y) clipped= foreground= raw-mouse processes= flags= target=`: once a second while relative mouse moves arrive (Porthole's first-person look): how many, how far, where the server's cursor is (it clamps at the desktop edge), whether a foreground thread exists to get raw input, and the raw-input mouse device each registered process holds.

Reason: Counter-Strike 2 (2026-10-18, 1.1.41): first-person look turns the view only until it stops at a fixed angle ("like the mouse reaches the edge of the screen"), only in CS2. Porthole's log showed every relative move delivered (1,345 moves, 29,375 counts of |dx|); the server hands raw input the unclamped delta, so a program reading WM_INPUT cannot stall at an edge. CS2 starts a raw-input thread (SDLRawInput), so the open question is whether it registers raw input at all, with which flags (RIDEV_NOLEGACY / INPUTSINK) and target, whether WM_INPUT reaches it, and whether the cursor clamps. These lines answer that on the next CS2 run.

Build: `vendor/Madeira/build/wineserver/build.sh`, copy `build/wineserver/obj/libwineserver.a` into a library override folder (`gl-lib-0158`, the other libraries copied from `gl-lib-0157`), `F4_BUILD_ROOT=... LIB_OVERRIDES=<dir> tools/stage_runtime.sh`. Logging only, so `tools/engine.sh accept`.
