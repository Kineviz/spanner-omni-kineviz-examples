#!/usr/bin/env bash
# Prove the graph works AND that the planted rings are findable.
# Asserts, does not describe.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=verify
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Verify — running the shared-device ring query"

load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_HOST OMNI_PORT OMNI_DATABASE OMNI_GRAPH
omni_require_running

# Deliberately the demo's headline query, not a trivial smoke test: if this
# returns nothing the graph "works" but the demo is pointless.
if ! out=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (c:Client)-[:USED_DEVICE]->(d:Device)
  RETURN d.id AS device, COUNT(DISTINCT c.id) AS accounts
  GROUP BY device
  NEXT
  FILTER accounts > 1
  RETURN device, accounts
  ORDER BY accounts DESC"); then
  e=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)
  case "$e" in
    *"Failed to find element label"*)
      die "GQL ran but a label was not found: $e" \
          "Edge labels are not table names in Spanner. Run ../../connect/verify.sh to list the real ones." ;;
    *"not found"*|*NotFound*)
      die "Database '$OMNI_DATABASE' or graph '$OMNI_GRAPH' is missing: $e" \
          "Re-run './gxr up fraud-rings' — setup is idempotent." ;;
    *Unavailable*|*Deadline*)
      die "The deployment stopped answering: $e" \
          "Check it is healthy: ./gxr omni status, and docker logs $OMNI_CONTAINER" ;;
    *)
      die "Verification query failed: $e" \
          "Re-run './gxr up fraud-rings' — setup is idempotent." ;;
  esac
fi

# First line is the CLI's column header.
rows=$(printf '%s\n' "$out" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)
[ "${rows:-0}" -ge 1 ] || die "No shared devices found — the demo's central finding is missing." \
  "The data is seeded, so this should not happen. Re-run setup; if it persists, open an issue."

ok "found $rows device(s) shared by more than one account"

# The demo's claim is not just "some devices are shared" — it is that the graph
# query separates the two rings from the innocent family. Assert that too, or
# `verify` passes on data that would make the walkthrough read as wrong.
rings=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (a:Client)-[:USED_DEVICE]->(d:Device)<-[:USED_DEVICE]-(b:Client),
        (a)-[:PAID]->(b)
  WHERE a.id <> b.id
  RETURN DISTINCT d.id AS device" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)

[ "${rings:-0}" -ge 1 ] || die "Shared devices exist, but none of them also move money — no rings." \
  "The generator plants two. Re-run setup; if it persists, generate.py and the schema have drifted apart."
[ "$rings" -lt "$rows" ] || warn "every shared device also moves money — the innocent family is missing from the data, so the demo's false-positive point will not land."

ok "$rings of those $rows also move money between themselves (the rest is the planted false positive)"
[ "$GXR_JSON" = 1 ] || printf '%s\n' "$out" | sed 's/^/      /'
echo "$rows" > "$DEMO_DIR/.verified_rows"
