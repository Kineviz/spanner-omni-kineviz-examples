#!/usr/bin/env bash
# What to say when the graph is built. Relayed verbatim; changes here change
# what every agent tells the person.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=handoff
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env "$DEMO_DIR"
rows=$(cat "$DEMO_DIR/.verified_rows" 2>/dev/null || echo "?")
desktop="not detected"; kineviz_desktop_installed && desktop="detected"

cat <<EOF

✅ Demo ready: paysim-schemaless
   Kineviz (formerly GraphXR) · Spanner Omni · schemaless property graph

   Deployment: ${OMNI_CONTAINER} at $(omni_endpoint)   (yours; not deleted by teardown)
   Console:    $(omni_console_url)   (read-only in preview)
   Database:   ${OMNI_DATABASE}   (synthetic PaySim, ${PAYSIM_CLIENTS} accounts, seed ${PAYSIM_SEED})
   Graph:      ${OMNI_GRAPH} — two tables, seven labels, all of them data
                 nodes  client · transaction · merchant · bank
                        email · phonenumber · ssn
                 edges  performs · to_client · to_merchant · to_bank
                        has_email · has_phone · has_ssn
   Verified:   ${rows} shared identifier(s) found
   Desktop:    ${desktop}

   Connect Kineviz — one command:
     ./gxr connect up paysim-schemaless

   That installs and starts the database proxy, registers this database with
   it, and prints the URL to paste into Kineviz Desktop. The Kineviz Agent
   needs no separate setup: it inherits whatever the project is connected to.

   Query it right now, without Kineviz:
     ./gxr omni sql ${OMNI_DATABASE}
     ../../connect/verify.sh --database ${OMNI_DATABASE} --graph ${OMNI_GRAPH}

   Then try, on the Kineviz canvas — these draw nodes and edges:
     1. Accounts sharing an identity          queries/canvas/01-shared-identifiers.gql
     2. Which of those also move money        queries/canvas/02-fraud-rings.gql
     3. Fan-in to a collector account         queries/canvas/03-collector-accounts.gql
     4. Where value leaves the network        queries/canvas/04-cash-out.gql

     Run 1 then 2. One of the identity clusters in 1 is an innocent family, and
     2 is what drops it out of the picture.

     The same four as tables, plus the schemaless proof, are in queries/ —
     Spanner will not hand a graph element back to a client, so the canvas set
     is Kineviz-only.

   What makes this the schemaless demo: there are two tables. Labels and
   properties are columns, not schema. Adding a node type is an INSERT — and
   you can watch that happen, with the dataset put back afterwards:
     ./scripts/prove-schemaless.sh

   Cost so far: ~\$0.00 — nothing billable exists. This ran on your hardware.
   Tear down with:  ./gxr down paysim-schemaless   (drops the database, keeps the deployment)

   Reminder: this deployment stops accepting writes 90 days after you created
   it, and speaks plain text with no TLS. Both are Spanner Omni preview limits.

EOF
