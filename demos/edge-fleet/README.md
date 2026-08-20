# Spanner Omni + Kineviz: blast radius across an edge fleet

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces — the Google Cloud Marketplace listing, the
> `graphxr.kineviz.com` portal, and screenshots in this repo — still show the former name.

## What you'll build

A Spanner property graph of a synthetic edge fleet — sites, the gateways that stand in them,
the devices behind those gateways, the firmware those devices run, and the technicians on call
— running in a **Spanner Omni deployment on your own machine**. Then you use it to answer the
question no single table can: *when one thing fails, what actually goes with it?*

Every finding here needs at least two relationships. A gateway's device count lives in one
table and the site it stands in lives in another. A site's technician roster and its equipment
criticality have nothing to do with each other until you put them side by side. A firmware
advisory names serial numbers; what you can act on is a list of sites.

The third point is *where* it runs. This is the premise Spanner Omni exists for: fleet
telemetry that is not allowed off the premises, or a site that spends most of its life without
a usable uplink. Same engine, same GQL, same schema you would run in a cloud region — on a
container at the edge.

## At a glance

| | |
|---|---|
| **Backend** | Spanner Omni — **pre-GA**, downloadable Spanner |
| **Runs** | A container on your machine. Nothing leaves it |
| **Connection** | Via the database proxy or a CSV export ([how](../../connect/)) |
| **Dataset** | Synthetic, generated locally — 12 sites, 900 devices |
| **Time** | ~12 minutes |
| **Cost** | $0.00. The budget is hardware: 4 vCPU, 16 GB RAM, 20 GB disk |
| **You need** | Docker, Python 3.9+, and a Kineviz account (free for individual use, forever) |

> **Spanner Omni is pre-GA**, under Google's Pre-GA Offerings Terms — development, testing,
> prototyping and demonstration only. **No TLS and no authentication**, and **a deployment
> stops accepting writes 90 days after you create it**. Details in
> [`docs/PREVIEW_NOTES.md`](../../docs/PREVIEW_NOTES.md).

## Architecture

```
        Kineviz Desktop
              │
              │  no native Spanner Omni connector yet —
              │  database proxy, or CSV export. See connect/
              ▼
   FleetGraph  (CREATE PROPERTY GRAPH)
              │
              ▼
   Site · Gateway · Device · Firmware · Technician        ← nodes
   HOSTED_AT · CONNECTED_TO · RUNS · COVERS · DEPENDS_ON  ← edges
              │
              ▼
   database `kineviz-fleet-demo`
              │
              ▼
   Spanner Omni, single-server, in Docker    ← localhost:15000
     project `default`, instance `default`     console on :15026
              │
              │  seeded generator, no network
              ▼
   data/generate.py                          ← synthetic, reproducible
```

`default` for both project and instance is not a placeholder — Spanner Omni fixes those
identifiers, and client libraries have to pass them literally.

## Prerequisites

1. **Docker** — Engine 24.0+ or Docker Desktop. The deployment is a container.
2. **Python 3.9+** — standard library only. It generates the fleet; there is nothing to
   `pip install`. Every database operation goes through the CLI inside the image.
3. **Room to run it** — Spanner Omni wants 4 vCPU, 16 GB RAM and ~20 GB of disk.
4. **A Kineviz account** — [sign up](https://www.kineviz.com/). Free for individual use,
   forever. Only needed at the last step; everything before it runs without one.
5. **Kineviz Desktop v0.17.1+** —
   [releases](https://github.com/Kineviz/kineviz-desktop/releases).

No Google Cloud project, no service account, no IAM. That is the point of Omni.

If you have already run [`../fraud-rings/`](../fraud-rings/), the deployment is already up and
this demo adds a second database beside the first.

## Quick start

```bash
cp .env.example .env      # the defaults work as they stand
../../gxr up edge-fleet
```

## Or do it step by step

**1. Check prerequisites.** Creates nothing.

```bash
./scripts/preflight.sh
```

**2. Start the deployment.** Idempotent — an already-running container is left alone.

```bash
../../gxr omni up
../../gxr omni status
```

**3. Generate the fleet.** Seeded, so the same numbers always produce the same graph —
including the fragilities the queries find.

```bash
set -a; . .env; set +a
python3 data/generate.py --out data/generated --seed "$FLEET_SEED" \
  --sites "$FLEET_SITES" --devices "$FLEET_DEVICES"
```

It prints the fragility it planted, so you know what the queries should surface. The output is
one headerless CSV per table plus a `csv-export.json` manifest — the layout Spanner's own bulk
import expects.

**4. Create the database and apply the schema.**

```bash
S="docker exec -i spanneromni /google/spanner/bin/spanner"

$S databases create "$OMNI_DATABASE"

# --ddl-file is read on the *server's* filesystem — inside the container for a
# container deployment. Copy it in first.
docker cp sql/01_schema.ddl spanneromni:/tmp/kineviz/01_schema.ddl
$S databases ddl update "$OMNI_DATABASE" --ddl-file=/tmp/kineviz/01_schema.ddl
```

[`sql/01_schema.ddl`](sql/01_schema.ddl) creates ten tables and the `FleetGraph` property
graph over them. Note there is no `--instance` flag: the Spanner Omni CLI does not take one.

**5. Load the rows** with Spanner's own CSV import.

```bash
docker cp data/generated spanneromni:/tmp/kineviz/data
$S databases import "$OMNI_DATABASE" --url="file:///tmp/kineviz/data" --format=csv
```

Import is asynchronous; it prints an operation name to poll with
`$S operations describe --database="$OMNI_DATABASE" <op>`.

> On `2026.r1-beta.2` that operation finishes reporting *"A step can generate output only if
> it's not a cleanup step…"* on a load that in fact wrote every row. Preview bookkeeping
> leaking out. `setup.sh` downgrades exactly that message to a warning and then counts rows.

**6. Verify.**

```bash
./scripts/verify.sh
```

It asserts two things, not one: that a concentration gateway exists **and** that it carries
more than twice what the runner-up does. A "busiest" gateway that is merely joint-first would
make the walkthrough read as wrong.

## Connect Kineviz

The walkthrough is in **[`connect/`](../../connect/)** — the same flow for every demo here, so
it's documented once. Read it before you start: Spanner Omni is not reachable by Kineviz's
native Spanner connector, and `connect/` is where the two routes that do work are written
down.

Values for this demo:

| Field | Value |
|---|---|
| Endpoint | `localhost:15000` (plain text, no TLS) |
| Project / Instance | `default` / `default` — fixed by Spanner Omni |
| Database | `kineviz-fleet-demo` |
| Graph | `FleetGraph` |

## Explore

Four questions, in [`queries/`](queries/). **Run `01` then `04`** — that pair is the argument
for using a graph rather than a spreadsheet of device counts.

**1. What goes dark if one gateway fails?** — [`01-blast-radius.gql`](queries/01-blast-radius.gql)

One gateway carries roughly triple what the next one does. In a real fleet, that row is the
one you buy a spare for.

**2. Which sites have one technician and equipment that matters?** —
[`02-lone-cover.gql`](queries/02-lone-cover.gql)

The staffing roster knows the first number; the asset register knows the second. Neither knows
the pair, and the pair is the finding.

**3. Which sites still run firmware under advisory?** —
[`03-advisory-exposure.gql`](queries/03-advisory-exposure.gql)

A scanner gives you serial numbers. This gives you places to send someone. **Run it in
Kineviz**: whether the exposure is concentrated or smeared across the fleet is a shape, and
they are different problems.

**4. The blast radius query 1 missed** — [`04-cascade.gql`](queries/04-cascade.gql)

Devices depend on each other, so losing one takes down whatever depends on it, and whatever
depends on that. `-[:DEPENDS_ON]->{1,4}` is a variable-length quantifier — and it is bounded on
purpose, because control dependencies acquire cycles the moment someone wires a mutual
interlock.

### What you should find

Seeded, so these are reproducible rather than lucky:

- **One concentration gateway** carrying ~129 of 900 devices, against ~37 for the next busiest.
- **One site with a single technician on call** and a double-figure count of high-criticality
  devices behind them.
- **A firmware build under `KEV-2026-0031`** still running on devices at a dozen different
  sites — exposure spread thin, which is a harder problem than exposure concentrated.
- **A four-hop dependency chain** ending on a device attached to the concentration gateway, so
  the true radius of that gateway is larger than query 1 suggests.

## How the graph is modeled

| Node label | Table | Key | Properties |
|---|---|---|---|
| `Site` | `Site` | `id` | `name`, `region`, `opened_date` |
| `Gateway` | `Gateway` | `id` | `model`, `installed_date` |
| `Device` | `Device` | `id` | `kind`, `serial`, `criticality` |
| `Firmware` | `Firmware` | `id` | `version`, `released_date`, `advisory` |
| `Technician` | `Technician` | `id` | `name`, `certification` |

| Edge label | From → To | Table | Properties |
|---|---|---|---|
| `HOSTED_AT` | `Gateway` → `Site` | `HostedAt` | `rack` |
| `CONNECTED_TO` | `Device` → `Gateway` | `ConnectedTo` | `port` |
| `RUNS` | `Device` → `Firmware` | `RunsFirmware` | `applied_date` |
| `COVERS` | `Technician` → `Site` | `Covers` | `since_date` |
| `DEPENDS_ON` | `Device` → `Device` | `DependsOn` | `reason` |

**Edge labels are declared explicitly and differ from the table names** — `ConnectedTo` the
table, `CONNECTED_TO` the label. GQL wants the label. That mismatch is the most common Spanner
Graph error, so [`connect/verify.sh`](../../connect/verify.sh) prints the real labels for any
graph.

`DEPENDS_ON` is the only self-referencing edge, and the only one worth walking with a
quantifier. The others are single hops by construction: a device has exactly one gateway, a
gateway exactly one site.

### Pointing this at real data

Replace the ten tables with your own CMDB, asset register or network inventory and adjust the
`CREATE PROPERTY GRAPH` at the bottom of `sql/01_schema.ddl`. The queries reference only labels
and properties, so they carry over as long as the shape does: things, the things they hang off,
the software they run, and the people responsible.

Because this is Spanner Omni, "real data" can mean data that is not allowed to leave the site.
The schema and the queries are unchanged if you later consolidate into managed Spanner.

## Troubleshooting

**`docker: Cannot connect to the Docker daemon`**

The deployment is a container. `open -a Docker` on macOS, `sudo systemctl start docker` on
Linux.

**The first `gxr omni up` takes minutes**

It is pulling ~1 GB. Later starts take seconds.

**`failed to build statement: invalid statement` on a query that looks fine**

Two causes, both in the CLI's `--sql` handling rather than in your SQL: it rejects `--` comment
lines, and it rejects a statement whose **first line is indented**. Indented continuation lines
are fine. `shared/lib/omni.sh` strips both, so this only bites when you call the CLI by hand.

**`Failed to find element label [X]`**

Edge labels are not table names. [`connect/verify.sh`](../../connect/verify.sh) lists the real
ones.

**Query 04 hangs or returns far more than you expect**

Check the quantifier bound. `-[:DEPENDS_ON]->{1,4}` is bounded deliberately; raising it on a
graph with a dependency cycle is how you get a walk that does not terminate.

**Verify says "No concentration gateway"**

`generate.py` plants one at roughly triple the runner-up. If it is missing, the generator and
the schema have drifted apart — that's a bug, please open an issue.

**Writes start failing after a while**

Check how old the deployment is. Spanner Omni stops accepting writes 90 days after creation.
`./gxr omni destroy --all` then `./gxr omni up`, and re-run.

## Clean up

```bash
../../gxr down edge-fleet
```

Drops the database and deletes the generated CSVs. **It does not remove the container or the
volume** — the volume holds every database on the deployment, including `fraud-rings` and
anything you built yourself.

To remove the deployment entirely, which is a separate and deliberate act:

```bash
../../gxr omni destroy --all      # container AND volume — every database goes
```

## What's next

- [`connect/`](../../connect/) — get this graph onto the Kineviz canvas
- [`../fraud-rings/`](../fraud-rings/) — the other demo here, on synthetic payments
- [Spanner Omni docs](https://docs.cloud.google.com/spanner-omni/setup) ·
  [Spanner Graph](https://docs.cloud.google.com/spanner/docs/graph/overview)
- [`spanner-kineviz-examples`](https://github.com/Kineviz/spanner-kineviz-examples) — the same
  patterns against managed Spanner
