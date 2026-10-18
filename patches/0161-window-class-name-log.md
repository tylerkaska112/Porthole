# 0161 win32u: log the class name when create_window_handle fails (log lines only)

`vendor/Madeira/build/win32u-unix/window_ios.c`: when `create_window_handle` fails, `[createwin] 0161 create_window_handle failed: class name '...' (atom/ptr) class-instance instance parent owner style ansi`.

Reason: Counter-Strike 2's SDLRawInput thread fails to create its message-only window with last error 6 (STATUS_INVALID_HANDLE). Patch 0160 gave a thread with no usable desktop the process's desktop, but its `[desktop-diag]` lines never appeared in the 1.1.45 run, so the missing desktop was not the cause. The other source of STATUS_INVALID_HANDLE in the server's create_window is `grab_class` (the window class is not found in the process). This line shows which class the thread asked for and with which instance.

Build: `tools/rebuild_win32u_ws_object.sh win32u:window_ios:window` into `gl-lib-0161` (copy of `gl-lib-0160`). Logging only: `tools/engine.sh accept`.
