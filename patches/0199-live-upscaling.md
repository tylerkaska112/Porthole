# 0199: upscaling that the in-game menu changes while the game runs

Until 1.3.107 MetalFX upscaling was fixed at the game's start (env `DXMT_METALFX_SPATIAL_SWAPCHAIN` / `DXMT_METALFX_FIT`, madeira.cfg `metalfx-upscale`); changing it meant restarting the game. The user asked for an on/off and adjust control in the in-game menu.

**Control file.** `MADEIRA_UPSCALE_CTL` = `C:\ProgramData\Porthole\upscale.ctl` (the app's `LiveUpscaling`): lines `mode=0|1|2` (off / to the screen / fixed), `factor=1.5`, `fit=<screen w>x<screen h>`. The engine looks at it twice a second and writes `upscale.ctl.status` (`state=on|off|same-size|unsupported|error`, factor, from, to) for the menu. Without the variable everything is as before. `env.MADEIRA_UPSCALE_LIVE = 0` (config) leaves the file out.

**Direct3D 11 (dxmt `d3d11_swapchain.cpp`, new `d3d11_upscale_ctl.hpp`, `Presenter::setScaleFactor`).** With the control file the MetalFX swap-chain variant is made for every game (in a process that `lsfg::processAllowed()` accepts: launchers and helpers are never upscaled); `upscale_on_` says whether the picture is enlarged now. `UpscalePoll()` (start of `Present1`) rebuilds on a change: commit, `WaitUntilGPUIdle`, drop the frame-generation passes and the enlarged generated pictures, new `scale_factor`, `ApplyLayerProps()`, `BuildUpscaler()` (enlarged back buffer + scaler; dropped when off, so a game that is not upscaled holds no memory for them). `ResizeBuffers` now works the factor out again for the new size (to the screen), the present paths take the plain route while `upscale_on_` is false.

**Direct3D 12 (`madeira_d3d12.c`).** `mad_up_poll`/`mad_up_spec` read the file (else madeira.cfg `metalfx-upscale`); `mad_swap_make_fx` uses the spec and writes the status; `mad_swap_upscale_poll(s)` (in `mad_present_run`, before the shared-layer check) releases and rebuilds the fx scaler/textures when the file's version changed and re-applies the layer's drawable size.

Not verified on a device. Rollback: `build-root/backups-upscale-live/` has the previous d3d11.dll / d3d12.dll / madeira_d3d12.dll. `tools/engine.sh accept`.
