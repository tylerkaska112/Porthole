# 0169 FEX: MADEIRA_COMPILE_LOG - log the code of each compiled block (diagnostic)

`FEX/FEXCore/Source/Interface/Core/Core.cpp` (`git -C vendor/Madeira/FEX apply patches/0169-fex-compile-log.patch`): with `MADEIRA_COMPILE_LOG=1`, every block FEX compiles at a guest address in 0x7000000000-0x71f0000000 (the game exe, not Wine's DLLs at 0x71f...) logs `[cblog] rip=… start=… len=… bytes=<up to 512 hex bytes; a block starting with 32 zero bytes is logged only 3 times (1.2.44; lines are cut into 192-byte `[cblog+]` pieces since 1.2.45 because one overlong message overflows Wine's 1 KB debug buffer and kills the game with 0x80000005)>`, up to `MADEIRA_COMPILE_LOG_LIMIT` lines (default 10000). Off by default, no effect on other games.

Why: Black Ops III's Arxan loop runs on ~1100 compiled blocks (`real_compiles` frozen) at 99% CPU; the bytes let us disassemble the loop offline (python capstone) and see which check never passes.

Rebuild: `/tmp/claude-501/fexbuild.sh` (cmake recipe of 0143) -> `Bin/libarm64ecfex.dll`, shipped as `ec-out/xtajit64.dll` (copy also into `stage-head/Resources/arm64ec-windows/`). Backup of the previous DLL: `ec-out/xtajit64.0168.dll.bak`.
