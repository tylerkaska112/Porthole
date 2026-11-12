#!/bin/bash
# Builds winemetal natively for macOS (its unix side and its C wrappers, DXMT_NATIVE) with the Porthole patches 0183-0185 and runs native/native_test.cpp against it.
# Needs the private copy made by tools/build_winemetal_unix.sh ($F4_BUILD_ROOT/winemetal-work/tree) or the pinned dxmt with the patches applied. Usage: run.sh [cycles_kernel.metal]
set -eu
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
ROOT="${F4_BUILD_ROOT:-$HERE/build}"
ENGINE="$(cd "$HERE/vendor/Madeira" && pwd -P)"
TREE="$ROOT/winemetal-work/tree/dxmt/src/winemetal"
[ -d "$TREE" ] || { echo "run tools/build_winemetal_unix.sh first"; exit 1; }
SDK=$(xcrun --sdk macosx --show-sdk-path); OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
INC="-I$ENGINE/dxmt/src/nativemetal -I$ENGINE/dxmt/include -I$ENGINE/dxmt/libs -I$TREE -I$ENGINE/dxmt/src/airconv"
sed 's/os_proc_available_memory()/((size_t)(8ull<<30))/g' "$TREE/unix/winemetal_unix.c" > "$TREE/unix/winemetal_unix_mac.c"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -fblocks -O1 -w -x objective-c -DDXMT_NATIVE=1 $INC -c "$TREE/unix/winemetal_unix_mac.c" -o "$OUT/unix.o"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -fblocks -O1 -w -x objective-c -DDXMT_NATIVE=1 $INC -c "$TREE/unix/cache.c" -o "$OUT/cache.o"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -std=gnu2x -O1 -w -DDXMT_NATIVE=1 $INC -c "$TREE/winemetal_thunks.c" -o "$OUT/thunks.o"
for f in DXSOCompile DXSODestroy DXSODestroyBitcode DXSOGetCompiledBitcode DXSOInitialize SM50Compile SM50CompileGeometryPipelineGeometry SM50CompileGeometryPipelineVertex SM50CompileTessellationPipelineDomain SM50CompileTessellationPipelineHull SM50Destroy SM50DestroyBitcode SM50FreeError SM50GetArgumentsInfo SM50GetCompiledBitcode SM50GetErrorMessage SM50Initialize ios_exc_msg_count ios_fps_cap_dxmt_pace ios_frame_drawable_wait ios_frame_encode_present ios_frame_game_tick ios_frame_gpu ios_frame_limiter ios_frame_note_display ios_frame_pass ios_frame_stats_on ios_srv_req_count ios_srv_wait_count ios_srv_wait_req_us ios_srv_wait_timeouts ios_srv_wait_us ios_xp_pe_block ios_xp_pe_len ios_xp_set_role madeira_frame_mark madeira_ir_convert madeira_swap_overlay_stats sqlite3_bind_blob64 sqlite3_clear_bindings sqlite3_close sqlite3_column_blob sqlite3_column_bytes sqlite3_errmsg sqlite3_exec sqlite3_finalize sqlite3_free sqlite3_open_v2 sqlite3_prepare_v2 sqlite3_reset sqlite3_step wmt_api_census_note; do echo "int $f(void) { return 0; }"; done > "$OUT/stubs.c"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -c "$OUT/stubs.c" -o "$OUT/stubs.o"
xcrun clang++ -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -std=c++20 -O1 -w -DDXMT_NATIVE=1 -I"$TREE" "$(dirname "$0")/native/native_test.cpp" "$OUT/thunks.o" "$OUT/unix.o" "$OUT/cache.o" "$OUT/stubs.o" \
  -framework Metal -framework Foundation -framework QuartzCore -framework IOKit -framework CoreFoundation -framework CoreGraphics -framework ApplicationServices -framework AppKit -framework CoreVideo -framework CoreServices -framework MetalFX -o "$OUT/test" 2>&1 | head -30 || true
"$OUT/test" "$@"
