#!/bin/bash
# Rebuilds winemetal's unix side with patches/0183 (and any later winemetal patch) in a private copy, and puts the object into a COPY of libdxmt_combined.a.
# The shared engine clone (vendor/Madeira/dxmt) is never touched. Output: $F4_BUILD_ROOT/dxmt-lib-130/libdxmt_combined.a (use it with LIB_OVERRIDES, or link it into the stage's lib/).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
ROOT="${F4_BUILD_ROOT:-$HERE/build}"
ENGINE="$(cd "$HERE/vendor/Madeira" && pwd -P)"
W="$ROOT/winemetal-work"; OUT="$ROOT/dxmt-lib-130"
rm -rf "$W"; mkdir -p "$W/tree/dxmt/src" "$W/obj" "$OUT"
cp -R "$ENGINE/dxmt/src/winemetal" "$W/tree/dxmt/src/winemetal"
ln -sfn "$ENGINE/build" "$W/tree/build"; ln -sfn "$ENGINE/research" "$W/tree/research"
( cd "$W/tree/dxmt" && for p in "$HERE"/patches/018[34567]-winemetal-*.patch; do patch -p1 -s < "$p"; done )
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -fblocks -O2 -x objective-c \
  -I"$ENGINE/dxmt/include" -I"$ENGINE/dxmt/libs" -I"$W/tree/dxmt/src/winemetal" -I"$ENGINE/dxmt/src/airconv" \
  -c "$W/tree/dxmt/src/winemetal/unix/winemetal_unix.c" -o "$W/obj/winemetal_unix.o"
cp "$ENGINE/app/Madeira/libdxmt_combined.a" "$OUT/libdxmt_combined.a"
xcrun ar r "$OUT/libdxmt_combined.a" "$W/obj/winemetal_unix.o"
xcrun ranlib "$OUT/libdxmt_combined.a"
echo "built $OUT/libdxmt_combined.a"
