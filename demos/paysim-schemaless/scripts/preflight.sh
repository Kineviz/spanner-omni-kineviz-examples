#!/usr/bin/env bash
# Check everything before creating anything. Creates nothing, costs nothing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=preflight
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Preflight — checking prerequisites (nothing will be created)"

[ -f "$DEMO_DIR/.env" ] || die "No .env found." \
  "cp .env.example .env — the defaults work as they stand, nothing to fill in. Then re-run."
load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_VOLUME OMNI_VERSION OMNI_HOST OMNI_PORT \
            OMNI_DATABASE OMNI_GRAPH \
            PAYSIM_CLIENTS PAYSIM_TRANSACTIONS PAYSIM_DAYS PAYSIM_SEED

require_cli docker python3
require_docker
ok "Docker daemon responding"

# python3 only has to be an interpreter — the generator is stdlib-only, and the
# load path is the CLI's own CSV import. No pip install stands between you and
# this demo.
py_ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "0.0")
case "$py_ver" in
  3.9|3.1[0-9]|[4-9].*) ok "python3 $py_ver" ;;
  *) die "python3 $py_ver is too old." "The data generator needs Python 3.9 or later." ;;
esac

# Spanner database ids: 2-30 characters, start with a lowercase letter, then
# lowercase letters, digits, underscores and hyphens, not ending in a hyphen.
# Catching this here is the difference between a clear message and an opaque
# INVALID_ARGUMENT from the admin API after the deployment has already started.
case "$OMNI_DATABASE" in
  [a-z]*[a-z0-9]) : ;;
  *) die "OMNI_DATABASE '$OMNI_DATABASE' is not a valid Spanner database id." \
         "Start with a lowercase letter, use only lowercase letters, digits, '_' and '-', and do not end with '-'." ;;
esac
[ "${#OMNI_DATABASE}" -ge 2 ] && [ "${#OMNI_DATABASE}" -le 30 ] || \
  die "OMNI_DATABASE '$OMNI_DATABASE' must be 2-30 characters." "Shorten it in .env."
ok "database id '$OMNI_DATABASE' is valid"

if omni_running; then
  ok "Spanner Omni is running at $(omni_endpoint)"
  if omni_db_exists "$OMNI_DATABASE"; then
    warn "Database $OMNI_DATABASE already exists — setup will reuse it and replace its rows."
  fi

  # The 90-day write window is the failure that looks like nothing: reads keep
  # working, and the next load quietly has nowhere to go. Say the age out loud
  # while there is still time to act on it.
  created=$(docker inspect -f '{{.Created}}' "$OMNI_CONTAINER" 2>/dev/null | cut -c1-10 || true)
  if [ -n "$created" ]; then
    age=$(python3 - "$created" <<'PY' 2>/dev/null || echo ""
import datetime, sys
d = datetime.date.fromisoformat(sys.argv[1])
print((datetime.date.today() - d).days)
PY
)
    if [ -n "$age" ]; then
      if [ "$age" -ge 90 ]; then
        die "This deployment is ${age} days old and has passed the 90-day write window." \
            "Spanner Omni stops accepting writes 90 days after a deployment is created. Recreate it: './gxr omni destroy --all' then './gxr omni up'. Nothing has been created yet."
      elif [ "$age" -ge 75 ]; then
        warn "deployment is ${age} days old — writes stop at 90 days. Plan to recreate it."
      else
        dim "deployment is ${age} day(s) old; writes stop at 90"
      fi
    fi
  fi
else
  info "Spanner Omni is not running yet — setup will start it"
  dim "image $OMNI_IMAGE:$OMNI_VERSION, first run pulls ~1 GB"
fi

# Preview terms, stated before anything is built rather than after.
warn "Spanner Omni is pre-GA: no TLS, no auth, and writes stop 90 days after a deployment is created."
dim "fine on a machine you control; not a production posture. See docs/PREVIEW_NOTES.md"

# A warning, not a stop. Everything up to and including verify runs locally and
# is worth having on its own; Desktop only matters at handoff.
warn_kineviz_desktop "0.17.1"

ok "preflight passed — nothing has been created yet"
info "Next: ./scripts/setup.sh (starts the deployment if needed, creates database ${OMNI_DATABASE})"
