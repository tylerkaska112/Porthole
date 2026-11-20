#!/bin/bash
# Builds Discord's DAVE library (libdave, MIT) with its two dependencies (mlspp BSD-2, OpenSSL 3 Apache-2) for arm64 iOS, into $DAVE_DIR/install-ios
# (default: next to the build root). app/DaveStage points at that folder. Discord branch only; takes about ten minutes.
#   tools/build_dave.sh
set -euo pipefail
DAVE_DIR="${DAVE_DIR:-${F4_BUILD_ROOT:-$PWD/build}/../dave-build}"
mkdir -p "$DAVE_DIR"; cd "$DAVE_DIR"; P="$PWD/install-ios"
OPENSSL=3.0.18; MLSPP=1cc50a124a3bc4e143a787ec934280dc70c1034d; JSON=v3.11.3
[ -d libdave ] || git clone --depth 1 https://github.com/discord/libdave.git
[ -d mlspp ] || { git clone https://github.com/cisco/mlspp.git; git -C mlspp checkout "$MLSPP"; }
[ -d nlohmann_json ] || git clone --depth 1 --branch "$JSON" https://github.com/nlohmann/json.git nlohmann_json
[ -d "openssl-$OPENSSL" ] || { curl -sSL -o openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz"; tar xzf openssl.tar.gz; }
cat > ios-toolchain.cmake <<'TC'
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TC
# OpenSSL
if [ ! -f "$P/lib/libcrypto.a" ]; then
  ( cd "openssl-$OPENSSL" && IPHONEOS_DEPLOYMENT_TARGET=17.0 ./Configure ios64-xcrun no-shared no-tests no-ui-console no-engine no-dso no-async --prefix="$P" >/dev/null && IPHONEOS_DEPLOYMENT_TARGET=17.0 make -j6 build_libs >/dev/null && make install_dev >/dev/null )
fi
# nlohmann json (headers)
cmake -S nlohmann_json -B build-json -DJSON_BuildTests=OFF -DCMAKE_INSTALL_PREFIX="$P" >/dev/null && cmake --install build-json >/dev/null
# mlspp: libdave does not use mls_ds / mls_vectors
sed -i '' -e '/add_subdirectory(mls_ds)/d' -e '/add_subdirectory(mls_vectors)/d' mlspp/lib/CMakeLists.txt
COMMON=(-G Ninja -DCMAKE_TOOLCHAIN_FILE="$PWD/ios-toolchain.cmake" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_PREFIX_PATH="$P" -DCMAKE_FIND_ROOT_PATH="$P" -DOPENSSL_ROOT_DIR="$P" -DOPENSSL_USE_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DTESTING=OFF)
cmake -S mlspp -B build-mlspp "${COMMON[@]}" -DDISABLE_GREASE=ON -DMLS_CXX_NAMESPACE=mlspp >/dev/null && cmake --build build-mlspp >/dev/null && cmake --install build-mlspp >/dev/null
cmake -S libdave/cpp -B build-dave "${COMMON[@]}" >/dev/null && cmake --build build-dave >/dev/null && cmake --install build-dave >/dev/null
echo "✓ DAVE built into $P"
# Opus (BSD-3): the sound codec of Discord voice
[ -d opus ] || git clone --depth 1 --branch v1.5.2 https://github.com/xiph/opus.git
cmake -S opus -B build-opus -G Ninja -DCMAKE_TOOLCHAIN_FILE="$PWD/ios-toolchain.cmake" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null && cmake --build build-opus >/dev/null && cmake --install build-opus >/dev/null
echo "✓ Opus built into $P"
