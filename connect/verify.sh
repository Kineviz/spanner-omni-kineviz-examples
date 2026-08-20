#!/usr/bin/env bash
#
# Prove a Spanner Omni property graph is reachable and queryable — before
# involving Kineviz at all. If this passes and Kineviz still cannot see your
# graph, the problem is the connection route, not Spanner Omni.
#
#   ./connect/verify.sh --database D --graph G
#
# Creates nothing. Reads only. Needs Docker and a stdlib Python 3, nothing else.
#
# There is no --project and no --instance, and that is not an omission: Spanner
# Omni fixes both to the literal string `default`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=shared/lib/common.sh
source "$REPO_ROOT/shared/lib/common.sh"

DATABASE=""; GRAPH=""; JSON=0

usage() {
  cat <<'EOF'
Usage: ./connect/verify.sh --database <name> --graph <name> [--container <name>] [--json]

  --database    Spanner Omni database id
  --graph       Property graph name (from CREATE PROPERTY GRAPH)
  --container   Deployment container (default: $OMNI_CONTAINER, else spanneromni)
  --json        Machine-readable output
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --database)  DATABASE="${2:-}"; shift 2 ;;
    --graph)     GRAPH="${2:-}"; shift 2 ;;
    --container) OMNI_CONTAINER="${2:-}"; shift 2 ;;
    --json)      JSON=1; GXR_JSON=1; export GXR_JSON; shift ;;
    -h|--help)   usage 0 ;;
    *)           echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[ -n "$DATABASE" ] && [ -n "$GRAPH" ] || die "Missing required arguments." "Run ./connect/verify.sh --help"

require_docker
omni_running || die \
  "Spanner Omni is not running (container: $OMNI_CONTAINER)." \
  "Start it with './gxr omni up', or pass --container if yours has a different name."

[ "$JSON" = 1 ] || printf '\nChecking %s → database %s → graph %s\n\n' "$(omni_endpoint)" "$DATABASE" "$GRAPH"

# 1 — the database exists and answers.
omni_db_exists "$DATABASE" || die \
  "Database '$DATABASE' does not exist on this deployment." \
  "List what is there: ./gxr omni status"

if ! out=$(omni_sql "$DATABASE" "SELECT 1 AS ok"); then
  die "Database '$DATABASE' did not answer: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" \
      "Check the deployment is healthy: ./gxr omni status, and docker logs $OMNI_CONTAINER"
fi
ok "deployment reachable at $(omni_endpoint), database '$DATABASE' answers"

# 2 — the property graph is registered.
graphs=$(omni_list_graphs "$DATABASE" || true)
printf '%s\n' "$graphs" | grep -qx "$GRAPH" || die \
  "No property graph named '$GRAPH' in $DATABASE." \
  "Graphs present: $(printf '%s' "$graphs" | tr '\n' ' ' | sed 's/  */ /g'). Names are case-sensitive."
ok "property graph '$GRAPH' is registered"

# 3 — surface the LABELS, not the table names.
#
# The single most common Spanner Graph mistake: a table called UsedDevice may
# declare LABEL USED_DEVICE, and GQL wants the label. Getting this wrong gives
# "Failed to find element label [X]", which reads like the graph is broken when
# only the query is.
labels=$(omni_graph_labels "$DATABASE" "$GRAPH" 2>/dev/null || true)
node_labels=$(printf '%s\n' "$labels" | sed -n 's/^NODE: //p')
edge_labels=$(printf '%s\n' "$labels" | sed -n 's/^EDGE: //p')
if [ -n "$node_labels" ]; then
  ok "labels resolved"
  dim "node labels: ${node_labels}"
  dim "edge labels: ${edge_labels}"
  dim "use these in GQL — they are often NOT the table names"
fi

# 4 — it actually answers a GQL query. Steps 1-3 only prove registration.
if ! out=$(omni_sql "$DATABASE" "GRAPH $GRAPH MATCH (n) RETURN COUNT(n) AS node_count"); then
  e=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240)
  case "$e" in
    *"Failed to find element label"*)
      die "GQL ran but a label was not found: $e" "Use the labels listed above, not the table names." ;;
    *)
      die "GQL query failed: $e" "Confirm the graph's node tables are readable, then re-run." ;;
  esac
fi
nodes=$(printf '%s\n' "$out" | awk 'NR==2' | tr -d ' \r')
ok "GQL query succeeded (graph has ${nodes:-?} nodes)"

if [ "$JSON" = 1 ]; then
  printf '{"ok":true,"endpoint":"%s","project":"default","instance":"default","database":"%s","graph":"%s","nodes":%s,"node_labels":"%s","edge_labels":"%s"}\n' \
    "$(omni_endpoint)" "$DATABASE" "$GRAPH" "${nodes:-0}" "$node_labels" "$edge_labels"
else
  cat <<EOF

  ${_c_green}The graph is good.${_c_reset} What Kineviz needs, whichever route you take:

    Endpoint   : $(omni_endpoint)      (plain text — Spanner Omni preview has no TLS)
    Project    : default            (fixed by Spanner Omni)
    Instance   : default            (fixed by Spanner Omni)
    Database   : $DATABASE
    Graph      : $GRAPH

  Kineviz has no native Spanner Omni connector yet. Pick a route in
  connect/README.md § 3 · Connect — the database proxy for live GQL, or a CSV
  export for a snapshot that works today with nothing to patch:

    ./connect/export.py --database $DATABASE --graph $GRAPH --out ./export

EOF
fi
