#!/bin/bash
# Builds libdatachannel (MPL-2.0: WebRTC peer connection, media tracks, SRTP) with its parts (libjuice MPL-2.0, libsrtp BSD, usrsctp BSD, plog MIT)
# for arm64 iOS into the same prefix as build_dave.sh ($DAVE_DIR/install-ios), reusing its OpenSSL. Discord branch only. Run tools/build_dave.sh first.
#   tools/build_datachannel.sh
set -euo pipefail
DAVE_DIR="${DAVE_DIR:-${F4_BUILD_ROOT:-$PWD/build}/../dave-build}"
cd "$DAVE_DIR"; P="$PWD/install-ios"
TAG=v0.24.6
[ -f "$P/lib/libcrypto.a" ] || { echo "run tools/build_dave.sh first (OpenSSL)"; exit 1; }
[ -d libdatachannel ] || git clone --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules https://github.com/paullouisageneau/libdatachannel.git
cmake -S libdatachannel -B build-datachannel -G Ninja -DCMAKE_TOOLCHAIN_FILE="$PWD/ios-toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_PREFIX_PATH="$P" -DCMAKE_FIND_ROOT_PATH="$P" -DOPENSSL_ROOT_DIR="$P" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DBUILD_SHARED_LIBS=OFF -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build-datachannel
cmake --install build-datachannel
echo "✓ libdatachannel $TAG built into $P"
