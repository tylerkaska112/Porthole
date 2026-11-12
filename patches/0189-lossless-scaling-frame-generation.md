# 0189: Lossless Scaling frame generation, through the D3D11 interface

DXMT's swap chain (`src/d3d11/d3d11_swapchain.cpp`, new `src/d3d11/d3d11_lsfg.hpp`) can make the pictures between a game's own frames with the motion-estimation compute shaders of **Lossless
Scaling** (the owner's own copy of `Lossless.dll`, read on the device by the app, see `app/Sources/Core/LosslessScaling.swift`). Nothing from Lossless Scaling is in this repository or in the
app: the shaders arrive as a file the app writes into the game's prefix for the length of the session (`C:\ProgramData\Porthole\lsfg.bin`, `MADEIRA_LSFG_SHADERS`).

**Inactive unless the app sets `MADEIRA_LSFG_CTL`** (a control file, `C:\ProgramData\Porthole\lsfg.ctl`; the older `MADEIRA_LSFG=1` also works). The app sets it for every game while the licence receipt is valid; the file says `enabled=`, `generated=` (1-3 frames per real one), `flow=` (motion-search divisor 1-4), `force=` (generate even when the game is fast), `hz=`. The engine looks at it twice a second, so the in-game menu changes it live (switching on, or changing frames/flow, rebuilds the passes: a hitch). The engine writes `<control file>.status` (state, game fps, generated/s, cost, or the reason it cannot work) for the menu. `MADEIRA_FRAMEGEN_HZ` is the screen's rate; the MetalFX path `MADEIRA_FRAMEGEN` is switched off while this is on.

How it works: every `Present1` copies the back buffer into one of two history textures and records Lossless Scaling's passes (mipmaps, alpha x7, beta, gamma x7, delta x3, generate: 25 distinct
shaders, about 70 dispatches) on a **deferred context**, finishes the command list and runs it on the game's immediate context with `ExecuteCommandList(list, TRUE)` so the game's own state is put back.
Then `ctx.present()` is emitted for each generated texture and finally for the real back buffer. A game that already runs near the screen's rate gets no extra frames (and no passes are run).
The shaders are ordinary D3D11 compute shaders, so DXMT's own converter turns them into Metal.

The pass layout (which shader, what it reads and writes, thread-group counts, the constant buffer) follows lsfg-vk 1.0.0 (MIT, copyright (c) 2025 lsfg-vk contributors, `framegen/v3.1_src`); it was
checked against Lossless.dll 3.2.1 by reading each shader's own reflection data (sampler/texture/UAV counts, thread groups and constant-buffer fields all match). Quality ("3.1") layout only; the
performance shaders (`p_*`) have another layout and are not used yet. Direct3D 11 swap chains, 8-bit/10-bit/FP16 back buffers, no multisampling.

Rebuild: `ninja -C dxmt/build-arm64ec-r29` with the llvm-mingw toolchain on PATH, `arm64ec-w64-mingw32-strip --strip-debug`, copy `d3d11.dll` over `ec-out-r29/` and the stage's `Resources/arm64ec-windows/`.
Not verified on a device when written. Does not change how any game runs while the switch is off, so `tools/engine.sh accept`.

**With the MetalFX spatial swap chain** (`DXMT_METALFX_SPATIAL_SWAPCHAIN=1`, the app's per-game "Upscaling" with `d3d11.metalSpatialUpscaleFactor`): the passes run at the game's own resolution (the back buffer), and each generated picture is then enlarged with the same scaler into its own output texture (`upscaled_generated_`) and presented before the real, enlarged frame.

**Performance layout** (`performance=1` in the control file, the app's "Lighter passes", on by default): the `p_*` shaders (ids 280-302) with fewer and smaller intermediate pictures (alpha 1/2 images instead of 2/4, beta and gamma/delta history 2 instead of 4, gamma/delta temporaries 3+2 instead of 4+4, delta's last stages 1 instead of 2); the chain of passes is the same (lsfg-vk 1.0.0 `framegen/v3.1p_src`, checked against the shaders' reflection like the quality layout). Each dispatch now binds only as many SRV/UAV slots as it uses (plus those the dispatch before used, which have to be cleared).

**`measure=1`** (menu: "Measure only"): the passes run every frame but the generated pictures are not presented, so the game's frame time shows what the passes cost without the extra drawables the screen needs for showing more frames.

**Presents (fix after the first Lethal Company logs):** the encode thread takes a drawable while it builds a command buffer, and the drawable only goes to the screen when the buffer is committed; a layer has three, one of them on the screen. All presents of a frame in ONE buffer needed (added + 1) drawables at once: with 2 added the third `nextDrawable` waited for the layer's timeout (game at 3 FPS), with 1 added the real frame waited a refresh or two for the first (the game locked to 3 refreshes = 40 FPS on a 120 Hz screen). Each generated frame is now emitted in its own chunk and committed before the next is built.
