#!/bin/bash
# Builds winemetal natively for macOS (DXMT_NATIVE: its unix side and its C wrappers, with the Porthole patches) into one static library, for linking the Cycles Metal device written
# against winemetal (blender-porthole) into a macOS build of Cycles. Needs the private copy made by tools/build_winemetal_unix.sh.
# usage: build_native_lib.sh <output dir>   -> <output dir>/libwinemetal_native.a and the include dir to give CMake (the winemetal folder of the private copy)
set -eu
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
ROOT="${F4_BUILD_ROOT:-$HERE/build}"
ENGINE="$(cd "$HERE/vendor/Madeira" && pwd -P)"
TREE="$ROOT/winemetal-work/tree/dxmt/src/winemetal"
OUT="${1:?output dir}"; mkdir -p "$OUT/obj"
[ -d "$TREE" ] || { echo "run tools/build_winemetal_unix.sh first"; exit 1; }
SDK=$(xcrun --sdk macosx --show-sdk-path)
INC="-I$ENGINE/dxmt/src/nativemetal -I$ENGINE/dxmt/include -I$ENGINE/dxmt/libs -I$TREE -I$ENGINE/dxmt/src/airconv"
sed 's/os_proc_available_memory()/((size_t)(8ull<<30))/g' "$TREE/unix/winemetal_unix.c" > "$TREE/unix/winemetal_unix_mac.c"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -fblocks -O1 -w -x objective-c -DDXMT_NATIVE=1 $INC -c "$TREE/unix/winemetal_unix_mac.c" -o "$OUT/obj/unix.o"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -fblocks -O1 -w -x objective-c -DDXMT_NATIVE=1 $INC -c "$TREE/unix/cache.c" -o "$OUT/obj/cache.o"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -std=gnu2x -O1 -w -DDXMT_NATIVE=1 $INC -c "$TREE/winemetal_thunks.c" -o "$OUT/obj/thunks.o"
# the shader compilers (airconv) the layer links but a compute-only program never calls, and the app-side hooks of the iOS build
for f in DXSOCompile DXSODestroy DXSODestroyBitcode DXSOGetCompiledBitcode DXSOInitialize SM50Compile SM50CompileGeometryPipelineGeometry SM50CompileGeometryPipelineVertex \
         SM50CompileTessellationPipelineDomain SM50CompileTessellationPipelineHull SM50Destroy SM50DestroyBitcode SM50FreeError SM50GetArgumentsInfo SM50GetCompiledBitcode SM50GetErrorMessage \
         SM50Initialize ios_exc_msg_count ios_fps_cap_dxmt_pace ios_frame_drawable_wait ios_frame_encode_present ios_frame_game_tick ios_frame_gpu ios_frame_limiter ios_frame_pass \
         ios_frame_stats_on ios_srv_req_count ios_srv_wait_count ios_srv_wait_req_us ios_srv_wait_timeouts ios_srv_wait_us ios_xp_pe_block ios_xp_pe_len ios_xp_set_role madeira_frame_mark ios_frame_note_display \
         madeira_ir_convert madeira_swap_overlay_stats sqlite3_bind_blob64 sqlite3_clear_bindings sqlite3_close sqlite3_column_blob sqlite3_column_bytes sqlite3_errmsg sqlite3_exec \
         sqlite3_finalize sqlite3_free sqlite3_open_v2 sqlite3_prepare_v2 sqlite3_reset sqlite3_step wmt_api_census_note; do echo "int $f(void) { return 0; }"; done > "$OUT/obj/stubs.c"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=15.0 -c "$OUT/obj/stubs.c" -o "$OUT/obj/stubs.o"
rm -f "$OUT/libwinemetal_native.a"; xcrun ar rcs "$OUT/libwinemetal_native.a" "$OUT/obj"/*.o
echo "built $OUT/libwinemetal_native.a ; include dir: $TREE"
