#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/raycast"
command -v npm >/dev/null || { echo 'Node.js 22 and npm are required.' >&2; exit 1; }
npm ci --no-audit --no-fund
npm run typecheck
INSTALLED="$HOME/.config/raycast/extensions/oil-find"
mkdir -p "$(dirname "$INSTALLED")"
WORK="$(mktemp -d "$(dirname "$INSTALLED")/.oil-find-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Build before replacing anything; an explicit output also avoids stale commands/maps.
./node_modules/.bin/ray build -e dev -o "$WORK/oil-find"
ARCHIVE="$ROOT/.local-archive/raycast/$(date +%Y%m%d-%H%M%S)-$$"
if [[ -e "$INSTALLED" ]]; then
    mkdir -p "$ARCHIVE"
    mv "$INSTALLED" "$ARCHIVE/oil-find"
    printf 'Previous extension archived: %s\n' "$ARCHIVE"
fi
if ! mv "$WORK/oil-find" "$INSTALLED"; then
    if [[ -d "$ARCHIVE/oil-find" ]]; then mv "$ARCHIVE/oil-find" "$INSTALLED"; fi
    exit 1
fi
printf '%s\n' 'Raycast extension installed. Run Search Files with Oil Find in Raycast.'
