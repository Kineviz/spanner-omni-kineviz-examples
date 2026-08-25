#!/usr/bin/env bash
# Prove the schemaless graph works AND that the planted rings are findable.
# Asserts, does not describe.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=verify
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Verify — running the shared-identity ring query"

load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_HOST OMNI_PORT OMNI_DATABASE OMNI_GRAPH
omni_require_running

# Deliberately the demo's headline query, not a trivial smoke test: if this
# returns nothing the graph "works" but the demo is pointless.
#
# n.label, not LABELS(n)[OFFSET(0)]: every schemaless node also carries the
# table's own label (GraphNode), LABELS() returns them sorted, and OFFSET(0)
# would report "GraphNode" for every label alphabetically after it.
if ! out=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (c:client)-[:has_ssn|has_email|has_phone]->(i)
  RETURN i.label AS kind, STRING(i.name) AS identifier, COUNT(DISTINCT c.id) AS accounts
  GROUP BY kind, identifier
  NEXT
  FILTER accounts > 1
  RETURN kind, identifier, accounts
  ORDER BY accounts DESC, identifier"); then
  e=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)
  case "$e" in
    *"Failed to find element label"*)
      die "GQL ran but a label was not found: $e" \
          "In a schemaless graph labels are DATA, so they are whatever was inserted — and they must be lowercase. Run ../../connect/verify.sh to list the real ones." ;;
    *"No matching signature"*)
      die "A type coercion is missing: $e" \
          "Dynamic properties are JSON, not scalars. Wrap them: STRING(n.name), FLOAT64(n.amount), BOOL(n.highrisk). 'id' and 'label' are real columns and need no wrapper." ;;
    *"not found"*|*NotFound*)
      die "Database '$OMNI_DATABASE' or graph '$OMNI_GRAPH' is missing: $e" \
          "Re-run './gxr up paysim-schemaless' — setup is idempotent." ;;
    *Unavailable*|*Deadline*)
      die "The deployment stopped answering: $e" \
          "Check it is healthy: ./gxr omni status, and docker logs $OMNI_CONTAINER" ;;
    *)
      die "Verification query failed: $e" \
          "Re-run './gxr up paysim-schemaless' — setup is idempotent." ;;
  esac
fi

# First line is the CLI's column header.
rows=$(printf '%s\n' "$out" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)
[ "${rows:-0}" -ge 1 ] || die "No shared identifiers found — the demo's central finding is missing." \
  "The data is seeded, so this should not happen. Re-run setup; if it persists, open an issue."

ok "found $rows identifier(s) shared by more than one account"

# The demo's claim is not just "some identities are shared" — it is that the
# graph query separates the rings from the innocent family. Assert that too, or
# `verify` passes on data that would make the walkthrough read as wrong.
rings=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (a:client)-[:has_ssn|has_email|has_phone]->(i)<-[:has_ssn|has_email|has_phone]-(b:client),
        (a)-[:performs]->(t:transaction)-[:to_client]->(b)
  WHERE a.id <> b.id
  RETURN DISTINCT STRING(i.name) AS identifier" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)

[ "${rings:-0}" -ge 1 ] || die "Shared identifiers exist, but none of those accounts move money to each other — no rings." \
  "The generator plants two. Re-run setup; if it persists, generate.py and the schema have drifted apart."
[ "$rings" -lt "$rows" ] || warn "every shared identifier also moves money — the innocent family is missing from the data, so the demo's false-positive point will not land."

ok "$rings of those $rows also move money between themselves (the rest is the planted false positive)"

# Schemaless-specific: assert the graph really is dynamic-labelled rather than
# a static graph that happens to have two tables. If this drops to 1 the DDL
# lost its DYNAMIC LABEL clause, and every downstream claim in the README —
# including the one Kineviz's schema panel depends on — is wrong.
labels=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (n)
  RETURN DISTINCT n.label AS label
  ORDER BY label" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)
[ "${labels:-0}" -ge 5 ] || die "Only ${labels} distinct node label(s) — the graph is not carrying labels as data." \
  "Check that sql/01_schema.ddl still declares DYNAMIC LABEL (label) on GraphNode."
ok "$labels node labels discovered from data, not from the schema"

[ "$GXR_JSON" = 1 ] || printf '%s\n' "$out" | sed 's/^/      /'
echo "$rows" > "$DEMO_DIR/.verified_rows"
