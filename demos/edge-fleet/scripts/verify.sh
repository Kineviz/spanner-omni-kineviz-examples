#!/usr/bin/env bash
# Prove the graph works AND that the planted fragility is findable.
# Asserts, does not describe.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=verify
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Verify — running the blast-radius query"

load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_HOST OMNI_PORT OMNI_DATABASE OMNI_GRAPH
omni_require_running

# The demo's headline query, not a smoke test. If there is no concentration
# gateway the graph "works" and the demo says nothing.
if ! out=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (d:Device)-[:CONNECTED_TO]->(g:Gateway)-[:HOSTED_AT]->(s:Site)
  RETURN g.id AS gateway, s.name AS site, COUNT(d.id) AS devices
  GROUP BY gateway, site
  ORDER BY devices DESC
  LIMIT 5"); then
  e=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)
  case "$e" in
    *"Failed to find element label"*)
      die "GQL ran but a label was not found: $e" \
          "Edge labels are not table names in Spanner. Run ../../connect/verify.sh to list the real ones." ;;
    *"not found"*|*NotFound*)
      die "Database '$OMNI_DATABASE' or graph '$OMNI_GRAPH' is missing: $e" \
          "Re-run './gxr up edge-fleet' — setup is idempotent." ;;
    *)
      die "Verification query failed: $e" \
          "Re-run './gxr up edge-fleet' — setup is idempotent." ;;
  esac
fi

top=$(printf '%s\n' "$out" | awk 'NR==2 {print $NF}')
second=$(printf '%s\n' "$out" | awk 'NR==3 {print $NF}')
[ -n "${top:-}" ] || die "The blast-radius query returned nothing." \
  "The data is seeded, so this should not happen. Re-run setup; if it persists, open an issue."

# A "concentration" gateway that carries no more than the next one is not a
# finding. Assert the outlier, or the walkthrough reads as wrong.
[ "${second:-0}" -gt 0 ] && [ "$top" -gt "$((second * 2))" ] || \
  die "No concentration gateway: the busiest carries $top devices, the next $second." \
      "generate.py plants one at roughly triple the runner-up. The generator and the schema have drifted apart — please open an issue."
ok "busiest gateway carries $top devices; the next carries $second"

# The second half of the demo's claim: dependencies extend the radius past the
# directly-attached count. A bounded variable-length walk, because control
# dependencies acquire cycles.
cascade=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (upstream:Device)-[:DEPENDS_ON]->{1,4}(root:Device)
  RETURN root.id AS root, COUNT(DISTINCT upstream.id) AS n
  GROUP BY root
  NEXT
  FILTER n >= 3
  RETURN root, n" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)

[ "${cascade:-0}" -ge 1 ] || die "No device has three or more devices depending on it transitively." \
  "generate.py plants a four-hop chain. Re-run setup; if it persists, open an issue."
ok "$cascade device(s) carry a transitive dependency tail of 3 or more"

[ "$GXR_JSON" = 1 ] || printf '%s\n' "$out" | sed 's/^/      /'
echo "$top" > "$DEMO_DIR/.verified_rows"
