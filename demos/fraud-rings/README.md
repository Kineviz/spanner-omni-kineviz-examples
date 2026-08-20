# Spanner Omni + Kineviz: fraud rings in P2P payments

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces — the Google Cloud Marketplace listing, the
> `graphxr.kineviz.com` portal, and screenshots in this repo — still show the former name.

## What you'll build

A Spanner property graph of synthetic peer-to-peer payments — accounts, the devices they
sign in from, transfers between them, and merchant payments — running in a **Spanner Omni
deployment on your own machine**. Then you use it to find fraud rings: accounts that share
a device **and** move money between themselves.

The point is the pairing. A shared device on its own is a weak signal — families share
tablets, and this dataset contains one such family on purpose so you can watch a
device-only rule produce a false positive that the graph query correctly ignores.

The second point is *where* it runs. This is the same Spanner Graph engine and the same GQL
you would run in Google Cloud, on a container on your laptop, with no project, no billing
account, and no request leaving the host. If the reason you have not tried Spanner Graph is
that payments data cannot go to someone else's cloud, this is the demo for you.

## At a glance

| | |
|---|---|
| **Backend** | Spanner Omni — **pre-GA**, downloadable Spanner |
| **Runs** | A container on your machine. Nothing leaves it |
| **Connection** | Via the database proxy or a CSV export ([how](../../connect/)) |
| **Dataset** | Synthetic, generated locally — nothing to download |
| **Time** | ~15 minutes, most of it the first image pull |
| **Cost** | $0.00. The budget is hardware: 4 vCPU, 16 GB RAM, 20 GB disk |
| **You need** | Docker, Python 3.9+, and a Kineviz account (free for individual use, forever) |

> **Spanner Omni is pre-GA**, under Google's Pre-GA Offerings Terms — development, testing,
> prototyping and demonstration only. Two limits matter here: **the preview build has no
> TLS**, so keep the endpoint on a network you trust, and **a deployment stops accepting
> writes 90 days after you create it**. Details in [`docs/PREVIEW_NOTES.md`](../../docs/PREVIEW_NOTES.md).

## Architecture

```
        Kineviz Desktop
              │
              │  no native Spanner Omni connector yet —
              │  database proxy, or CSV export. See connect/
              ▼
   FraudGraph  (CREATE PROPERTY GRAPH)
              │
              ▼
   Client · Device · Merchant                ← nodes
   UsedDevice · Paid · PaidMerchant          ← edges
              │
              ▼
   database `kineviz-fraud-demo`
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
2. **Python 3.9+** — standard library only. It generates the synthetic data; there is
   nothing to `pip install`. Every database operation goes through the CLI inside the image.
3. **Room to run it** — Spanner Omni wants 4 vCPU, 16 GB RAM and ~20 GB of disk. On a
   smaller machine it will start and then behave badly under load.
4. **A Kineviz account** — [sign up](https://www.kineviz.com/). Kineviz Desktop is **free
   for individual use, forever**, but the app requires sign-in. Only needed at the last step;
   everything before it runs without one.
5. **Kineviz Desktop v0.17.1+** —
   [releases](https://github.com/Kineviz/kineviz-desktop/releases). ~600 MB installed.

There is no Google Cloud project, no service account, and no IAM to arrange. That is the
whole point of Omni.

## Quick start

```bash
cp .env.example .env      # the defaults work as they stand
../../gxr up fraud-rings
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

Under the hood that is Google's documented setup, with one change: on macOS and Windows the
port range is published rather than using `--network host`, because the engine runs in a VM
there and host networking does not reach the host's loopback.

```bash
docker volume create spanner
docker run -d -p 15000-15026:15000-15026 --name spanneromni -v "spanner:/spanner" \
  us-docker.pkg.dev/spanner-omni/images/spanner-omni:2026.r1-beta.2 start-single-server
```

**3. Generate the payments.** Seeded, so the same numbers always produce the same graph —
including the rings the queries find.

```bash
set -a; . .env; set +a
python3 data/generate.py --out data/generated --seed "$FRAUD_SEED" \
  --clients "$FRAUD_CLIENTS" --transactions "$FRAUD_TRANSACTIONS" --days "$FRAUD_DAYS"
```

It prints the findings it planted, so you know what the queries should surface. The output is
one headerless CSV per table plus a `csv-export.json` manifest — exactly the layout Spanner's
own bulk import expects.

**4. Create the database and apply the schema.**

```bash
S="docker exec -i spanneromni /google/spanner/bin/spanner"

$S databases create "$OMNI_DATABASE"

# --ddl-file is read on the *server's* filesystem, which for a container
# deployment means inside the container. Copy it in first.
docker cp sql/01_schema.ddl spanneromni:/tmp/kineviz/01_schema.ddl
$S databases ddl update "$OMNI_DATABASE" --ddl-file=/tmp/kineviz/01_schema.ddl
```

[`sql/01_schema.ddl`](sql/01_schema.ddl) creates six tables and the `FraudGraph` property
graph over them. Note there is no `--instance` flag: the Spanner Omni CLI does not take one.

**5. Load the rows** with Spanner's own CSV import — no client library, no DML size limits.

```bash
docker cp data/generated spanneromni:/tmp/kineviz/data
$S databases import "$OMNI_DATABASE" --url="file:///tmp/kineviz/data" --format=csv
```

Import is asynchronous; it prints an operation name to poll with
`$S operations describe --database="$OMNI_DATABASE" <op>`.

> On `2026.r1-beta.2` that operation finishes reporting *"A step can generate output only if
> it's not a cleanup step…"* on a load that in fact wrote every row. It is preview
> bookkeeping leaking out. `setup.sh` downgrades exactly that message to a warning and then
> counts rows, which is the check that actually means something.

**6. Verify.**

```bash
./scripts/verify.sh
```

This runs the demo's *headline* query, not a trivial smoke test. If no shared devices come
back, the graph works but the demo is pointless — so that counts as a failure.

## Connect Kineviz

The walkthrough is in **[`connect/`](../../connect/)** — the same flow for every demo here,
so it's documented once. Read it before you start: Spanner Omni is not reachable by
Kineviz's native Spanner connector, and `connect/` is where the two routes that do work are
written down.

Values for this demo:

| Field | Value |
|---|---|
| Endpoint | `localhost:15000` (plain text, no TLS) |
| Project / Instance | `default` / `default` — fixed by Spanner Omni |
| Database | `kineviz-fraud-demo` |
| Graph | `FraudGraph` |

## Explore

Four questions, in [`queries/`](queries/). **Run `01` then `02`** — that pair is the whole
argument for using a graph here.

**1. Which accounts share a device?** — [`01-shared-devices.gql`](queries/01-shared-devices.gql)

Three devices come back. One of them is innocent.

**2. Which of those also move money between themselves?** —
[`02-money-cycles.gql`](queries/02-money-cycles.gql)

Two devices survive. The family drops out — that's the false positive a shared-device list
would have handed an investigator. **Run this one in Kineviz**: a cycle is a shape.

**3. Which account is the fan-in point?** —
[`03-collector-accounts.gql`](queries/03-collector-accounts.gql)

The mule. Where 02 finds the ring, this finds the account worth freezing first.

**4. Where does the value leave?** — [`04-cash-out.gql`](queries/04-cash-out.gql)

Large merchant payments. Note the account here is the same one query 03 named — the
collector cashes out.

### What you should find

Seeded, so these are reproducible rather than lucky:

- **A ring of 4 accounts** sharing one device, moving ~$9,200 in a closed cycle and skimming
  a little at each hop. No account looks unusual alone.
- **A ring of 3 accounts** sharing a device and fanning money into a **fourth collector
  account**, which then makes one large gaming-merchant payment.
- **A family of 3 accounts** sharing a tablet with **no transfers between them** — present on
  purpose, and the reason to use a graph rather than a shared-device rule.

## How the graph is modeled

| Node label | Table | Key | Properties |
|---|---|---|---|
| `Client` | `Client` | `id` | `name`, `email`, `opened_date`, `risk_tier` |
| `Device` | `Device` | `id` | `kind`, `first_seen` |
| `Merchant` | `Merchant` | `id` | `name`, `category` |

| Edge label | From → To | Table | Properties |
|---|---|---|---|
| `USED_DEVICE` | `Client` → `Device` | `UsedDevice` | `first_used` |
| `PAID` | `Client` → `Client` | `Paid` | `tx_id`, `amount`, `ts` |
| `PAID_MERCHANT` | `Client` → `Merchant` | `PaidMerchant` | `tx_id`, `amount`, `ts` |

**Edge labels are declared explicitly and differ from the table names** — `UsedDevice` the
table, `USED_DEVICE` the label. GQL wants the label. That mismatch is the most common Spanner
Graph error, so [`connect/verify.sh`](../../connect/verify.sh) prints the real labels for any
graph.

### Pointing this at real data

Replace the six tables with your own and adjust the `CREATE PROPERTY GRAPH` at the bottom of
`sql/01_schema.ddl`. The queries only reference labels and properties, so they carry over as
long as the shape does: accounts, a shared-identity signal, and transfers.

Because this is Spanner Omni, "real data" can mean data that is not allowed to leave your
network. The schema and the queries are unchanged if you later move to managed Spanner —
same engine, same dialect.

## Troubleshooting

**`docker: Cannot connect to the Docker daemon`**

The deployment is a container, so Docker has to be running first. On macOS, `open -a Docker`
and wait for the whale to settle; on Linux, `sudo systemctl start docker`.

**The first `gxr omni up` takes minutes**

It is pulling ~400 MB. Subsequent runs start in seconds. `docker logs spanneromni` shows
progress.

**`connection refused` on localhost:15000 right after the container starts**

The container reports itself up before the servers finish electing. `omni_wait_ready` polls
for you; if you are driving Docker by hand, give it 20–30 seconds.

**Port 15000 is already in use**

Something else has it. Change `OMNI_PORT` in `.env` and re-run — the whole range
`OMNI_PORT`–`OMNI_CONSOLE_PORT` gets published.

**`failed to build statement: invalid statement` on a query that looks fine**

Two causes, both in the CLI's `--sql` handling rather than in your SQL. It rejects `--`
comment lines, and it rejects a statement whose **first line is indented** — indented
continuation lines are fine. Writing a query as an indented shell heredoc hits the second one
every time. `shared/lib/omni.sh` strips both before sending, so this only bites when you call
the CLI by hand.

**`Failed to find element label [X]`**

Edge labels are not table names. Run [`connect/verify.sh`](../../connect/verify.sh), which
lists the real ones.

**`Syntax error: Unexpected keyword AT`**

`AT` is reserved in Spanner GQL. Don't alias a column `AS at` — these queries use
`occurred_at`.

**Writes start failing after a while**

Check how old the deployment is. Spanner Omni stops accepting writes 90 days after a
deployment is created — a preview limitation, not a bug. Recreate it with
`./gxr omni destroy --all` followed by `./gxr omni up`, then re-run this demo.

**`verify.sh` finds no shared devices**

Shouldn't happen — the data is seeded. If it does, `data/generate.py` and the schema have
drifted apart. That's a bug; please open an issue.

## Clean up

```bash
../../gxr down fraud-rings
```

Drops the database and deletes the generated CSVs. **It does not remove the container or the
volume** — the volume holds every database on the deployment, including any you built
yourself, so throwing it away to clean up one demo is not teardown's call.

To remove the deployment entirely, which is a separate and deliberate act:

```bash
../../gxr omni destroy --all      # container AND volume — every database goes
```

## What's next

- [`connect/`](../../connect/) — get this graph onto the Kineviz canvas
- [`../edge-fleet/`](../edge-fleet/) — the other demo here, on a fleet Omni is built for
- [Spanner Omni docs](https://docs.cloud.google.com/spanner-omni/setup) ·
  [Spanner Graph](https://docs.cloud.google.com/spanner/docs/graph/overview)
- [`spanner-kineviz-examples`](https://github.com/Kineviz/spanner-kineviz-examples) — the
  same demo against managed Spanner, if you would rather Google ran it
