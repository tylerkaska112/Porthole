# 0197: generated pictures of another format get their own MetalFX scaler

Schedule I (sRGB back buffer, Direct3D 11) with MetalFX upscaling and Lossless Scaling frame generation both on flickered badly (2026-11-08 23:38, 1.3.104): the generated pictures are `R16G16B16A16_FLOAT` for an sRGB back buffer (0191/1.3.96) but were enlarged with the scaler that was made for the back buffer's own format, into textures of the back buffer's format, so every generated frame was garbage between real ones.
`EnsureUpscaledGenerated(i, generated)` now compares the generated texture's Metal pixel format with the back buffer's: when they differ it makes a scaler for that format (`metalfx_scaler_gen`, output format the same) and enlarged pictures in `lsfg_->generatedFormat()`; the present loop uses it. Same format (UNORM back buffers): unchanged.
Not verified on a device. `tools/engine.sh accept`.
