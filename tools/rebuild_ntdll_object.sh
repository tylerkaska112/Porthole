#!/bin/bash
# Recompile ONE object of libntdll_unix.a from vendor/Madeira/build/ntdll-unix and write a patched COPY of the library; the library in vendor/ is not touched.
# Same flags as compile_one in build/ntdll-unix/build.sh. Used by patches 0012, 0013 and 0018.
#   tools/rebuild_ntdll_object.sh virtual                 # virtual_ios.c -> member virtual.o
#   tools/rebuild_ntdll_object.sh virtual signal_arm64    # several objects go into the same copy (patch 0018 changes both)
# Output: $F4_BUILD_ROOT/ntdll-lib/libntdll_unix.a (override with OUT=...). Stage it with LIB_OVERRIDES=$F4_BUILD_ROOT/ntdll-lib tools/stage_runtime.sh
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
F4_BUILD_ROOT="${F4_BUILD_ROOT:-$HERE/build}"
[ $# -ge 1 ] || { echo "object names: virtual, signal_arm64, loader, process, thread, sync and/or others in the case below"; exit 1; }
M="$HERE/vendor/Madeira"; BUILD_DIR="$M/build/ntdll-unix"; WINE_SRC="$M/wine"; WINE_BUILD="$WINE_SRC/build-macos"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT="${OUT:-$F4_BUILD_ROOT/ntdll-lib}"; WORK="$OUT/obj"; mkdir -p "$WORK"
# BASE=<library>: start from that archive instead of the one in vendor/ (to stack rebuilt objects on an earlier copy, for example the OpenGL one).
cp "${BASE:-$M/app/Madeira/libntdll_unix.a}" "$OUT/libntdll_unix.a"
for NAME in "$@"; do
  OBJ=$NAME; EXTRA=(); UNDEF=()
  case "$NAME" in
    virtual) SRCFILE=virtual_ios.c ;;
    signal_arm64) SRCFILE=signal_arm64_ios.c ;;
    loader) SRCFILE=loader_ios.c ;;
    process) SRCFILE=process_ios.c ;;
    thread) SRCFILE=thread_ios.c ;;
    server) SRCFILE=server_ios.c ;;
    file) SRCFILE=../../wine/dlls/ntdll/unix/file.c ;;
    sync) SRCFILE=../../wine/dlls/ntdll/unix/sync.c ;;   # fastsync (patch 0140)
    env) SRCFILE=env_ios.c ;;
    audio_null) SRCFILE=audio_null_ios.c; OBJ=audio_null_ios ;;          # silent audio clock (patch 0163, PR 349)
    crypt32) SRCFILE=../crypto-unix/crypt32_unixlib_ios.c; OBJ=crypt32_unixlib      # root store (patch 0163, PR 356)
             EXTRA=(-D__wine_unix_call_funcs=crypt32_unix_call_funcs -D__wine_unix_call_wow64_funcs=crypt32_unix_call_wow64_funcs
                    -I"$WINE_SRC/dlls/crypt32" -I"$M/toolchains/gnutls-ios/include" -include "$M/build/crypto-unix/ios_gnutls_shim.h") ;;
    winegstreamer) SRCFILE=winegstreamer_unixlib_ios.c; OBJ=winegstreamer_unixlib   # libavcodec/libavformat WMA decoder and wg_parser (patch 0119, PR 241)
                   EXTRA=(-D__wine_unix_call_funcs=winegstreamer_unix_call_funcs -D__wine_unix_call_wow64_funcs=winegstreamer_unix_call_wow64_funcs
                          -I"$WINE_SRC/dlls/winegstreamer" -I"$M/toolchains/ffmpeg-ios/include")
                   UNDEF=(-UBINDIR -ULIBDIR -UDATADIR -USYSTEMDLLPATH) ;;   # objidl.h has an enum named DATADIR
    *) echo "unknown object $NAME"; exit 1 ;;
  esac
  xcrun -sdk iphoneos clang \
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
    -Wno-implicit-function-declaration -Wno-int-conversion \
    -include "$WINE_BUILD/include/config.h" -include "$BUILD_DIR/shims/wine_ios_exit.h" \
    "${EXTRA[@]+"${EXTRA[@]}"}" \
    -I"$BUILD_DIR/shims" -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1 \
    -I"$WINE_BUILD/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll/unix" -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
    -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
    -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
    -DWINE_UNIX_LIB -DWINE_IOS=1 -Dget_thread_context=ntdll_get_thread_context -Dset_thread_context=ntdll_set_thread_context \
    "${UNDEF[@]+"${UNDEF[@]}"}" -c "$BUILD_DIR/$SRCFILE" -o "$WORK/$OBJ.o" 2>"$WORK/$NAME.err" || { cat "$WORK/$NAME.err" | grep error; exit 1; }
  ( cd "$WORK" && xcrun -sdk iphoneos ar r "$OUT/libntdll_unix.a" "$OBJ.o" 2>&1 | grep -v "^ar: creating" || true )
done
xcrun -sdk iphoneos ranlib "$OUT/libntdll_unix.a"
echo "wrote $OUT/libntdll_unix.a ($(ar t "$OUT/libntdll_unix.a" | wc -l | tr -d ' ') members) with fresh: $*"
