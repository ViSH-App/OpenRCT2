#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ASSETS="$ROOT/build/ios-data"
if [[ ! -f "$ASSETS/g2.dat" || ! -f "$ASSETS/fonts/fusion-pixel-10px-proportional-zh_hans.otf" ]]; then
    echo "Prepared iOS assets are missing; run src/openrct2-ios/scripts/prepare.sh." >&2
    exit 1
fi
# ditto merges; drop previously bundled fonts so replaced ones do not linger in the app.
rm -rf "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/data/fonts"
/usr/bin/ditto "$ASSETS" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/data"
# The prepared copies of repository data go stale when the repository changes (new strings,
# for example); bundle the current ones.
for folder in language scenario_patches shaders; do
    /usr/bin/ditto "$ROOT/data/$folder" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/data/$folder"
done
