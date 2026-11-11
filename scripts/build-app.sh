#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=release
APP_PATH="$PROJECT_DIR/build/Oil Find.app"
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --debug) [[ $# -eq 1 ]] || exit 2; CONFIGURATION=debug; APP_PATH="$PROJECT_DIR/build/debug/Oil Find.app" ;;
    *) printf '%s\n' 'Usage: scripts/build-app.sh [--debug]' >&2; exit 2 ;;
esac
source "$PROJECT_DIR/scripts/signing.sh"
resolve_signing_identity
swift build -c "$CONFIGURATION"
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
# Always assemble a fresh generated bundle, even for incremental builds.
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/OilFind" "$APP_PATH/Contents/MacOS/OilFind"
if [[ "$CONFIGURATION" == release ]]; then
    # Release bundles omit debug symbols containing local source paths.
    strip -S "$APP_PATH/Contents/MacOS/OilFind"
fi
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
# Copy only resource bundles declared by the active package, including optional targets.
swift package describe --type json | python3 -c '
import json, pathlib, shutil, sys
package = json.load(sys.stdin)
binary, resources = map(pathlib.Path, sys.argv[1:])
for old in resources.glob(package["name"] + "_*.bundle"):
    shutil.rmtree(old)
for target in package["targets"]:
    if target.get("resources"):
        name = package["name"] + "_" + target["c99name"] + ".bundle"
        shutil.copytree(binary / name, resources / name)
' "$BINARY_DIR" "$APP_PATH/Contents/Resources"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [[ -n "$SIGN_IDENTITY" ]]; then
    if [[ -n "${OILFIND_SIGN_IDENTITY:-}" && -z "${OILFIND_LOCAL_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp "$APP_PATH"
    else
        codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP_PATH"
    fi
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_PATH"
fi
codesign --verify --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
