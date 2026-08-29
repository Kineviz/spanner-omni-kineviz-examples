# The stream

`./gxr up` builds the graph in one shot and it never moves again. That is right
for a demo you query and wrong for one you watch. This replays the same 12,033
transactions through Kafka on compressed time, so the graph fills while someone
is looking at it — and the Kineviz dashboard's numbers climb on their own.

```
transactions.csv ──▶ producer ──▶ Kafka ──▶ sink ──▶ Spanner Omni ──▶ proxy ──▶ Kineviz
                    (paced)     (3 parts)  (3 rows      (host)                  Dashboard
                                            per event)                          (2s poll)
```

## Run it

```bash
./gxr up paysim-schemaless        # once: schema, actors, and the CSV to replay
./gxr connect up paysim-schemaless
./gxr stream up paysim-schemaless # ~2 minutes of replay
./gxr stream status               # watches it fill, live
./gxr stream down
```

`stream status` on a terminal redraws in place until the replay drains:

```
  paysim.transactions -> Kafka -> Spanner Omni   replaying
  landed   █████████████████░░░░░░░  8619 / 12033  71%
  106 tx/s · ~32s left · 0 behind the topic
```

Ctrl-C stops watching, not the replay. Piped output, `--json` and `--once` get
the old single snapshot instead — containers, topic offsets, consumer lag and
the landed count — so scripts and CI see what they always did.

`stream up` clears the transactions before replaying, because the batch load
already wrote them and a replay the sink deduplicates is a demo where nothing
happens. `--keep` skips the clear, which is how you demonstrate the idempotency
instead: same replay, same primary keys, count never wavers.

**Actors are never touched.** Clients, merchants, banks and identifiers stay as
`up` loaded them. What clears and refills is the fact stream — ~12k
`:transaction` nodes and the ~24k edges hanging off them, 88% of the graph.

## Running with no network

Everything this stack *runs* is local. Everything it *builds* is not: the
Dockerfiles start from `python:3.12-slim` and pip install, so a first build wants
docker.io and PyPI. Do that once, while you have a network:

```bash
./gxr offline prepare        # pull the images, build producer and sink
./gxr offline check          # what still needs a network, if anything
```

After that `./gxr stream up` starts disconnected. It builds only when the images
are missing or the source has changed — each image carries a `gxr.srchash` label
recording the build context it came from, so "already built from this source" is a
local question with a local answer. `./gxr up` and `./gxr connect up` make no
network calls of their own once the proxy checkout exists.

Edit `sink.py` with no network and the stack still starts, saying plainly that the
running code is older than the source. That beats the alternative, which is
debugging code that is not the code you are reading.

## What lands, per transaction

Three rows, one commit:

| table | key | label |
|---|---|---|
| `GraphNode` | `transaction_T000123` | `transaction` |
| `GraphEdge` | `client_C0115` → `transaction_T000123` | `performs` |
| `GraphEdge` | `transaction_T000123` → `merchant_M025` | `to_merchant` / `to_client` / `to_bank` |

The ids, labels and property names are the ones
[`data/generate.py`](../demos/paysim-schemaless/data/generate.py) writes in the
batch path — same `label_key` ids, same lowercase labels, same rounded amount. A
streamed row and a batch-loaded row are the same row, which is why `verify.sh`
still passes after a replay and why replaying twice changes nothing.

## Why this shape

**Kafka**, because the requirement was a buffer with replay that fans out to more
than one consumer. The database sink is the only consumer today; the point is
that adding a second one — an algorithm server, a second store — does not touch
the producer. Apache-2.0, and since 4.0 removed ZooKeeper, genuinely one
container.

**At-least-once, deduplicated by the primary key.** The sink commits to Spanner
and *then* commits the Kafka offsets. Crash in between and the batch is
redelivered; `insert_or_update` makes the replay a no-op. Spanner has no
`ON CONFLICT`, and mutations are both cheaper than DML and idempotent by
construction, so the key does the work either way. No exactly-once machinery.

**Mutations, not DML.** Three `INSERT OR UPDATE` statements per event would mean
query planning on each. `batch.insert_or_update` sends rows: no SQL parsed, one
commit for the batch, retry semantics for free.

**The deployment is not a service here.** Spanner Omni is longer-lived than any
streaming session, it belongs to `./gxr omni`, and it may hold other people's
databases. The sink reaches it on the host at `host.docker.internal:15000`;
nothing in this stack starts, stops or removes it.

**No HTML dashboard.** The sibling Postgres repo serves its own page on :8090.
Here the panel is Kineviz's own Dashboard — see
[`../demos/paysim-schemaless/kineviz/`](../demos/paysim-schemaless/kineviz/).

## Ports

Deliberately not the Postgres repo's, so both stacks run on one laptop:

| | this repo | Kineviz/pg-kineviz-examples |
|---|---|---|
| compose project | `paysim-schemaless-stream` | `paysim-stream` |
| Kafka | 9094 | 9092 |
| Kafka UI | 8084 | 8082 |

The Kafka UI (`STREAM_UI=off` to skip it) is for looking at the pipe itself:
topics, partitions, consumer lag. It never touches Spanner.

## Pacing

`STREAM_HOUR_SECONDS=0.167` (the default) means one simulated hour per 0.167
wall seconds. The dataset spans ~720 simulated hours, so all 30 days replay in
**about two minutes** — long enough to watch the graph fill, short enough to sit
through twice. The producer sleeps until each row is *due* rather than a fixed
amount per row, so quiet stretches still emit nothing for a beat and fraud still
arrives in bursts, just closer together. That beat is the point; a flat rate
flattens it away.

Raise it to stretch the demo out — `STREAM_HOUR_SECONDS=2.5` gives the leisurely
half hour, a simulated day per wall minute.

`STREAM_RATE=<n>` for flat tx/s instead. `STREAM_HOUR_SECONDS=0` for no pacing at
all, which is what you want when you are testing rather than presenting.

## When it looks broken

**"Timed out waiting for a node assignment"** — an admin client bootstrapped on
`localhost:9092` inside the broker container. Kafka hands back the *advertised*
address for that listener, `localhost:9094`, and nothing listens there inside the
container. Everything here bootstraps on `broker:29092` for that reason.

**The sink logs "database ... does not exist yet"** — not an error, a queue. Run
`./gxr up paysim-schemaless`; the sink picks up where it left off.

**The sink logs a write refusal** — a Spanner Omni deployment stops accepting
writes 90 days after it was created. See [`../docs/PREVIEW_NOTES.md`](../docs/PREVIEW_NOTES.md).

**`stream status` shows produced climbing and landed flat** — the sink is down or
cannot reach Omni. `docker compose -p paysim-schemaless-stream logs sink`.
