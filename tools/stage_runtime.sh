#!/bin/bash
# Stage the BUILT runtime for the Xcode project from the pinned GitHub snapshot (vendor/Madeira/app/Madeira: tracked PE farms + the iOS-side libs we built).
# Output lives on the external drive; app/RuntimeStage is a symlink to it. Nothing here is committed.
# The arm64ec farm and x86_64-vcruntime are COPIED so we can add files (our gdiplus.dll; Microsoft's VC runtime DLLs, which the repo cannot ship) without touching vendor/.
# usage: tools/stage_runtime.sh [extra arm64ec DLLs...]     env: VCRUNTIME_DIR=<dir with the vc DLLs> (default on the build drive), OVERRIDES=<dir of our rebuilt arm64ec DLLs>
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# This machine's paths (F4_BUILD_ROOT) live in tools/local.env, which is not committed.
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
F4_BUILD_ROOT="${F4_BUILD_ROOT:-$HERE/build}"
APP="$HERE/vendor/Madeira/app/Madeira"
STAGE="${STAGE:-$F4_BUILD_ROOT/stage-head}"
rm -rf "$STAGE"; mkdir -p "$STAGE/lib" "$STAGE/Resources"
for f in "$APP"/lib*.a; do ln -s "$f" "$STAGE/lib/$(basename "$f")"; done
# LIB_OVERRIDES=<dir>: archives in it (for example libntdll_unix.a from tools/rebuild_ntdll_object.sh) are used instead of the snapshot's. Unset = the normal runtime.
if [ -n "${LIB_OVERRIDES:-}" ]; then
  for f in "$LIB_OVERRIDES"/lib*.a; do [ -f "$f" ] && ln -sf "$f" "$STAGE/lib/$(basename "$f")" && echo "library override: $(basename "$f")"; done
fi
for d in nls aarch64-windows legal d3d12 licenses; do ln -s "$APP/$d" "$STAGE/Resources/$d"; done
# The 32-bit farm is linked, unless we have our own builds of some of its DLLs (OVERRIDES_I386, e.g. the xinput DLLs of patch 0017): then it is copied and they go over it.
OVERRIDES_I386="${OVERRIDES_I386:-$F4_BUILD_ROOT/ec-out-i386}"
if ls "$OVERRIDES_I386"/*.dll >/dev/null 2>&1; then
  cp -R "$APP/i386-windows" "$STAGE/Resources/i386-windows"
  for dll in "$OVERRIDES_I386"/*.dll; do cp "$dll" "$STAGE/Resources/i386-windows/" && echo "override (i386): $(basename "$dll")"; done
else
  ln -s "$APP/i386-windows" "$STAGE/Resources/i386-windows"
fi
# OpenGL (patches/0082, docs/OPENGL.md): Mesa's OSMesa + Zink and MoltenVK (gl/), LuaJIT for LOVE games (compat/love/) and their licence texts. They come from GL_ASSETS (default
# $F4_BUILD_ROOT/gl-assets); without it the folders are empty and the OpenGL driver falls back to OpenGL ES. The licence folder is then a copy with those texts added.
GL_ASSETS="${GL_ASSETS:-$F4_BUILD_ROOT/gl-assets}"
mkdir -p "$STAGE/Resources/gl" "$STAGE/Resources/compat"
if [ -d "$GL_ASSETS/gl" ]; then
  cp -R "$GL_ASSETS/gl/." "$STAGE/Resources/gl/"; [ -d "$GL_ASSETS/compat" ] && cp -R "$GL_ASSETS/compat/." "$STAGE/Resources/compat/"
  rm -f "$STAGE/Resources/licenses"; cp -R "$APP/licenses" "$STAGE/Resources/licenses"; cp "$GL_ASSETS"/licenses/* "$STAGE/Resources/licenses/" 2>/dev/null || true
  echo "OpenGL assets: $(ls "$STAGE/Resources/gl" | tr '\n' ' ')"
fi
# Vulkan (opt-in per game: engine lines vulkan, d3d11 = dxvk, d3d12 = vkd3d): Wine's winevulkan and vulkan-1, vkd3d-proton and DXVK, built by build/vkd3d-proton/build.sh and build/dxvk/build.sh
# into vendor/Madeira/app/Madeira/vulkan. They are linked into a prefix only for a session that asks for them, so a game that does not ask sees no vulkan-1.dll.
[ -d "$APP/vulkan/arm64ec-windows" ] && ln -s "$APP/vulkan" "$STAGE/Resources/vulkan"
for f in prefix-template.tar.gz cacert.pem madeira-jit.js; do ln -s "$APP/$f" "$STAGE/Resources/$f"; done
cp -R "$APP/arm64ec-windows" "$STAGE/Resources/arm64ec-windows"
for dll in "$@"; do cp "$dll" "$STAGE/Resources/arm64ec-windows/"; echo "added $(basename "$dll") to arm64ec-windows"; done
mkdir -p "$STAGE/Resources/x86_64-vcruntime"
VCRUNTIME_DIR="${VCRUNTIME_DIR:-$F4_BUILD_ROOT/vcruntime}"
if [ -d "$VCRUNTIME_DIR" ]; then cp "$VCRUNTIME_DIR"/*.dll "$STAGE/Resources/x86_64-vcruntime/"; fi
# Our own rebuilt DLLs (patches/0005 d3d11.dll etc.) go over the repo's: every *.dll in OVERRIDES is copied into the ARM64EC farm.
OVERRIDES="${OVERRIDES:-$F4_BUILD_ROOT/ec-out}"
# 0099/0101: programs too (regsvr32.exe, which the Dock batch needs to register wintrust.dll)
for dll in "$OVERRIDES"/*.dll "$OVERRIDES"/*.exe; do case "$dll" in *.orig.dll) continue;; esac; [ -f "$dll" ] && cp "$dll" "$STAGE/Resources/arm64ec-windows/" && echo "override: $(basename "$dll")"; done
# Our own gdiplus.dll (patches/0001): the Madeira snapshot ships none and Factorio will not start without it. Always included, so a re-stage can never drop it.
[ -f "$STAGE/Resources/arm64ec-windows/gdiplus.dll" ] || { cp "$HERE/patches/0001-gdiplus.dll" "$STAGE/Resources/arm64ec-windows/gdiplus.dll" && echo "added gdiplus.dll (patches/0001)"; }
ln -sfn "$STAGE" "$HERE/app/RuntimeStage"
echo "staged at $STAGE: $(ls "$STAGE/lib" | wc -l) libs, $(ls "$STAGE/Resources/arm64ec-windows" | wc -l) arm64ec DLLs, $(ls "$STAGE/Resources/x86_64-vcruntime" | wc -l) vcruntime DLLs"
