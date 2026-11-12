# 0191: Lossless Scaling frame generation for Direct3D 12 games

Patch 0189 runs Lossless Scaling's passes inside DXMT's Direct3D 11 swap chain, so a Direct3D 12 game (Grand Theft Auto V Enhanced, Red Dead Redemption 2, ...) never got extra frames: its swap chain
belongs to `madeira_d3d12.dll`, which presents with Metal directly. This patch adds a **bridge**: the same passes (`d3d11_lsfg.hpp`, unchanged) run on a Direct3D 11 device of their own inside
`d3d11.dll`, and `madeira_d3d12.dll` hands the finished picture over and presents what comes back.

* `dxmt/src/d3d11/d3d11_lsfg_bridge.cpp` (new, exported `DXMTLsfgBegin`, `DXMTLsfgRun`, `DXMTLsfgAbort`, in `d3d11.def`): reads the same control file (`MADEIRA_LSFG_CTL`) and writes the same status file as the Direct3D 11 path,
  makes its own device on first use, keeps one texture the game's picture is copied into, runs `FrameGen`, and returns the Metal texture handles of the generated pictures. The decision "does this frame get extra frames" (game speed against
  the screen's rate, switched on/off, passes rebuilt on a setting change or a resolution change) is the swap chain's, copied.
* `d3d11_fence.cpp/.hpp`: `CreateFenceExposingEvent`, a Direct3D 11 fence whose `MTLSharedEvent` handle the caller gets as well. Three events join the two Metal queues: `input` (the picture was copied; the passes wait for it), `out` (the passes
  are done; the copies to the screen wait for it) and `done` (the generated pictures were copied out; the next run waits for it before it writes them again).
* `madeira-d3d12/src/pe/madeira_d3d12.c` (`mad_lsfg_before`, `mad_lsfg_show`, called from `mad_present_run` just before the drawable of the real frame is taken): `LoadLibraryA("d3d11.dll")` + `GetProcAddress` once (only when `MADEIRA_LSFG_CTL`
  or `MADEIRA_LSFG` is set), then per present: `DXMTLsfgBegin` -> blit the swap chain buffer into the bridge's texture on the queue, signal `input` -> `DXMTLsfgRun` -> for each generated picture: its own command buffer that waits for `out`,
  blits into a drawable and presents it (the last one signals `done`) -> the game's own picture as before. One swap chain only (the first one that is at least 640x360); not with the MetalFX spatial scaler of madeira.cfg `metalfx-upscale`.
  Every failure path returns 0 and the game just gets no extra frames; `[lsfg]` lines in the log and the status file say why.

Risks (not verified on a device when written): the second Direct3D 11 device's command queue never sees a Present, so any per-frame bookkeeping DXMT does at Present is missing there; the generated pictures are `R8G8B8A8`/`B8G8R8A8`/`R10G10B10A2`/`R16G16B16A16F`
only (other formats say "not supported" in the status); a swap chain format whose Metal pixel format differs from the generated picture's would fail the blit; extra memory (several full-size pictures plus the second device).
Does not change anything while the switch is off, so `tools/engine.sh accept`.

Rebuild: `ninja -C dxmt/build-arm64ec-r29 src/d3d11/d3d11.dll`, `arm64ec-w64-mingw32-strip --strip-debug`; `build/madeira-d3d12/build-pe.sh` (output `out-pe/d3d12.dll`, which is also `madeira_d3d12.dll`); copy all three over `ec-out-r29/` and the stage's `Resources/arm64ec-windows/`.

**1.3.93 (after the first device logs of 1.3.92):** (1) `lsfg::processAllowed()` (d3d11_lsfg.hpp): the control file is shared by every program in the prefix, so Rockstar's Launcher and Social Club helper (and Steam, other launchers, browser helpers) ran the
passes too, on windows of 1280x600 and 700x800 at 2-8 FPS, while the game was starting; now only a program whose name is not a launcher/helper/service/installer gets frame generation (`MADEIRA_LSFG_ANY_PROCESS=1` lifts it), and swap chains
under 640x360 are skipped, in both the Direct3D 11 swap chain and the bridge. (2) The bridge logs a line every 5 s (`presents seen / asked for the passes / skipped`) because the first logs showed nothing of what it decided. (3) `mad_lsfg_show` waits
for the passes on the CPU for at most 400 ms before queueing the copy (the queue is in order; a GPU-side wait on events that never come would have held every later command buffer of the game), and on a timeout asks the bridge to switch itself off
(`DXMTLsfgAbort` with `reserved = 1`; status "the passes did not finish in time ...").

**1.3.94 (first in-game log of 1.3.93):** the 400 ms bounded wait of 1.3.93 fired on the very first frame (the first run of each shader is compiled by Metal and takes seconds) and switched the feature off after blocking the present thread; the second time it was switched on it ran well ("game 22 fps, generated 44/s, passes cost
3 ms on the present thread", i.e. about 66 FPS shown). Now: the bridge starts no new passes while the previous frame's are still running on the GPU (`out` event not reached; `cBusy` in the heartbeat) and only takes itself for stuck after 20 s; `mad_lsfg_show` waits 40 ms at most for the passes and shows the
frame without the extra pictures when they are not done, never blocking the queue.

**1.3.96 (Schedule I, a Unity game, Direct3D 11):** the menu said "Not working: the game's back buffer format (29) is not supported" (29 = `R8G8B8A8_UNORM_SRGB`). `FrameGen` now accepts `R8G8B8A8_UNORM_SRGB` and `B8G8R8A8_UNORM_SRGB`: the history pictures keep the back buffer's own format, so the shaders' sampling reads linear light through the sRGB view, and the generated pictures are `R16G16B16A16_FLOAT` (an 8-bit linear picture would band in shadows). The presenter's pipeline (built from the swap chain's format) treats its source as sRGB and encodes what it samples (`present_backbuffer_is_srgb` -> `to_srgb`), so linear floats come out right through the same pipeline as the game's own frame. `generatedFormat()` tells the caller; the Direct3D 12 bridge refuses a swap chain whose generated format differs from its own (a blit cannot convert), and the MetalFX spatial variant (`ctx.upscale` needs the scaler's color format) is not meant to work with it. Not verified on a device: whether the shaders' typed UAV declaration accepts a float view, and the brightness of the generated pictures (too bright or dark would mean the presenter's constant does not apply as read).
