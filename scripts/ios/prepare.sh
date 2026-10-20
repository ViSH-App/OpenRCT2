#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
JOBS=${JOBS:-8}
cmake -S . -B build/ipad-host -G Ninja -DCMAKE_BUILD_TYPE=Release -DDISABLE_GUI=ON -DMACOS_BUNDLE=OFF -DENABLE_SCRIPTING=OFF -DDISABLE_HTTP=ON -DDISABLE_NETWORK=ON -DDISABLE_DISCORD_RPC=ON -DDISABLE_IPO=ON
cmake --build build/ipad-host --target graphics -j "$JOBS"
scripts/ios/build-dependencies.sh
python3 scripts/ios/prepare-assets.py
cmake -S . -B build/ipad -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 "-DIOS_DEVELOPMENT_TEAM=${IOS_DEVELOPMENT_TEAM:-}" "-DIOS_BUNDLE_IDENTIFIER=${IOS_BUNDLE_IDENTIFIER:-io.openrct2.personal.ipad}"
