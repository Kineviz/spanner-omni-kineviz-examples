#!/usr/bin/env bash
# Everything above was automatable. Everything below is the person's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=handoff
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env "$DEMO_DIR"
top=$(cat "$DEMO_DIR/.verified_rows" 2>/dev/null || echo "?")
desktop="not detected"; kineviz_desktop_installed && desktop="detected"

cat <<EOF

✅ Demo ready: edge-fleet
   Kineviz (formerly GraphXR) · Spanner Omni

   Deployment: ${OMNI_CONTAINER} at $(omni_endpoint)   (yours; not deleted by teardown)
   Console:    $(omni_console_url)   (read-only in preview)
   Database:   ${OMNI_DATABASE}   (synthetic, ${FLEET_SITES} sites, ${FLEET_DEVICES} devices, seed ${FLEET_SEED})
   Graph:      ${OMNI_GRAPH}
                 Site · Gateway · Device · Firmware · Technician
                 HOSTED_AT · CONNECTED_TO · RUNS · COVERS · DEPENDS_ON
   Verified:   busiest gateway carries ${top} devices
   Desktop:    ${desktop}

   Query it right now, without Kineviz:
     ./gxr omni sql ${OMNI_DATABASE}
     ../../connect/verify.sh --database ${OMNI_DATABASE} --graph ${OMNI_GRAPH}

   Last step — connect Kineviz. Spanner Omni has no native Kineviz connector
   yet, so pick a route in ../../connect/README.md:
     · database proxy — live GQL from the canvas, one small driver change
     · CSV export     — works today with no patching, static snapshot

   Then try:
     1. What goes dark if one gateway fails    queries/01-blast-radius.gql
     2. Sites with one technician and high-criticality kit
                                               queries/02-lone-cover.gql
     3. Which sites run firmware under advisory
                                               queries/03-advisory-exposure.gql
     4. The transitive tail query 1 misses     queries/04-cascade.gql

     Run 3 in Kineviz rather than the CLI — whether the exposure is concentrated
     or smeared across the fleet is a shape, and they are different problems.

   Cost so far: ~\$0.00 — nothing billable exists. This ran on your hardware.
   Tear down with:  ./gxr down edge-fleet   (drops the database, keeps the deployment)

   Reminder: this deployment stops accepting writes 90 days after you created
   it, and speaks plain text with no TLS. Both are Spanner Omni preview limits.

EOF
