#!/usr/bin/env bash
# Common helpers for demo scripts.
#
# Two output modes, one code path: human-readable by default, --json for agents.
# Source this at the top of every script:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
#
# Spanner Omni specifics live in omni.sh, which this file sources.

set -euo pipefail

: "${GXR_JSON:=0}"   # set to 1 by --json
: "${GXR_STEP:=}"    # current step id, for JSON output

# --- output -----------------------------------------------------------------

_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'
_c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_bold=$'\033[1m'
if [ ! -t 1 ]; then _c_reset=""; _c_dim=""; _c_red=""; _c_green=""; _c_yellow=""; _c_bold=""; fi

# JSON-escape a string using only shell builtins (no jq dependency).
_json_escape() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  printf '%s' "$s"
}

_emit_json() {  # _emit_json <level> <message> [remediation]
  printf '{"step":"%s","level":"%s","message":"%s"' \
    "$(_json_escape "$GXR_STEP")" "$1" "$(_json_escape "$2")"
  [ -n "${3:-}" ] && printf ',"remediation":"%s"' "$(_json_escape "$3")"
  printf '}\n'
}

info() { if [ "$GXR_JSON" = 1 ]; then _emit_json info "$1"; else printf '  %s\n' "$1"; fi; }
step() { if [ "$GXR_JSON" = 1 ]; then _emit_json step "$1"; else printf '\n%s▸ %s%s\n' "$_c_bold" "$1" "$_c_reset"; fi; }
ok()   { if [ "$GXR_JSON" = 1 ]; then _emit_json ok "$1";   else printf '  %s✓%s %s\n' "$_c_green" "$_c_reset" "$1"; fi; }
warn() { if [ "$GXR_JSON" = 1 ]; then _emit_json warn "$1"; else printf '  %s!%s %s\n' "$_c_yellow" "$_c_reset" "$1" >&2; fi; }
dim()  { if [ "$GXR_JSON" = 1 ]; then :; else printf '    %s%s%s\n' "$_c_dim" "$1" "$_c_reset"; fi; }

# die <message> <remediation...>
#
# Every failure exits non-zero with exactly one REMEDIATION line, because that is
# what AGENTS.md tells agents to relay verbatim. Never fail silently, never fail
# with only a stack trace.
die() {
  local msg="$1"; shift
  local rem="${*:-See the demo README.}"
  if [ "$GXR_JSON" = 1 ]; then
    _emit_json error "$msg" "$rem" >&2
  else
    printf '\n  %s✗%s %s\n' "$_c_red" "$_c_reset" "$msg" >&2
    printf '    REMEDIATION: %s\n\n' "$rem" >&2
  fi
  exit 1
}

# --- environment ------------------------------------------------------------

# Parse --json out of "$@". Usage: eval "$(parse_common_flags "$@")"
parse_common_flags() {
  for arg in "$@"; do
    [ "$arg" = "--json" ] && echo "GXR_JSON=1; export GXR_JSON"
  done
  echo ":"
}

# Load .env if present. Never load .env.example — it holds placeholders, and
# silently running against a placeholder value is worse than failing.
load_env() {
  local dir="${1:-.}"
  if [ -f "$dir/.env" ]; then
    set -a; . "$dir/.env"; set +a
    dim "loaded $dir/.env"
  fi
}

require_env() {
  local missing=()
  for var in "$@"; do
    [ -z "${!var:-}" ] && missing+=("$var")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required config: ${missing[*]}" \
        "cp .env.example .env, fill in ${missing[*]}, then re-run. Nothing has been created yet."
  fi
}

require_cli() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || \
      die "'$bin' not found on PATH." "Install $bin, then re-run. Nothing has been created yet."
  done
  ok "required CLIs present: $*"
}

# --- Kineviz Desktop --------------------------------------------------------

KINEVIZ_RELEASES="https://github.com/Kineviz/kineviz-desktop/releases"

# Best-effort platform detection, used to hand the person the right asset URL.
kineviz_asset_hint() {
  local ver="$1" os arch
  os=$(uname -s); arch=$(uname -m)
  case "$os:$arch" in
    Darwin:arm64)  echo "$KINEVIZ_RELEASES/download/v$ver/Kineviz-Desktop-$ver-mac-arm64.dmg" ;;
    Darwin:x86_64) echo "$KINEVIZ_RELEASES/download/v$ver/Kineviz-Desktop-$ver-mac-x64.dmg" ;;
    Linux:aarch64) echo "$KINEVIZ_RELEASES/download/v$ver/Kineviz-Desktop-$ver-linux-arm64.AppImage" ;;
    Linux:x86_64)  echo "$KINEVIZ_RELEASES/download/v$ver/Kineviz-Desktop-$ver-linux-x86_64.AppImage" ;;
    *)             echo "$KINEVIZ_RELEASES/tag/v$ver" ;;
  esac
}

# Look for an installed Desktop. Absence is not fatal on its own — the caller
# decides — because someone may be running the hosted portal.
kineviz_desktop_installed() {
  case "$(uname -s)" in
    Darwin) [ -d "/Applications/Kineviz Desktop.app" ] && return 0 ;;
    Linux)  command -v kineviz-desktop >/dev/null 2>&1 && return 0
            [ -d "$HOME/.local/share/applications" ] && \
              grep -rqil "kineviz" "$HOME/.local/share/applications" 2>/dev/null && return 0 ;;
    *)      command -v kineviz-desktop >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

# warn_kineviz_desktop <floor-version>
#
# Deliberately a warning, not a hard stop — unlike the cloud-backed repos in
# this family. Everything up to and including `verify` runs entirely against
# your local Spanner Omni deployment and is useful on its own, so a missing
# Desktop must not block building and querying the graph. `handoff` is where
# Desktop matters, and that is where the three person-only steps are spelled
# out. See AGENTS.md.
warn_kineviz_desktop() {
  local floor="$1"
  if kineviz_desktop_installed; then
    ok "Kineviz Desktop found (floor: v$floor or later)"
    dim "if yours is older than v$floor, update from $KINEVIZ_RELEASES"
    return 0
  fi
  warn "Kineviz Desktop not found — the demo will still build and verify locally."
  dim "three steps, all yours — an agent cannot do any of them for you:"
  dim "  1. create a Kineviz account (free for individual use, forever): https://www.kineviz.com/"
  dim "  2. install Kineviz Desktop v$floor or later:"
  dim "     $(kineviz_asset_hint "$floor")"
  dim "  3. launch it and sign in"
  return 0
}

# --- misc -------------------------------------------------------------------

confirm() {  # confirm <prompt> — always answered by a person, never auto-yes
  local reply
  if [ ! -t 0 ]; then
    die "Confirmation required but stdin is not a terminal: $1" \
        "Re-run interactively. Destructive steps are never auto-confirmed."
  fi
  printf '  %s [y/N] ' "$1"; read -r reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

demo_dir() { cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd; }

# Spanner Omni deployment + CLI helpers.
# shellcheck source=shared/lib/omni.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/omni.sh"

# The Kafka replay leg. Sourced here, not only from gxr, because teardown.sh has
# to stop the sink before dropping the database it is writing into.
# shellcheck source=shared/lib/stream.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stream.sh"
