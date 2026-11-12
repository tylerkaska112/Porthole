# Cycles on Metal: feasibility spike (2026-11-06)

Not part of the app. Tests the two things a port of Cycles' Metal backend (Blender on Porthole, GPU rendering) stands on:

1. a Metal buffer wrapped around ordinary memory (`newBufferWithBytesNoCopy`, 16 KB aligned) is read and written by the GPU in place: no copy between a Windows program's memory and Metal;
2. Cycles' own Metal kernel source (`intern/cycles/kernel/device/metal/kernel.metal` of Blender 5.2.3, includes expanded exactly as Cycles' `path_source_replace_includes` does) compiles with `newLibraryWithSource`, as Cycles does at run time, and compute pipelines build from it.

Run on a Mac (the M4 Mac is the iPad's GPU family):

```bash
git clone --depth 1 --filter=blob:none --sparse --branch v5.2.3 https://github.com/blender/blender.git blender-src
(cd blender-src && git sparse-checkout set intern/cycles)
clang++ -std=c++17 -fobjc-arc -O1 -w main.mm -framework Metal -framework Foundation -o spike
./spike blender-src/intern/cycles
```

Result on an Apple M4: zero-copy YES; kernel source 2.7 MB after includes compiles in about 5 s (75 kernels, 89 with MetalRT); pipelines for `integrator_init_from_camera` and `queued_paths_array` build in under a second.
