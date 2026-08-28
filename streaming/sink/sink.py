#!/usr/bin/env python3
"""Land Kafka transactions in a SCHEMALESS Spanner Omni graph, as they arrive.

Each transaction becomes three rows, written in ONE commit:

    GraphNode  transaction_T000123          label 'transaction'
    GraphEdge  client_C0115 -> transaction_T000123      label 'performs'
    GraphEdge  transaction_T000123 -> merchant_M025     label 'to_merchant'

The ids, the labels and the property names are not invented here. They are the
same ones demos/paysim-schemaless/data/generate.py writes in the batch path, so
a streamed row and a batch-loaded row are the SAME row, down to the primary key.
Two things follow from that, and both are load-bearing:

  * replaying onto a full database changes nothing — that is the idempotency
    `./gxr stream up --keep` demonstrates;
  * verify.sh still passes after a replay, because the graph it asserts on is
    the graph the batch path would have built.

AT-LEAST-ONCE, WITHOUT DUPLICATES

    1. commit the batch to Spanner
    2. only then commit the Kafka offsets

Crash between 1 and 2 and the batch is redelivered. `insert_or_update` makes the
replay a no-op: same primary key, same values, so the second write is the first
write. That is this sink's version of the `ON CONFLICT DO NOTHING` the Postgres
sibling relies on — Spanner has no ON CONFLICT, and mutations are both cheaper
than DML and idempotent by construction, so the primary key does the work either
way. No exactly-once machinery.

WHY MUTATIONS AND NOT DML

`INSERT ... ON CONFLICT` does not exist in GoogleSQL, and `INSERT OR UPDATE` as
DML would mean building 3 statements per event and paying query-planning on each.
`batch.insert_or_update` sends the rows as mutations: no SQL parsed, one commit
for the whole batch, and the retry semantics come for free.

ORDERING IS NOT A CORRECTNESS PROBLEM, EXCEPT WHERE IT IS

GraphEdge is INTERLEAVE IN PARENT GraphNode, so an edge's SOURCE node must exist
when the edge lands. Both parents always do:

  * `performs` hangs off the client node, which the batch path seeded — a stream
    against an empty database would break here, which is exactly why
    `./gxr stream up` clears only the transactions and never the actors;
  * `to_*` hangs off the transaction node, written in the same commit.

The DESTINATION is not a parent and is not checked, so a receiver arriving late
would not break the write. It never happens here — every actor is seeded — but
it is why the sink does not sort or buffer.
"""

import json
import os
import signal
import sys
import time

from confluent_kafka import Consumer, KafkaError, KafkaException
from google.api_core import exceptions as gexc
from google.cloud import spanner

BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "broker:29092")
TOPIC = os.environ.get("KAFKA_TOPIC", "paysim.transactions")
GROUP = os.environ.get("KAFKA_GROUP", "paysim-schemaless-sink")

# Project and instance are fixed by Spanner Omni — both are the literal string
# "default", whatever your GCP project is called. See connect/proxy/
# spanner_omni_driver.py, which says the same thing at more length.
OMNI_PROJECT = "default"
OMNI_INSTANCE = "default"
OMNI_HOST = os.environ.get("OMNI_HOST", "host.docker.internal")
OMNI_PORT = os.environ.get("OMNI_PORT", "15000")
DATABASE = os.environ.get("OMNI_DATABASE", "kineviz-paysim-demo")

BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "200"))
FLUSH_MS = int(os.environ.get("FLUSH_MS", "1000"))

running = True


def _stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def connect_spanner():
    """Build a client for Spanner Omni: no auth, no TLS, fixed project/instance.

    `use_plain_text=True` is not optional — without it the client insists on TLS
    and fails with "TLS/mTLS connection requires ca_certificate to be set for
    Spanner Omni", and the preview build serves no TLS at all.

    Google's Omni docs still show `experimental_host=`; on client 3.69 that
    emits a DeprecationWarning pointing at `client_options` + `instance_type`.
    Try the current form first and fall back, same as the proxy driver does.
    """
    endpoint = f"{OMNI_HOST}:{OMNI_PORT}"
    while running:
        try:
            try:
                client = spanner.Client(
                    project=OMNI_PROJECT,
                    client_options={"api_endpoint": endpoint},
                    instance_type="omni",
                    use_plain_text=True,
                )
            except TypeError:           # client 3.65-3.68: no instance_type
                client = spanner.Client(
                    project=OMNI_PROJECT,
                    experimental_host=endpoint,
                    use_plain_text=True,
                )
            db = client.instance(OMNI_INSTANCE).database(DATABASE)
            # Cheap round trip: prove the endpoint answers and the database
            # exists before the first batch, so a typo fails here and not
            # halfway through a replay.
            with db.snapshot() as snap:
                list(snap.execute_sql("SELECT 1"))
            print(f"connected to Spanner Omni at {endpoint}, database {DATABASE}",
                  flush=True)
            return db
        except Exception as e:
            print(f"Spanner Omni not ready at {endpoint} ({e}); retrying in 5s — "
                  "is it up? ./gxr omni status", flush=True)
            time.sleep(5)
    sys.exit(0)


def money2(x):
    """Round to cents before it becomes JSON.

    Spanner rejects JSON numbers that cannot round-trip through their string
    form, so `JSON'{"amount": 286954.5962}'` is an error rather than a value.
    generate.py:91 does exactly this for the batch path; the streamed row has to
    match it or the two would not be the same row.
    """
    return round(float(x), 2)


def event_to_rows(e):
    """One transaction -> (GraphNode row, [GraphEdge rows]).

    Mirrors generate.py's build step. Labels and property names are LOWERCASE
    because Spanner requires schemaless label values to be stored lowercase —
    matching is case-insensitive, storage is not.
    """
    gs = e["global_step"]
    tx = f"transaction_T{gs:06d}"

    node = (tx, "transaction", json.dumps({
        "amount": money2(e["amount"]),
        "timestamp": e["ts"],
        "action": e["action"],
        "globalstep": gs,
        "isfraud": bool(e["is_fraud"]),
        "isflaggedfraud": bool(e["is_flagged_fraud"]),
        "typeorig": e["sender_type"],
        "typedest": e["receiver_type"],
    }))

    rtype = e["receiver_type"]
    if rtype == "MERCHANT":
        dest, label = f"merchant_{e['receiver_id']}", "to_merchant"
    elif rtype == "BANK":
        dest, label = f"bank_{e['receiver_id']}", "to_bank"
    else:                       # CLIENT or MULE — both are client nodes
        dest, label = f"client_{e['receiver_id']}", "to_client"

    props = json.dumps({"timestamp": e["ts"]})
    edges = [
        (f"client_{e['sender_id']}", tx, f"p{gs}", "performs", props),
        (tx, dest, f"t{gs}", label, props),
    ]
    return node, edges


def flush(db, batch, final=False):
    """Write one batch in a single commit. Returns (db, wrote).

    Retries a lost connection forever while we are running. Anything that is not
    a transient connection problem is left to crash: the Kafka offsets were never
    committed, compose restarts us, and the batch is redelivered. Failing loudly
    beats landing a half-graph quietly.

    `wrote` exists because the caller must not commit offsets for a batch that
    never landed. On SIGTERM the retry loop stops, and a flush that gave up has
    to be distinguishable from one that succeeded — otherwise shutting the sink
    down mid-batch would acknowledge messages it dropped, which is precisely the
    data loss the commit ordering exists to prevent.

    `final=True` is the last attempt on the way out: it runs once, with `running`
    already false, and does not retry.
    """
    nodes, edges = [], []
    for e in batch:
        n, es = event_to_rows(e)
        nodes.append(n)
        edges.extend(es)

    while running or final:
        try:
            with db.batch() as b:
                # Nodes first: GraphEdge is interleaved in GraphNode, so the
                # transaction node has to exist before its to_* edge. Both land
                # in the same commit, but the order within it still matters.
                b.insert_or_update(
                    table="GraphNode",
                    columns=("id", "label", "properties"),
                    values=nodes,
                )
                b.insert_or_update(
                    table="GraphEdge",
                    columns=("id", "dest_id", "edge_id", "label", "properties"),
                    values=edges,
                )
            return db, True
        except (gexc.ServiceUnavailable, gexc.DeadlineExceeded) as e:
            if final:
                raise
            print(f"Spanner Omni unreachable ({e}); reconnecting", flush=True)
            db = connect_spanner()
        except gexc.NotFound:
            if final:
                raise
            # The database or the tables are not there yet. Not an error — a
            # queue. setup.sh may still be applying the DDL.
            print(f"database {DATABASE} or its tables do not exist yet — run "
                  "'./gxr up paysim-schemaless'; retrying in 5s", flush=True)
            time.sleep(5)
        except gexc.PermissionDenied as e:
            # The 90-day preview write window. Worth its own message, because
            # "permission denied" on a database with no auth reads as nonsense.
            sys.exit(f"Spanner Omni refused the write ({e}). If this deployment "
                     "is more than 90 days old it has passed the preview write "
                     "window — see docs/PREVIEW_NOTES.md")
    # Shutting down before the write went through. The offsets stay uncommitted,
    # so the next start replays this batch.
    return db, False


def main():
    db = connect_spanner()
    consumer = Consumer({
        "bootstrap.servers": BOOTSTRAP,
        "group.id": GROUP,
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,     # offsets commit AFTER the Spanner commit
        # A hard-killed consumer holds its partitions until the broker times out
        # its session — 45s by default, which reads as "the pipeline broke" in a
        # live demo. 10s keeps crash-recovery snappy.
        "session.timeout.ms": 10000,
    })
    consumer.subscribe([TOPIC])
    print(f"consuming {TOPIC} as group {GROUP}", flush=True)

    batch, landed, last_flush = [], 0, time.monotonic()
    while running:
        msg = consumer.poll(0.2)
        if msg is not None:
            if msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    raise KafkaException(msg.error())
            else:
                try:
                    batch.append(json.loads(msg.value()))
                except (json.JSONDecodeError, TypeError) as e:
                    print(f"skipping undecodable message: {e}", file=sys.stderr)

        overdue = (time.monotonic() - last_flush) * 1000 >= FLUSH_MS
        if batch and (len(batch) >= BATCH_SIZE or overdue):
            db, wrote = flush(db, batch)
            if wrote:                    # never acknowledge a batch that did not land
                consumer.commit(asynchronous=False)
                landed += len(batch)
                if landed % 2000 < len(batch):
                    print(f"{landed} transactions landed "
                          f"({landed * 3} rows)", flush=True)
                batch = []
            last_flush = time.monotonic()

    # Best effort on the way out. If this batch does not make it the offsets
    # were never committed, so the next start replays it.
    if batch:
        try:
            _, wrote = flush(db, batch, final=True)
            if wrote:
                consumer.commit(asynchronous=False)
        except Exception as e:
            print(f"final flush failed, will be replayed: {e}", file=sys.stderr)
    consumer.close()
    print(f"sink stopped after {landed} transactions", flush=True)


if __name__ == "__main__":
    main()
