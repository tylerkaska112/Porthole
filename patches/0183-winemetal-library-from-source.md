# 0183: winemetal can compile Metal source (Cycles on Metal)

Adds `MTLDevice_newLibraryWithSource` to DXMT's `winemetal` layer, unix-call slot **160** (slots 151-159 are left empty on purpose: upstream Madeira appends to the table, and a Porthole
call must not move when it does). A Windows program passes Metal Shading Language source text, a language version (`0x0302` = Metal 3.2) and flags (bit 0: fast math) and gets back a
library handle, or an error handle (a retained NSError the caller releases). Local rendering only: the remote path returns STATUS_NOT_IMPLEMENTED.

Why: Cycles' Metal backend compiles its kernels from source at run time; to run it from Windows Blender on Porthole (GPU rendering) the Metal layer has to do the same.
Nothing in Porthole calls it yet except `tools/spikes/cycles_metal/win/mtltest.cpp`; games are not affected (a new, unused table entry).

Only `winemetal_unix.c` matters for the call to work (the PE side, `winemetal.dll`, is not rebuilt: the test program makes the unix call itself). Rebuild:

```bash
tools/build_winemetal_unix.sh      # copies dxmt/src/winemetal to $F4_BUILD_ROOT/.., applies this patch, compiles winemetal_unix.o, replaces it in a COPY of libdxmt_combined.a
ln -sfn "$F4_BUILD_ROOT/dxmt-lib-130/libdxmt_combined.a" "$F4_BUILD_ROOT/stage-130/lib/libdxmt_combined.a"      # or LIB_OVERRIDES=<that folder> when staging
```
