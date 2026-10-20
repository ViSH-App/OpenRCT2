#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# Xcode exports the iPhoneOS SDK; the graphics generator must be a host executable.
unset SDKROOT
JOBS=${JOBS:-8}
cmake -S . -B build/ipad-host -G Ninja -DCMAKE_BUILD_TYPE=Release -DDISABLE_GUI=ON -DMACOS_BUNDLE=OFF -DENABLE_SCRIPTING=OFF -DDISABLE_HTTP=ON -DDISABLE_NETWORK=ON -DDISABLE_DISCORD_RPC=ON -DDISABLE_IPO=ON
cmake --build build/ipad-host --target graphics -j "$JOBS"
src/openrct2-ios/scripts/build-dependencies.sh
python3 src/openrct2-ios/scripts/prepare-assets.py
printf 'iOS dependencies and assets ready. Open src/openrct2-ios/OpenRCT2.xcodeproj.\n'
