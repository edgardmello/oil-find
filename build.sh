#!/bin/bash
#
# build.sh — Interactive build for Oil Find
#
# Usage:
#   ./build.sh                    # interactive menu
#   ./build.sh install            # PRODUCTION: build release, quit the running
#                                 # app, overwrite /Applications/Oil Find.app,
#                                 # and relaunch it
#   ./build.sh dev                # debug build + open the debug app
#   ./build.sh build              # release build only (bundle in build/)
#   ./build.sh test               # swift test
#   ./build.sh package            # release + zip + update manifest (site)
#   ./build.sh --patch [command]  # bump version before the command
#   ./build.sh --minor [command]
#   ./build.sh --major [command]
#   ./build.sh --version 1.8.0 [command]
#   ./build.sh --no-clean         # skip the cleanup step
#   ./build.sh --yes              # accept defaults for the remaining prompts
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PLIST="Resources/Info.plist"
DEBUG_APP="build/debug/Oil Find.app"
RELEASE_APP="build/Oil Find.app"
INSTALL_APP="/Applications/Oil Find.app"
SELF_SIGNED="Oil Find Self-Signed"

# ----------------------------------------------------------------- colors ---
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; RESET=""
fi

info()  { printf '%s[info]%s %s\n'  "$BLUE"   "$RESET" "$*"; }
ok()    { printf '%s[ok]%s %s\n'    "$GREEN"  "$RESET" "$*"; }
warn()  { printf '%s[aviso]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()   { printf '%s[erro]%s %s\n'  "$RED"    "$RESET" "$*" >&2; }
step()  { printf '\n%s== %s ==%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
hr()    { printf '%s%s%s\n' "$DIM" "------------------------------------------------------------" "$RESET"; }

# Interactive only when stdin is a terminal and CI is not set. Everything
# falls back to defaults otherwise, so scripts and CI keep working.
ARG_YES=0
INTERACTIVE=1
if [ ! -t 0 ] || [ -n "${CI:-}" ]; then
  INTERACTIVE=0
fi

# confirm PROMPT [default:s|n] -> 0 for yes, 1 for no
confirm() {
  local prompt="$1" def="${2:-s}" ans="" hint
  if [ "$INTERACTIVE" = 0 ] || [ "$ARG_YES" = 1 ]; then
    [ "$def" = "s" ] && return 0 || return 1
  fi
  [ "$def" = "s" ] && hint="S/n" || hint="s/N"
  while :; do
    printf '%s %s%s[%s]%s ' "$prompt" "$BOLD" "$CYAN" "$hint" "$RESET"
    read -r ans || exit 130
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    [ -z "$ans" ] && ans="$def"
    case "$ans" in s|sim|y|yes) return 0 ;; n|nao|no) return 1 ;; esac
  done
}

# ask_option TITLE "option 1" "option 2" ... -> echoes the picked number
# (menu on stderr so it works inside $() )
ask_option() {
  local title="$1"; shift
  local i=1 opt def="${ARG_DEFAULT_OPTION:-1}"
  {
    printf '\n%s%s%s\n' "$BOLD" "$title" "$RESET"
    for opt in "$@"; do
      printf '  %s%s)%s %s\n' "$CYAN" "$i" "$RESET" "$opt"
      i=$((i + 1))
    done
  } >&2
  if [ "$INTERACTIVE" = 0 ] || [ "$ARG_YES" = 1 ]; then
    echo "$def"; return
  fi
  while :; do
    printf '%sEscolha%s [1-%d, default %s]: ' "$BOLD" "$RESET" "$#" "$def" >&2
    read -r reply || exit 130
    [ -z "$reply" ] && reply="$def"
    case "$reply" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$reply" -ge 1 ] && [ "$reply" -le "$#" ] && { echo "$reply"; return; }
  done
}

du_of() { [ -e "$1" ] && du -sh "$1" 2>/dev/null | cut -f1 || echo "—"; }

# ----------------------------------------------------------------- version --
get_version()   { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST"; }
get_buildnum()  { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"; }

semver_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

bump_version() {
  local v="$1" part="$2" major minor rest patch
  major="${v%%.*}"; rest="${v#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
  case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  echo "$major.$minor.$patch"
}

# Writes the new marketing version and increments the build number. The build
# number must always move forward: the app updater compares it release to release.
set_version() {
  local newver="$1" newbuild
  newbuild=$(( $(get_buildnum) + 1 ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $newver" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $newbuild" "$PLIST"
  ok "versão $newver (build $newbuild) gravada em $PLIST"
}

# --------------------------------------------------------------- pre-checks -
# Ejects orphaned DMG mount volumes left behind by failed builds. A stuck
# 'dmg.XXXXXX' volume makes the next build die with 'Resource busy'.
eject_orphan_dmg_mounts() {
  local ORPHANS=0 vol dev
  for vol in /Volumes/dmg.*; do
    [ -d "$vol" ] || continue
    dev=$(diskutil info "$vol" 2>/dev/null | perl -ne 'print "$1\n" if /^\s*Device Node:\s+(\S+)/')
    if [ -n "$dev" ]; then
      hdiutil detach -force "$dev" >/dev/null 2>&1 || true
      ORPHANS=$((ORPHANS + 1))
    fi
  done
  if [ "$ORPHANS" -gt 0 ]; then
    ok "ejetei $ORPHANS montagem(ns) órfã(s) de DMG — evita 'Resource busy'"
  fi
}

has_self_signed_identity() {
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$SELF_SIGNED\""
}

# The self-signed identity gives the app a stable code signature, so macOS
# keeps Full Disk Access across reinstalls (see scripts/create-signing-cert.sh).
check_signing() {
  if has_self_signed_identity; then
    ok "identidade \"$SELF_SIGNED\" presente — permissões (FDA) sobrevivem ao reinstall"
    return 0
  fi
  warn "sem identidade \"$SELF_SIGNED\" — o app será assinado ad-hoc e o macOS pedirá Full Disk Access de novo"
  if [ "$INTERACTIVE" = 1 ] && [ "$ARG_YES" = 0 ] && confirm "Criar o certificado local agora? (scripts/create-signing-cert.sh)" s; then
    ./scripts/create-signing-cert.sh
    if has_self_signed_identity; then
      ok "certificado criado"
    else
      warn "certificado não disponível — seguindo com assinatura ad-hoc"
    fi
  fi
}

# ------------------------------------------------------------------ flags ---
COMMAND=""
ARG_VERSION=""
ARG_BUMP=""
ARG_NO_CLEAN=0
ARG_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    dev|build|test|package|install) COMMAND="$1" ;;
    --patch) ARG_BUMP="patch" ;;
    --minor) ARG_BUMP="minor" ;;
    --major) ARG_BUMP="major" ;;
    --version) shift; ARG_VERSION="${1:-}" ;;
    --version=*) ARG_VERSION="${1#*=}" ;;
    --no-clean) ARG_NO_CLEAN=1 ;;
    --yes|-y) ARG_YES=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "argumento desconhecido: $1 (use --help)"; exit 2 ;;
  esac
  shift
done

[ -n "$ARG_VERSION" ] && ! semver_ok "$ARG_VERSION" && { err "versão inválida: $ARG_VERSION (use X.Y.Z)"; exit 2; }

# ==================================================================== main ==
printf '%s' "$BOLD$MAGENTA"
cat <<'EOF'
   ___  _ ___ _____  _    ___
  / _ \| | _ \_ _\ \/ /  /_\| _ \__ _ __ _ __ ___ _ _
 | (_) | |  _/| | >  <  / _ \  _/ _` / _|/ _/ _ \ ' \
  \___/|_|_| |___/_/\_\/_/ \_\_| \__,_\__\__\___/_||_|
EOF
printf '%s\n' "$RESET"

V_VERSION=$(get_version)
V_BUILD=$(get_buildnum)
GIT_DESC=$(git describe --tags 2>/dev/null || echo "sem tags")
GIT_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

hr
printf '%sVersão:%s %s (build %s)\n' "$BOLD" "$RESET" "$V_VERSION" "$V_BUILD"
printf '%sGit:%s %s · %s alteração(ões) não commitada(s)\n' "$BOLD" "$RESET" "$GIT_DESC" "$GIT_DIRTY"
printf '%sbuild/:%s %s  .build/: %s\n' "$BOLD" "$RESET" "$(du_of build)" "$(du_of .build)"
hr

# --- step 1: version --------------------------------------------------------
step "1/5 · Versão"
NEW_VERSION="$V_VERSION"

if [ -n "$ARG_VERSION" ]; then
  NEW_VERSION="$ARG_VERSION"
  info "versão fixada por --version: $NEW_VERSION"
elif [ -n "$ARG_BUMP" ]; then
  NEW_VERSION=$(bump_version "$V_VERSION" "$ARG_BUMP")
  info "bump $ARG_BUMP: $V_VERSION → $NEW_VERSION"
elif [ "$INTERACTIVE" = 1 ] && [ "$ARG_YES" = 0 ]; then
  SUGGEST_PATCH=$(bump_version "$V_VERSION" patch)
  SUGGEST_MINOR=$(bump_version "$V_VERSION" minor)
  choice=$(ask_option \
    "Qual versão este build deve usar?" \
    "Manter a atual ($V_VERSION)" \
    "Patch  → $SUGGEST_PATCH (correções)" \
    "Minor  → $SUGGEST_MINOR (funcionalidades novas)" \
    "Major  → $(bump_version "$V_VERSION" major) (mudanças incompatíveis)" \
    "Digitar outra versão")
  case "$choice" in
    1) info "mantendo $V_VERSION" ;;
    2) NEW_VERSION="$SUGGEST_PATCH" ;;
    3) NEW_VERSION="$SUGGEST_MINOR" ;;
    4) NEW_VERSION=$(bump_version "$V_VERSION" major) ;;
    5)
      while :; do
        printf 'Nova versão (X.Y.Z): '
        read -r v || exit 130
        if semver_ok "$v"; then NEW_VERSION="$v"; break; fi
        err "formato inválido — use X.Y.Z (ex.: 1.2.3)"
      done ;;
  esac
fi

if [ "$NEW_VERSION" != "$V_VERSION" ]; then
  set_version "$NEW_VERSION"
else
  info "sem bump de versão — usando $V_VERSION"
fi

# --- step 2: cleanup ---------------------------------------------------------
step "2/5 · Limpeza"
if [ "$ARG_NO_CLEAN" = 1 ]; then
  info "pulando limpeza (--no-clean)"
elif [ "$ARG_YES" = 1 ] || [ "$INTERACTIVE" = 0 ]; then
  rm -rf build
  ok "limpo: bundles antigos removidos (cache do Swift em .build preservado)"
else
  choice=$(ask_option \
    "Quanto limpar antes do build? (build atual: $(du_of build))" \
    "Nada — build incremental, mais rápido" \
    "Rápida — bundles antigos em build/  [$RELEASE_APP]" \
    "Total — apagar build/ E .build (recompila tudo, lento)")
  case "$choice" in
    1) info "sem limpeza" ;;
    2) rm -rf build; ok "bundles antigos removidos" ;;
    3)
      if confirm "Apagar build/ e .build ($(du_of .build)) — rebuild completo?" n; then
        rm -rf build .build
        ok "build/ e .build removidos — recompila do zero"
      else
        rm -rf build
        ok "mantido .build; bundles antigos removidos"
      fi ;;
  esac
fi

# --- step 3: pre-checks ------------------------------------------------------
step "3/5 · Pré-checks"
eject_orphan_dmg_mounts
check_signing
if [ "$GIT_DIRTY" != "0" ] && [ "$NEW_VERSION" != "$V_VERSION" ]; then
  warn "há $GIT_DIRTY alteração(ões) não commitada(s) junto com o bump de versão"
fi

# --- step 4: build / action --------------------------------------------------
step "4/5 · Ação"
if [ -z "$COMMAND" ]; then
  if [ "$INTERACTIVE" = 1 ] && [ "$ARG_YES" = 0 ]; then
    choice=$(ask_option \
      "O que você quer fazer?" \
      "install  PRODUÇÃO: sobrescreve o app em /Applications e reabre" \
      "dev       build debug e abre o app de debug" \
      "build     só o build release (bundle em build/)" \
      "test      roda a suíte de testes" \
      "package   release + zip + manifest de atualização p/ o site")
    case "$choice" in
      1) COMMAND="install" ;;
      2) COMMAND="dev" ;;
      3) COMMAND="build" ;;
      4) COMMAND="test" ;;
      5) COMMAND="package" ;;
    esac
  else
    COMMAND="build"
    info "sem comando — usando 'build' (padrão)"
  fi
fi

BUILD_START=$SECONDS
case "$COMMAND" in
  dev)
    ./scripts/build-app.sh --debug >/dev/null
    ok "debug app: $DEBUG_APP"
    open "$DEBUG_APP"
    ok "app de debug aberto (use --snapshot para validar a interface)"
    ;;
  build)
    ./scripts/build-app.sh >/dev/null
    ok "release app: $RELEASE_APP"
    ;;
  test)
    swift test
    ;;
  package)
    ./scripts/package.sh
    ;;
  install)
    info "produção: saindo do app aberto, sobrescrevendo $INSTALL_APP e reabrindo…"
    ./scripts/install.sh >/dev/null
    ;;
esac
ok "concluído em $((SECONDS - BUILD_START))s"

# --- step 5: post ------------------------------------------------------------
step "5/5 · Pós-build"
if [ "$COMMAND" = "install" ]; then
  if [ -d "$INSTALL_APP" ]; then
    INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || echo "?")
    INSTALLED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || echo "?")
    if [ "$INSTALLED" = "$NEW_VERSION" ]; then
      ok "$INSTALL_APP atualizado: versão $INSTALLED (build $INSTALLED_BUILD), app reaberto"
    else
      warn "$INSTALL_APP reporta versão $INSTALLED (esperado $NEW_VERSION)"
    fi
  else
    err "$INSTALL_APP não encontrado após a instalação"
    exit 1
  fi
elif [ "$COMMAND" = "build" ] || [ "$COMMAND" = "package" ]; then
  find build -maxdepth 2 \( -name '*.app' -o -name '*.zip' -o -name '*.json' \) -print 2>/dev/null \
    | while IFS= read -r f; do printf '  %s%s%s  %s\n' "$GREEN" "$(du -sh "$f" | cut -f1)" "$RESET" "$f"; done
fi

hr
if [ "$NEW_VERSION" != "$V_VERSION" ] && [ "$INTERACTIVE" = 1 ] && [ "$ARG_YES" = 0 ]; then
  if confirm "Criar commit de versão + tag v$NEW_VERSION agora?" n; then
    git add "$PLIST"
    git commit -m "chore: release v$NEW_VERSION"
    git tag "v$NEW_VERSION"
    ok "commit + tag v$NEW_VERSION criados (não enviei nada — push é manual)"
    printf '%s  dica: git push origin main --tags%s\n' "$DIM" "$RESET"
  fi
fi
printf '%sPronto!%s %s · versão %s (build %s)\n' "$BOLD$GREEN" "$RESET" "$COMMAND" "$NEW_VERSION" "$(get_buildnum)"
hr
