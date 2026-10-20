#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
DEPS="$ROOT/build/ios-deps"
PREFIX="$DEPS/install"
JOBS=${JOBS:-8}
# --sdl-only / --lzma-only rebuild just that library in an existing preparation (see build-native.sh).
SDL_ONLY=0
LZMA_ONLY=0
[[ "${1:-}" == "--sdl-only" ]] && SDL_ONLY=1
[[ "${1:-}" == "--lzma-only" ]] && LZMA_ONLY=1
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$PREFIX/include" "$DEPS/logs"
python3 "$ROOT/src/openrct2-ios/scripts/fetch-dependencies.py"
# These are architecture-independent C++ headers from the checksum-pinned host dependency pack.
if [[ $SDL_ONLY == 0 ]]; then
    for header in nlohmann fmt rapidjson; do
        cp -R "$ROOT/lib/macos/include/$header" "$PREFIX/include/"
    done
fi
COMMON=(-G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DBUILD_SHARED_LIBS=OFF)
build() {
 local name=$1; local source=$2; shift 2
 printf 'Building iPhoneOS dependency: %s (log: %s)\n' "$name" "$DEPS/logs/$name.log"
 cmake -S "$source" -B "$DEPS/$name" "${COMMON[@]}" "$@" > "$DEPS/logs/$name.log" 2>&1
 cmake --build "$DEPS/$name" -j "$JOBS" >> "$DEPS/logs/$name.log" 2>&1
 cmake --install "$DEPS/$name" >> "$DEPS/logs/$name.log" 2>&1
}
# The LZMA SDK has no build system for these two decoders; compile them into liblzmasdk.a.
build_lzma_sdk() {
 local source="$DEPS/sources/7zip/C" objects="$DEPS/lzma-sdk"
 printf 'Building iPhoneOS dependency: LZMA SDK (log: %s)\n' "$DEPS/logs/lzma-sdk.log"
 mkdir -p "$objects" "$PREFIX/include/lzma-sdk" "$PREFIX/lib"
 for file in LzmaDec Lzma2Dec; do
  xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -O2 -c "$source/$file.c" -o "$objects/$file.o" >> "$DEPS/logs/lzma-sdk.log" 2>&1
 done
 rm -f "$PREFIX/lib/liblzmasdk.a"
 xcrun libtool -static -o "$PREFIX/lib/liblzmasdk.a" "$objects/LzmaDec.o" "$objects/Lzma2Dec.o" >> "$DEPS/logs/lzma-sdk.log" 2>&1
 cp "$source"/{7zTypes.h,7zWindows.h,Compiler.h,Precomp.h,LzmaDec.h,Lzma2Dec.h} "$PREFIX/include/lzma-sdk/"
}
if [[ $LZMA_ONLY == 1 ]]; then
    build_lzma_sdk
    exit 0
fi
# Metal only: no OpenGL ES video backend or renderers, so the app does not link OpenGLES.
build SDL "$DEPS/sources/SDL" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_METAL=ON -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF
if [[ $SDL_ONLY == 1 ]]; then
    exit 0
fi
build zstd "$DEPS/sources/zstd/build/cmake" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_TESTS=OFF
build libpng "$DEPS/sources/libpng" -DPNG_SHARED=OFF -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
build libzip "$DEPS/sources/libzip" -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF
build_lzma_sdk
build freetype "$DEPS/sources/freetype" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
# ICU needs native data-generation tools before cross compilation.
mkdir -p "$DEPS/icu-host" "$DEPS/icu-ios"
if [[ ! -f "$DEPS/icu-host/config.status" ]]; then
 (cd "$DEPS/icu-host"; "$DEPS/sources/icu/source/configure" --disable-shared --enable-static --disable-tests --disable-samples > "$DEPS/logs/icu-host.log" 2>&1)
fi
printf 'Building ICU host tools (log: %s)\n' "$DEPS/logs/icu-host.log"
make -C "$DEPS/icu-host" -j "$JOBS" >> "$DEPS/logs/icu-host.log" 2>&1
if [[ ! -f "$DEPS/icu-ios/config.status" ]]; then
 (cd "$DEPS/icu-ios"; CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0" CXXFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0" LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0" "$DEPS/sources/icu/source/configure" --host=aarch64-apple-darwin --with-cross-build="$DEPS/icu-host" --prefix="$PREFIX" --disable-shared --enable-static --disable-tests --disable-samples --disable-tools --disable-extras > "$DEPS/logs/icu-ios.log" 2>&1)
fi
printf 'Building ICU for iPhoneOS (log: %s)\n' "$DEPS/logs/icu-ios.log"
make -C "$DEPS/icu-ios" -j "$JOBS" >> "$DEPS/logs/icu-ios.log" 2>&1
make -C "$DEPS/icu-ios" install >> "$DEPS/logs/icu-ios.log" 2>&1
printf 'iPhoneOS dependencies ready: %s\n' "$PREFIX"
