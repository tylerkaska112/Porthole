# 0159 win32u: log why a window fails to be created (log lines only)

`vendor/Madeira/build/win32u-unix/window_ios.c` (the window-creation function of our win32u fork): `ML0159_FAIL` writes `[createwin] 0159 failed at <step> hwnd=... last-error=...` at every point where creating a window can fail (create_window_handle, the CBT hook, apply_window_pos, WM_NCCREATE aborted, WM_CREATE returning -1, the driver's CreateWindow, the window gone after WM_PARENTNOTIFY), and `[createwin] 0159 message-only window created` when a message-only window (parent HWND_MESSAGE) is created. First 40 failures / 20 successes only.

Reason: Counter-Strike 2's first-person look stops at a fixed angle (2026-10-18, 1.1.43). The wineserver diagnostics of patch 0158 showed no raw-input device is ever registered (`raw-mouse processes=0`, no `raw input registered` line), the cursor clamps at the desktop edges, and the game never warps it. The game's SDL3 "SDLRawInput" thread starts, logs `[createwin] 0156 ... parent=0x10028` (a message-only window) and exits at once with status 0, before it can register. These lines show whether that window creation fails, and where.

Build: `tools/rebuild_win32u_ws_object.sh win32u:window_ios:window` into `gl-lib-0159` (copy of `gl-lib-0158`), `LIB_OVERRIDES=<dir> tools/stage_runtime.sh`. Logging only: `tools/engine.sh accept`.
