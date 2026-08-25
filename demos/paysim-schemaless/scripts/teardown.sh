#!/usr/bin/env bash
# Drop the database this demo created — and NOTHING else.
#
# Specifically not the container and not the volume. The volume holds every
# database on the deployment: other demos in this repo, and anything you built
# yourself. Removing it to clean up one demo would be destroying unrelated data
# to save a few megabytes. Removing the container is your call too, and
# './gxr omni destroy' is where that lives.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=teardown
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Teardown — removing what this demo created"
load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_DATABASE

if omni_running; then
  omni_db_drop "$OMNI_DATABASE"
else
  info "Spanner Omni is not running — nothing to drop from"
  dim "start it with './gxr omni up' if you want the database gone from the volume"
fi

rm -rf "$DEMO_DIR/data/generated" "$DEMO_DIR/.verified_rows"
ok "removed locally generated data"

info "The deployment ($OMNI_CONTAINER) and volume ($OMNI_VOLUME) were NOT touched."
dim "remove the whole deployment yourself with: ./gxr omni destroy --all"
