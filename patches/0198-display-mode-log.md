# 0198: log what a game's resolution list is built from

Diagnostic only. `[vmode] 0198 EnumDisplaySettings index N = WxH` / `no more modes (current, session default, cap)` (win32u, first 80 lines) and `[wsi-modes] 0198 GetDisplayModeList index N (user32 table, DXMT_WSI_MODE_TABLE | short list): WxH` (DXMT, first 60 lines).
Why: How to Fish (Unity, Direct3D 12, 1.3.106, 2026-11-08 23:57) still offers only 1080p although 1.3.106 turned `DXMT_WSI_MODE_TABLE` on for every game; the log shows no enumeration at all, so it is not known which interface the game's list comes from or what it gets.
`tools/engine.sh accept`. Rebuild: `rm build/ntdll... ` no: `rm -f build/win32u-unix/obj/libwin32u_unix.a; build/win32u-unix/build.sh` (else FreeType is merged in again, 42 duplicate members), `ninja -C dxmt/build-arm64ec-r29 src/dxgi/dxgi.dll src/d3d11/d3d11.dll`, strip, copy dxgi.dll and d3d11.dll over ec-out-r29/ and the stage.
