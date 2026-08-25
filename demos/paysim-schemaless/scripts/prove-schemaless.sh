#!/usr/bin/env bash
# Prove the graph is genuinely schemaless — by changing it, live.
set -euo pipefail
#
# Not part of the demo lifecycle: `./gxr up` never runs this. It exists because
# the claim lands when someone watches a node type appear without a schema
# migration.
#
# What it does, in order:
#
#   1. Reads what the CATALOG knows and what the DATA contains, side by side.
#   2. Adds a node type and an edge type that do not exist. No DDL.
#   3. Queries the new label, which now works.
#   4. Reads both sides again — the schema row is UNCHANGED, the data row grew.
#   5. Shows Kineviz's schema picking the new category up, if the proxy is up.
#   6. Removes what it added.
#
# Step 6 runs on every exit path, including failure and Ctrl-C, so the demo
# dataset is left exactly as it was found.
#
# The writes go through the CLI on purpose. The database proxy runs every
# statement in a read-only snapshot, so DML through Kineviz comes back as
# "DML statements may not be performed in single-use transactions". Applications
# write, Kineviz reads.
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=prove
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERY_FILE="$DEMO_DIR/queries/05-prove-schemaless.sql"

# --keep leaves the added types in place; --undo removes them and stops.
# Without them the script inserts and cleans up in one run, which is right for
# a check and useless for a demo: nobody can look at Kineviz in the second
# between the insert and the delete.
KEEP=0; UNDO_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --undo) UNDO_ONLY=1 ;;
    --json) ;;
    *) die "Unknown flag: $arg" "Usage: ./scripts/prove-schemaless.sh [--keep] [--undo] [--json]" ;;
  esac
done

step "Proving the graph is schemaless"

load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_DATABASE OMNI_GRAPH
omni_require_running

NODE_ID="regulator_R01"
EDGE_SRC="client_C0394"

# Undo on every exit path — success, failure, or interrupt. Without this a
# failed run leaves a node behind and the next `verify` counts eight labels.
cleanup() {
  omni_sql "$OMNI_DATABASE" \
    "DELETE FROM GraphEdge WHERE id='$EDGE_SRC' AND dest_id='$NODE_ID' AND edge_id='sar1'" >/dev/null 2>&1 || true
  omni_sql "$OMNI_DATABASE" \
    "DELETE FROM GraphNode WHERE id='$NODE_ID'" >/dev/null 2>&1 || true
}
if [ "$UNDO_ONLY" = 1 ]; then
  cleanup
  ok "removed :regulator and :reported_to (if they were there)"
  exit 0
fi

# Only arm the trap when we intend to clean up. With --keep the rows are the
# point, and undoing them on exit would defeat it.
[ "$KEEP" = 1 ] || trap cleanup EXIT INT TERM

# Start from a known state: a previous interrupted run may have left rows.
cleanup

sides() {  # print the two-row catalog-vs-data result
  omni_sql "$OMNI_DATABASE" "$(omni_strip_comments < "$QUERY_FILE")" \
    || die "The proof query failed." "Check that $QUERY_FILE still matches OMNI_GRAPH=$OMNI_GRAPH."
}

info "1 · what the schema knows, and what the data contains"
before=$(sides)
[ "$GXR_JSON" = 1 ] || printf '%s\n' "$before" | sed 's/^/      /'

schema_before=$(printf '%s\n' "$before" | grep 'the schema' | sed 's/.*label  *//' | sed 's/[[:space:]]*$//')
labels_before=$(printf '%s\n' "$before" | grep 'the data' | tr ',' '\n' | grep -c . || true)
ok "the catalog knows 1 label; the data carries $labels_before"

info "2 · adding a node type and an edge type — no DDL, no schema update"
omni_sql "$OMNI_DATABASE" "INSERT INTO GraphNode (id, label, properties) VALUES ('$NODE_ID', 'regulator', JSON'{\"name\": \"Financial Conduct Authority\", \"jurisdiction\": \"UK\"}')" >/dev/null \
  || die "Could not insert the new node type." \
         "If this says the deployment is read-only, it has passed the 90-day write window. See docs/PREVIEW_NOTES.md"
omni_sql "$OMNI_DATABASE" "INSERT INTO GraphEdge (id, dest_id, edge_id, label, properties) VALUES ('$EDGE_SRC', '$NODE_ID', 'sar1', 'reported_to', JSON'{\"filed\": \"2026-02-01\", \"reason\": \"structuring\"}')" >/dev/null \
  || die "Could not insert the new edge type." "See the error above."
ok "inserted :regulator and :reported_to"

info "3 · querying a label that did not exist a moment ago"
hit=$(omni_sql "$OMNI_DATABASE" "
  GRAPH $OMNI_GRAPH
  MATCH (c:client)-[r:reported_to]->(g:regulator)
  RETURN STRING(c.name) AS client, STRING(g.name) AS regulator,
         STRING(g.jurisdiction) AS jurisdiction, STRING(r.reason) AS reason") \
  || die "The new label is not queryable." \
         "That should be impossible on a dynamic-label graph. Check sql/01_schema.ddl still declares DYNAMIC LABEL (label)."
rows=$(printf '%s\n' "$hit" | awk 'NR>1' | sed 's/[[:space:]]*$//' | grep -c . || true)
[ "${rows:-0}" -ge 1 ] || die "The new label returned no rows." "The insert reported success but the graph cannot see it."
[ "$GXR_JSON" = 1 ] || printf '%s\n' "$hit" | sed 's/^/      /'
ok "queryable immediately, with no migration in between"

info "4 · the same two sides again"
after=$(sides)
[ "$GXR_JSON" = 1 ] || printf '%s\n' "$after" | sed 's/^/      /'

schema_after=$(printf '%s\n' "$after" | grep 'the schema' | sed 's/.*label  *//' | sed 's/[[:space:]]*$//')
labels_after=$(printf '%s\n' "$after" | grep 'the data' | tr ',' '\n' | grep -c . || true)

# The assertion the whole script exists to make.
[ "$schema_before" = "$schema_after" ] || die \
  "The schema changed, which means this was not a schemaless insert." \
  "Expected the catalog to be untouched. Got '$schema_before' before and '$schema_after' after."
[ "$labels_after" -gt "$labels_before" ] || die \
  "The data did not gain a label." "Expected more than $labels_before, got $labels_after."
ok "schema unchanged ($schema_after); data went from $labels_before labels to $labels_after"

# 5 — Kineviz's view, when the proxy happens to be running. Optional: the proof
# stands without it, and the demo must not require the proxy to be up.
proxy_url="http://127.0.0.1:${PROXY_PORT:-9080}/api/spanner/${PROXY_PROJECT:-paysim-schemaless}/graphSchema"
if cats=$(curl -fsS --max-time 20 "$proxy_url" 2>/dev/null); then
  names=$(printf '%s' "$cats" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
print(", ".join(c["name"] for c in (d.get("data") or {}).get("categories", [])))' 2>/dev/null || true)
  case "$names" in
    *regulator*) ok "Kineviz sees it too, with no reconnect: $names" ;;
    "")          info "the proxy answered but returned no schema — skipping that check" ;;
    *)           warn "the proxy is up but has not picked up :regulator yet — $names" ;;
  esac
else
  info "database proxy not running — skipping the Kineviz check"
  dim "start it with './gxr connect up paysim-schemaless' to see the category appear there too"
fi

if [ "$KEEP" = 1 ]; then
  ok "left :regulator and :reported_to in place (--keep)"
  info "look at it in Kineviz, then undo with: ./scripts/prove-schemaless.sh --undo"
  exit 0
fi

info "6 · removing what this added"
cleanup
trap - EXIT INT TERM
final=$(sides | grep 'the data' | tr ',' '\n' | grep -c . || true)
[ "$final" = "$labels_before" ] || die \
  "Cleanup left the graph with $final labels instead of $labels_before." \
  "Remove them by hand: DELETE FROM GraphNode WHERE id='$NODE_ID';"
ok "back to $final labels — the dataset is as it was"

ok "labels here are data, not schema"
