# 0180: every register of the first two unhandled faults, in one log line

`vendor/Madeira/build/ntdll-unix/signal_arm64_ios.c`, next to `[ec-fault-regs]`: `[fault-regs-all] x0=… x28=… fp=…` and 64 bytes at x0 and x19..x22 when they look like pointers. Log only; nothing changes
how a program runs. Added to explain the null table read in `OpenImageIO_Util.dll` (native Arm Blender 5.2.3): the register that faulted (x8 = 0) says nothing about the object the code was given (x20).

Rebuild: `BASE=<libntdll_unix.a with 0179> OUT=$F4_BUILD_ROOT/ntdll-lib-130b tools/rebuild_ntdll_object.sh signal_arm64`, stage as `stage-130`.
