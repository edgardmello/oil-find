#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Personal packages use the same stable identity as production installation.
export OILFIND_REQUIRE_STABLE_SIGNING=1
"$PROJECT_DIR/scripts/build-app.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCHIVE_PATH="$PROJECT_DIR/build/Oil-Find-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "build/Oil Find.app" "$ARCHIVE_PATH"
python3 Tests/Scripts/test_packaged_launch.py "$ARCHIVE_PATH"
mkdir -p site/public/downloads site/public/updates
node --experimental-strip-types scripts/generate-update-manifest.mjs Resources/Info.plist "$ARCHIVE_PATH" site/public/updates/latest.json
cp "$ARCHIVE_PATH" "site/public/downloads/Oil-Find-$VERSION.zip"
cp "$ARCHIVE_PATH" site/public/downloads/Oil-Find.zip

printf 'File: %s\n' "$ARCHIVE_PATH"
printf 'Size: %s bytes\n' "$(stat -f '%z' "$ARCHIVE_PATH")"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$ARCHIVE_PATH" | cut -d ' ' -f 1)"
