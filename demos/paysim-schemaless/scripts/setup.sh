#!/usr/bin/env bash
# Start the deployment if needed, create the database, apply the schema, load
# the data. Idempotent: safe to re-run after a partial failure.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=setup
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Setup — building the schemaless graph"

load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_VOLUME OMNI_VERSION OMNI_HOST OMNI_PORT \
            OMNI_DATABASE OMNI_GRAPH \
            PAYSIM_CLIENTS PAYSIM_TRANSACTIONS PAYSIM_DAYS PAYSIM_SEED

GEN_DIR="$DEMO_DIR/data/generated"

# Two tables, which is the entire point of this demo. Children before parents,
# so a re-run's DELETE does not trip over an interleaved child.
TABLES="GraphEdge GraphNode"

# 1 — the deployment. omni_start is idempotent: running, stopped, or absent all
# converge on "running", and the named volume means an existing database
# survives a container that was removed.
omni_start

# 2 — synthetic data. Local, seeded, stdlib only, no network.
info "generating synthetic payments (seed $PAYSIM_SEED — same seed, same graph)"
rm -rf "$GEN_DIR"
python3 "$DEMO_DIR/data/generate.py" \
  --out "$GEN_DIR" --seed "$PAYSIM_SEED" --days "$PAYSIM_DAYS" \
  --clients "$PAYSIM_CLIENTS" --transactions "$PAYSIM_TRANSACTIONS" \
  || die "Data generation failed." "Check that python3 is 3.9 or later: python3 --version"
ok "generated $(wc -l < "$GEN_DIR/GraphNode.csv" | tr -d ' ') node row(s) and $(wc -l < "$GEN_DIR/GraphEdge.csv" | tr -d ' ') edge row(s) across 2 table(s)"

# 3 — the database.
omni_db_create "$OMNI_DATABASE"

# 4 — schema and property graph. omni_ddl treats "already exists" as success,
# because re-running setup after a partial failure has to converge.
info "applying schema and the DYNAMIC LABEL property graph"
omni_ddl "$OMNI_DATABASE" "$DEMO_DIR/sql/01_schema.ddl" \
  || die "Applying sql/01_schema.ddl failed." \
         "See the error above. If the schema is half-applied, drop the database with './gxr down paysim-schemaless' and re-run."
ok "schema and property graph in place"

# 5 — clear, then load. Clearing first is what makes a second run converge
# rather than fail on a duplicate primary key.
info "clearing any previous rows"
omni_truncate "$OMNI_DATABASE" $TABLES

info "loading rows via Spanner's CSV import (this is the slow part)"
omni_import "$OMNI_DATABASE" "$GEN_DIR" \
  || die "The CSV import failed." \
         "Re-run setup — it clears and reloads, so repeating is safe. If it persists: docker logs $OMNI_CONTAINER"

# The import operation's own status is not trustworthy in this preview build
# (see omni_wait_operation), so assert the load actually landed. Cheap, and it
# turns a silent empty database into an error at the step that caused it.
#
# Both tables are checked: a manifest whose typeName does not match the DDL
# exactly — "STRING" where the column is STRING(MAX) — fails ONE table and
# reports it only inside the operation, never inline.
loaded=$(omni_sql_scalar "$OMNI_DATABASE" "SELECT COUNT(*) FROM GraphNode") || loaded=0
[ "${loaded:-0}" -ge 1 ] || die "The import reported no error but GraphNode is empty." \
  "Check the operation: docker exec -it $OMNI_CONTAINER /google/spanner/bin/spanner operations list --database=$OMNI_DATABASE"
edges=$(omni_sql_scalar "$OMNI_DATABASE" "SELECT COUNT(*) FROM GraphEdge") || edges=0
[ "${edges:-0}" -ge 1 ] || die "Nodes loaded but GraphEdge is empty." \
  "Check the operation for a per-table error: docker exec -it $OMNI_CONTAINER /google/spanner/bin/spanner operations list --database=$OMNI_DATABASE"
ok "loaded $loaded node(s) and $edges edge(s)"

ok "setup complete"
