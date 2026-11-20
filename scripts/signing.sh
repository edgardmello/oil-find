#!/bin/bash
# Shared identity selection for local builds and production preflight.
resolve_signing_identity() {
    SIGN_IDENTITY="${OILFIND_LOCAL_SIGN_IDENTITY:-${OILFIND_SIGN_IDENTITY:-}}"
    if [[ -z "$SIGN_IDENTITY" && -f "$PROJECT_DIR/.env.oilfind-sign-identity" ]]; then
        SIGN_IDENTITY="$(cat "$PROJECT_DIR/.env.oilfind-sign-identity")"
    fi
    if [[ -z "$SIGN_IDENTITY" ]]; then
        # Reuse the installed certificate before considering another identity.
        local installed="/Applications/Oil Find.app" work
        if [[ -d "$installed" ]]; then
            work="$(mktemp -d)"
            if codesign -d --extract-certificates "$work/cert" "$installed" 2>/dev/null && [[ -f "$work/cert0" ]]; then
                SIGN_IDENTITY="$(shasum "$work/cert0" | cut -d ' ' -f 1 | tr '[:lower:]' '[:upper:]')"
            fi
            rm -rf "$work"
        fi
        if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -v -p codesigning | grep -q '"Oil Find Self-Signed"'; then
            SIGN_IDENTITY="Oil Find Self-Signed"
        fi
    fi
    if [[ -n "$SIGN_IDENTITY" ]]; then
        if ! security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" >/dev/null; then
            printf 'Signing identity unavailable: %s. Restore it instead of changing certificates.\n' "$SIGN_IDENTITY" >&2
            return 1
        fi
    elif [[ "${OILFIND_REQUIRE_STABLE_SIGNING:-0}" == 1 ]]; then
        printf '%s\n' 'Production installation requires a stable signing identity. Run scripts/create-signing-cert.sh once.' >&2
        return 1
    fi
}
