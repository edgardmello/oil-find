#!/bin/bash
# Remove only generated files owned by this checkout. Keep signing and app data.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---quick}"
case "$MODE" in --quick|--full|--dry-run) ;; *) echo 'Usage: scripts/clean.sh [--quick|--full|--dry-run]' >&2; exit 2 ;; esac
for relative in build raycast/dist raycast/raycast-env.d.ts site/.next site/tsconfig.tsbuildinfo; do
    [[ -e "$ROOT/$relative" ]] || continue
    printf 'Generated: %s\n' "$relative"
    [[ "$MODE" == --dry-run ]] || rm -rf "$ROOT/$relative"
done
if [[ "$MODE" == --full ]]; then
    rm -rf "$ROOT/.build"
    printf '%s\n' 'Removed Swift build cache.'
fi
