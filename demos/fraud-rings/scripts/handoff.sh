#!/usr/bin/env bash
# Everything above was automatable. Everything below is the person's.
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

✅ Demo ready: fraud-rings
   Kineviz (formerly GraphXR) · Spanner Omni

   Deployment: ${OMNI_CONTAINER} at $(omni_endpoint)   (yours; not deleted by teardown)
   Console:    $(omni_console_url)   (read-only in preview)
   Database:   ${OMNI_DATABASE}   (synthetic, ${FRAUD_CLIENTS} accounts, seed ${FRAUD_SEED})
   Graph:      ${OMNI_GRAPH} — Client, Device, Merchant / USED_DEVICE, PAID, PAID_MERCHANT
   Verified:   ${rows} shared device(s) found
   Desktop:    ${desktop}

   Query it right now, without Kineviz:
     ./gxr omni sql ${OMNI_DATABASE}
     ../../connect/verify.sh --database ${OMNI_DATABASE} --graph ${OMNI_GRAPH}

   Last step — connect Kineviz. Spanner Omni has no native Kineviz connector
   yet, so pick a route in ../../connect/README.md:
     · database proxy — live GQL from the canvas, one small driver change
     · CSV export     — works today with no patching, static snapshot

   Then try:
     1. Accounts sharing a device            queries/01-shared-devices.gql
     2. Money moving in a closed cycle       queries/02-money-cycles.gql
     3. Fan-in to a collector account        queries/03-collector-accounts.gql
     4. Where value leaves the network       queries/04-cash-out.gql

     Run 2 in Kineviz rather than the CLI — a cycle is a shape.

   Cost so far: ~\$0.00 — nothing billable exists. This ran on your hardware.
   Tear down with:  ./gxr down fraud-rings   (drops the database, keeps the deployment)

   Reminder: this deployment stops accepting writes 90 days after you created
   it, and speaks plain text with no TLS. Both are Spanner Omni preview limits.

EOF
