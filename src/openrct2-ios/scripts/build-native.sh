#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
CONFIGURATION=${CONFIGURATION:-Release}
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "Unsupported native configuration: $CONFIGURATION" >&2; exit 1 ;;
esac
if [[ ${PLATFORM_NAME:-iphoneos} != iphoneos || ${EFFECTIVE_PLATFORM_NAME:-} == *simulator* ]]; then
    echo "OpenRCT2 requires an iPad or My Mac (Designed for iPad) destination." >&2
    exit 1
fi
# First build prepares the pinned dependencies/assets in their existing locations.
if [[ ! -f "$ROOT/build/ios-deps/install/lib/libSDL2.a" ||
      ! -f "$ROOT/build/ios-deps/install/lib/libicudata.a" ||
      ! -f "$ROOT/build/ios-deps/install/lib/pkgconfig/freetype2.pc" ||
      ! -f "$ROOT/build/ios-data/g2.dat" ||
      ! -f "$ROOT/build/ios-data/fonts/WenQuanYi.Bitmap.Song.12px.ttf" ]]; then
    "$ROOT/src/openrct2-ios/scripts/prepare.sh"
fi
# Older preparations built SDL with OpenGL ES, which the app no longer links; rebuild only SDL.
# (grep -q would end the pipe early and fail it under pipefail, so read all of nm's output.)
if [[ -n "$(nm -u "$ROOT/build/ios-deps/install/lib/libSDL2.a" 2>/dev/null | grep EAGLContext || true)" ]]; then
    "$ROOT/src/openrct2-ios/scripts/build-dependencies.sh" --sdl-only
fi
# Replace only the old generator's configuration when migrating build/ipad.
# Dependency downloads, installed libraries, assets, and their paths are preserved.
CMAKE_ARGS=(
    -S "$ROOT" -B "$ROOT/build/ipad" -G "Ninja Multi-Config"
    -DCMAKE_CONFIGURATION_TYPES="Debug;Release"
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
)
if [[ -f "$ROOT/build/ipad/CMakeCache.txt" ]] &&
   ! grep -qx 'CMAKE_GENERATOR:INTERNAL=Ninja Multi-Config' "$ROOT/build/ipad/CMakeCache.txt"; then
    CMAKE_ARGS+=(--fresh)
fi
cmake "${CMAKE_ARGS[@]}"
cmake --build "$ROOT/build/ipad" --config "$CONFIGURATION" --target openrct2 -j "${JOBS:-8}"
