#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="/Applications/Oil Find.app"
export OILFIND_REQUIRE_STABLE_SIGNING=1
"$PROJECT_DIR/scripts/build-app.sh"

# Stage on the destination volume. Never overlay an existing bundle.
WORK="$(mktemp -d /Applications/.oilfind-install.XXXXXX)"
REPLACED=0
cleanup() {
    local status=$?
    if [[ "$REPLACED" == 1 && "$status" != 0 ]]; then
        swift "$PROJECT_DIR/scripts/quit-app.swift" || { printf 'Could not stop the new app; backup retained at %s\n' "$WORK" >&2; exit "$status"; }
        rm -rf "$DESTINATION"
        if [[ -d "$WORK/previous.app" ]]; then
            mv "$WORK/previous.app" "$DESTINATION" || { printf 'Backup retained at %s\n' "$WORK" >&2; exit "$status"; }
            open "$DESTINATION" || true
        fi
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$PROJECT_DIR/build/Oil Find.app" "$WORK/new.app"
codesign --verify --strict "$WORK/new.app"
if [[ -d "$DESTINATION" ]]; then
    REQUIREMENT="$(codesign -d -r- "$DESTINATION" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -z "$REQUIREMENT" ]] || ! codesign --verify --strict --test-requirement "=$REQUIREMENT" "$WORK/new.app"; then
        printf '%s\n' 'The new signature does not match the installed identity. Installation cancelled to preserve permissions.' >&2
        exit 1
    fi
fi
swift "$PROJECT_DIR/scripts/quit-app.swift"
if [[ -d "$DESTINATION" ]]; then mv "$DESTINATION" "$WORK/previous.app"; fi
REPLACED=1
mv "$WORK/new.app" "$DESTINATION"
codesign --verify --strict "$DESTINATION"
open "$DESTINATION"
swift "$PROJECT_DIR/scripts/quit-app.swift" --verify-launch
printf 'Installed and opened: %s\n' "$DESTINATION"
