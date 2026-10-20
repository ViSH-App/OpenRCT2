#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ASSETS="$ROOT/build/ios-data"
if [[ ! -f "$ASSETS/g2.dat" || ! -f "$ASSETS/fonts/NotoSansCJKsc-Regular.otf" ]]; then
    echo "Prepared iOS assets are missing; run src/openrct2-ios/scripts/prepare.sh." >&2
    exit 1
fi
/usr/bin/ditto "$ASSETS" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/data"
