#!/usr/bin/env python3
"""Replay generated PaySim transactions into Kafka, on compressed time.

Reads the canonical transactions.csv (already ordered by global_step, with a
simulated timestamp per row) and produces one JSON message per transaction to
KAFKA_TOPIC, keyed by sender_id so a client's own history stays ordered
within a partition.

Pacing — the part that makes the demo watchable:

  STREAM_HOUR_SECONDS   (default 2.5) one simulated hour takes this many
                        wall seconds, so 30 simulated days pass in ~30
                        minutes. Quiet nights stay quiet, fraud bursts land
                        as bursts — the "boom, something happened" beat a
                        flat rate flattens away. 0 = no pacing, full blast.
  STREAM_RATE           set to a number to use flat transactions/second
                        instead (overrides STREAM_HOUR_SECONDS).

Exits 0 when the replay is done; the sink keeps running. `docker compose up`
again (or ./gxr stream up) to replay after a reset.

Nothing here knows about Spanner, or about graphs. It publishes the transaction
as it happened; turning that into a node and two edges is the sink's job. That
separation is why this file is a near-verbatim copy of the one in
Kineviz/pg-kineviz-examples — only the demo name in the error message differs —
and why a second consumer can be added without touching it.
"""

import csv
import json
import os
import sys
import time
from datetime import datetime

from confluent_kafka import KafkaException, Producer

BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "broker:29092")
TOPIC = os.environ.get("KAFKA_TOPIC", "paysim.transactions")
DATA_FILE = os.environ.get("DATA_FILE", "/data/transactions.csv")
HOUR_SECONDS = float(os.environ.get("STREAM_HOUR_SECONDS", "2.5") or 0)
RATE = os.environ.get("STREAM_RATE", "").strip()

errors = 0


def on_delivery(err, _msg):
    global errors
    if err is not None:
        errors += 1
        if errors <= 5:
            print(f"delivery failed: {err}", file=sys.stderr)


def wait_for_broker(producer, tries=30):
    for i in range(tries):
        try:
            producer.list_topics(timeout=5)
            return
        except KafkaException:
            print(f"broker not ready yet ({i + 1}/{tries})...", flush=True)
            time.sleep(2)
    sys.exit("broker never became reachable")


def row_to_event(row):
    """Types matter: the sink and the dashboard read these as JSON."""
    return {
        "global_step": int(row["global_step"]),
        "step": int(row["step"]) if row.get("step") else None,
        "ts": row["ts"],
        "action": row["action"],
        "amount": float(row["amount"]),
        "sender_id": row["sender_id"],
        "sender_type": row["sender_type"],
        "receiver_id": row["receiver_id"],
        "receiver_type": row["receiver_type"],
        "is_fraud": row["is_fraud"] == "true",
        "is_flagged_fraud": row["is_flagged_fraud"] == "true",
    }


def main():
    if not os.path.exists(DATA_FILE):
        sys.exit(f"no data at {DATA_FILE} — run './gxr up paysim-schemaless' first")

    producer = Producer({
        "bootstrap.servers": BOOTSTRAP,
        "linger.ms": 20,
        "compression.type": "lz4",
    })
    wait_for_broker(producer)

    flat_rate = float(RATE) if RATE else None
    speed = (3600.0 / HOUR_SECONDS) if HOUR_SECONDS > 0 else None
    if flat_rate:
        print(f"replaying {DATA_FILE} flat at {flat_rate:.0f} tx/s", flush=True)
    elif speed:
        print(f"replaying {DATA_FILE} at {speed:.0f}x simulated time "
              f"(1 sim-hour = {HOUR_SECONDS}s wall)", flush=True)
    else:
        print(f"replaying {DATA_FILE} at full speed", flush=True)

    sent = 0
    wall_start = time.monotonic()
    sim_start = None

    with open(DATA_FILE, newline="") as fh:
        for row in csv.DictReader(fh):
            event = row_to_event(row)

            if flat_rate:
                due = wall_start + sent / flat_rate
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            elif speed:
                sim_ts = datetime.fromisoformat(event["ts"])
                if sim_start is None:
                    sim_start = sim_ts
                due = wall_start + (sim_ts - sim_start).total_seconds() / speed
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)

            while True:
                try:
                    producer.produce(
                        TOPIC,
                        key=event["sender_id"].encode(),
                        value=json.dumps(event).encode(),
                        on_delivery=on_delivery,
                    )
                    break
                except BufferError:      # local queue full — drain and retry
                    producer.poll(0.5)
            producer.poll(0)

            sent += 1
            if sent % 1000 == 0:
                print(f"{sent} produced (sim time {event['ts']})", flush=True)

    producer.flush(30)
    if errors:
        sys.exit(f"replay finished with {errors} delivery error(s) after {sent} messages")
    print(f"replay complete: {sent} transactions -> {TOPIC}", flush=True)


if __name__ == "__main__":
    main()
