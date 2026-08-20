#!/usr/bin/env bash
# Start the deployment if needed, create the database, apply the schema, load
# the data. Idempotent: safe to re-run after a partial failure.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=setup
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step "Setup — building the graph"

load_env "$DEMO_DIR"
require_env OMNI_CONTAINER OMNI_VOLUME OMNI_VERSION OMNI_HOST OMNI_PORT \
            OMNI_DATABASE OMNI_GRAPH \
            FRAUD_CLIENTS FRAUD_TRANSACTIONS FRAUD_DAYS FRAUD_SEED

GEN_DIR="$DEMO_DIR/data/generated"

# Children before parents, so a re-run's DELETE does not trip over a reference.
TABLES="PaidMerchant Paid UsedDevice Merchant Device Client"

# 1 — the deployment. omni_start is idempotent: running, stopped, or absent all
# converge on "running", and the named volume means an existing database
# survives a container that was removed.
omni_start

# 2 — synthetic data. Local, seeded, stdlib only, no network.
info "generating synthetic payments (seed $FRAUD_SEED — same seed, same graph)"
rm -rf "$GEN_DIR"
python3 "$DEMO_DIR/data/generate.py" \
  --out "$GEN_DIR" --seed "$FRAUD_SEED" --days "$FRAUD_DAYS" \
  --clients "$FRAUD_CLIENTS" --transactions "$FRAUD_TRANSACTIONS" \
  || die "Data generation failed." "Check that python3 is 3.9 or later: python3 --version"
ok "generated $(wc -l < "$GEN_DIR/Paid.csv" | tr -d ' ') transfer row(s) across 6 table(s)"

# 3 — the database.
omni_db_create "$OMNI_DATABASE"

# 4 — schema and property graph. omni_ddl treats "already exists" as success,
# because re-running setup after a partial failure has to converge.
info "applying schema and property graph"
omni_ddl "$OMNI_DATABASE" "$DEMO_DIR/sql/01_schema.ddl" \
  || die "Applying sql/01_schema.ddl failed." \
         "See the error above. If the schema is half-applied, drop the database with './gxr down fraud-rings' and re-run."
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
loaded=$(omni_sql_scalar "$OMNI_DATABASE" "SELECT COUNT(*) FROM Client") || loaded=0
[ "${loaded:-0}" -ge 1 ] || die "The import reported no error but Client is empty." \
  "Check the operation: docker exec -it $OMNI_CONTAINER /google/spanner/bin/spanner operations list --database=$OMNI_DATABASE"
ok "loaded $loaded client(s) and their transactions"

ok "setup complete"
