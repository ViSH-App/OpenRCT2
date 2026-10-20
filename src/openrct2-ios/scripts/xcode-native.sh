#!/bin/bash
# Build tool of the Xcode target "Native": the dependencies, assets and engine libraries for
# one SDK. Usage: xcode-native.sh <platform> <configuration> <deployment target> [action], from
# the project's build settings; Xcode passes an empty action for a build and "clean" for Clean.
set -euo pipefail
PLATFORM=${1:?platform}
CONFIGURATION=${2:?configuration}
DEPLOYMENT_TARGET=${3:?deployment target}
ACTION=${4:-build}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT="$ROOT/build/ios"
# Homebrew supplies cmake, ninja, pkg-config and Python, locally and on Xcode Cloud.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# Host tools (the graphics generator) build for macOS: under Xcode a bare cc
# finds no SDK at all. The iOS builds name their own sysroot.
unset IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
case "$PLATFORM" in
    iphoneos|iphonesimulator) ;;
    *) echo "Unsupported platform: $PLATFORM" >&2; exit 1 ;;
esac
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "Unsupported configuration: $CONFIGURATION" >&2; exit 1 ;;
esac
# The pinned dependencies are a cache, not build products; Clean only drops the engine libraries.
if [[ $ACTION == clean ]]; then
    rm -rf "$OUT/$PLATFORM/engine/$CONFIGURATION"
    exit 0
fi

cmake -S "$ROOT/src/openrct2-ios/cmake/native" -B "$OUT/$PLATFORM/native" -G Ninja \
    -DIOS_PLATFORM="$PLATFORM" -DIOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DIOS_PREFIX="$OUT/$PLATFORM/install" -DIOS_SOURCES="$OUT/$PLATFORM/sources" \
    -DIOS_DOWNLOADS="$OUT/downloads" -DIOS_HOST_DIR="$OUT/host" -DIOS_DATA_DIR="$OUT/data"
cmake --build "$OUT/$PLATFORM/native"

cmake -S "$ROOT" -B "$OUT/$PLATFORM/engine" -G "Ninja Multi-Config" -DCMAKE_CONFIGURATION_TYPES="Debug;Release" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$PLATFORM" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DIOS_DEPENDENCIES="$OUT/$PLATFORM/install"
cmake --build "$OUT/$PLATFORM/engine" --config "$CONFIGURATION" --target openrct2
