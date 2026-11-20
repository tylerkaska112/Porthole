# 0203 The D3D12 layer can say where Metal's memory grows (gpu-attr)

`madeira-d3d12/src/pe/madeira_d3d12.c` (engine clone commit dcc131f): with `madeira.cfg gpu-attr = 1` (default 0, a diagnostic) every Metal allocation made at the layer's allocation sites
(pipelines at first draw, at creation and as vertex-descriptor variants, compute pipelines, shader libraries created and read back, textures, buffers, descriptor heap buffers,
argument-ring chunks, scratch buffers, placement heaps) is bracketed with `MTLDevice_currentAllocatedSize` before and after, and the growth is added to its site. The 5 s memory census prints one
`[madeira-d3d12] gpu-attr:` line with MB, calls and calls-that-grew per site, and the sum against Metal's total.

Why: the `metal-gap` line explains about 60 % of Metal's total in Grand Theft Auto V Enhanced and leaves "the rest" (649-750 MB, growing in steps) unexplained; settings (720p, vram-mb, pso-lazy-libs) do not touch it.
Other threads allocate at the same time, so read sums over many calls. Off, it costs one cached flag test per allocation. The DLL is `d3d12.dll` and `madeira_d3d12.dll` (the same file) in the staged runtime.

**Also in 0203 (1.4.14): `upload-swap-min-kb`** (madeira.cfg / a game's config; default 8192 = the old fixed 8 MB). The size from which a CPU-visible (UPLOAD/READBACK) buffer gets storage of our own on the file tier
(ml1154), off the jetsam footprint. The gpu-attr run of Grand Theft Auto V Enhanced (2026-11-13) showed 6,928 live CPU-visible buffers, 616 MB, of which only 2 (130 MB) were on the file tier: the rest are under 8 MB.
Try `upload-swap-min-kb = 256`. The `metal-gap` line's "texture heaps" now reads the current device's heaps (it printed 0 once `g_hp_dev` was cleared; the 5 heaps of 64 MB were inside "the rest").
