#!/usr/bin/env python3
"""Generate a synthetic P2P payments dataset with planted fraud rings.

Why synthetic: payment data is among the most sensitive an organisation holds,
so a public example repo cannot ship it and should not ask you to point a first
run at production. The shape here mirrors what a real P2P ledger looks like —
accounts, the devices they sign in from, transfers between them, merchant
payments — so the graph model and every query transfer to real data unchanged.

Deterministic: same seed, same graph, including the rings the queries find.

Output is exactly what `spanner databases import --format=csv` expects: one
headerless CSV per table, plus a `csv-export.json` manifest naming each table's
columns and their Spanner types. That is the same layout
`spanner databases export --format=csv` produces, which is the point — the load
path is Spanner Omni's own bulk import, not a loader of ours, so there is no
DML size limit to work around and nothing to keep in sync with a client library.

Headerless is not an oversight. Spanner's CSV import reads the first line as
data; a header row lands as a row of literal column names, and on a DATE column
it fails with a parse error that points at the data rather than at the header.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import pathlib
import random

# The signal this demo is built around. A device shared by a handful of
# accounts that then move money between themselves is the classic ring shape:
# each account looks unremarkable alone, and the pattern only exists in the
# relationships.
FINDINGS = """
Planted findings — what the demo's queries should surface:

  1. RING-A: 4 accounts share one device and move funds in a closed cycle,
     returning most of it to where it started. No single account looks odd.

  2. RING-B: 3 accounts share a device and fan money OUT to one collector
     account that then pays a single merchant. A mule pattern.

  3. One legitimate shared device (a family) with 3 accounts and NO money
     movement between them — the false positive a device-only rule would flag
     and a graph query correctly ignores.
"""

FIRST = ["ana", "ben", "cleo", "dev", "elif", "femi", "gus", "hana", "ivan",
         "jo", "kai", "lena", "milo", "nadia", "omar", "pia", "quinn", "rosa",
         "sam", "tariq", "uma", "vic", "wren", "xan", "yuri", "zoe"]
LAST = ["acuna", "brandt", "cole", "diallo", "esposito", "fontaine", "gupta",
        "haddad", "ionescu", "jensen", "kovac", "lindqvist", "moreau",
        "nakamura", "okafor", "petrov", "reyes", "silva", "tanaka", "ustinov"]
# Paired with their category — drawing categories at random produced
# "Vertex Gaming / fuel", which undermines a demo people are meant to read as
# plausible.
MERCHANTS = [("Northwind Grocery", "grocery"), ("Blue Harbor Fuel", "fuel"),
             ("Cedar Pharmacy", "pharmacy"), ("Lumen Electronics", "retail"),
             ("Orchard Cafe", "food"), ("Pinnacle Sports", "retail"),
             ("Riverside Hardware", "retail"), ("Summit Travel", "travel"),
             ("Vertex Gaming", "gaming"), ("Willow Bookstore", "retail")]

# Column order and Spanner type for every table, in the shape Spanner's CSV
# import manifest wants. This must match sql/01_schema.ddl exactly, types
# included — the import validates against the live schema and rejects a
# mismatch, which is a good failure but an opaque one if you do not know to
# look here.
TABLES = [
    {"tableName": "Client", "filePatterns": ["Client.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "name", "typeName": "STRING(128)"},
        {"columnName": "email", "typeName": "STRING(256)"},
        {"columnName": "opened_date", "typeName": "DATE"},
        {"columnName": "risk_tier", "typeName": "STRING(16)"},
    ]},
    {"tableName": "Device", "filePatterns": ["Device.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "kind", "typeName": "STRING(16)"},
        {"columnName": "first_seen", "typeName": "DATE"},
    ]},
    {"tableName": "Merchant", "filePatterns": ["Merchant.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "name", "typeName": "STRING(128)"},
        {"columnName": "category", "typeName": "STRING(32)"},
    ]},
    {"tableName": "UsedDevice", "filePatterns": ["UsedDevice.csv"], "columns": [
        {"columnName": "client_id", "typeName": "STRING(32)"},
        {"columnName": "device_id", "typeName": "STRING(32)"},
        {"columnName": "first_used", "typeName": "DATE"},
    ]},
    {"tableName": "Paid", "filePatterns": ["Paid.csv"], "columns": [
        {"columnName": "tx_id", "typeName": "STRING(32)"},
        {"columnName": "src_client_id", "typeName": "STRING(32)"},
        {"columnName": "dst_client_id", "typeName": "STRING(32)"},
        {"columnName": "amount", "typeName": "FLOAT64"},
        {"columnName": "ts", "typeName": "TIMESTAMP"},
    ]},
    {"tableName": "PaidMerchant", "filePatterns": ["PaidMerchant.csv"], "columns": [
        {"columnName": "tx_id", "typeName": "STRING(32)"},
        {"columnName": "client_id", "typeName": "STRING(32)"},
        {"columnName": "merchant_id", "typeName": "STRING(32)"},
        {"columnName": "amount", "typeName": "FLOAT64"},
        {"columnName": "ts", "typeName": "TIMESTAMP"},
    ]},
]


def build(rng: random.Random, n_clients: int, n_tx: int, days: int, start: dt.datetime):
    clients, devices, merchants = [], [], []
    used_device, paid, paid_merchant = [], [], []

    names = set()
    while len(names) < n_clients:
        names.add(f"{rng.choice(FIRST)}.{rng.choice(LAST)}")
    # Sort for determinism, then shuffle with the seeded rng. Without the
    # shuffle the ring members — which are simply the first few clients — all
    # shared a first name, which made the data look obviously fabricated.
    names = sorted(names)
    rng.shuffle(names)

    for i, n in enumerate(names):
        clients.append({
            "id": f"C{i:05d}",
            "name": n.replace(".", " ").title(),
            "email": f"{n}@example.com",
            "opened": (start - dt.timedelta(days=rng.randint(30, 900))).date().isoformat(),
            "risk": rng.choice(["low"] * 8 + ["medium"] * 3 + ["high"]),
        })

    # One device per client, plus a few spares. Assigning devices round-robin
    # from a small pool makes EVERY device shared by several accounts — the
    # planted rings then become indistinguishable from the background and the
    # demo's central query returns noise. Sharing a device has to be rare for it
    # to mean anything.
    n_devices = n_clients + 10
    for i in range(n_devices):
        devices.append({
            "id": f"D{i:04d}",
            "kind": rng.choice(["ios", "android", "web"]),
            "first_seen": (start - dt.timedelta(days=rng.randint(1, 700))).date().isoformat(),
        })

    for i, (name, cat) in enumerate(MERCHANTS):
        merchants.append({"id": f"M{i:03d}", "name": name, "category": cat})

    # Ordinary behaviour: one account, one device.
    for i, c in enumerate(clients):
        used_device.append((c["id"], devices[i]["id"],
                            (start - dt.timedelta(days=rng.randint(0, days))).date().isoformat()))

    def ts(day_jitter: int = 0) -> str:
        d = start + dt.timedelta(days=rng.randint(0, max(0, days - 1)) + day_jitter,
                                 seconds=rng.randint(0, 86399))
        return d.replace(microsecond=0).isoformat() + "Z"

    txid = [0]

    def transfer(src: str, dst: str, amount: float, day_jitter: int = 0):
        txid[0] += 1
        paid.append((f"T{txid[0]:06d}", src, dst, round(amount, 2), ts(day_jitter)))

    # The three accounts that will share a tablet innocently. Reserved here,
    # before any traffic is generated, because the whole point of that group is
    # that no money moves between its members — see the rejection below.
    family_ids = {c["id"] for c in clients[8:11]}

    # --- background traffic ---------------------------------------------------
    for _ in range(n_tx):
        a, b = rng.sample(clients, 2)
        # Reject a transfer that would land inside the family. With 300 accounts
        # and 2000 transfers, a random pair inside a group of three comes up
        # about once per run — and one such transfer is enough to make the
        # family match query 02, which is precisely the query that is supposed
        # to clear them. The demo's central claim ("the graph query drops the
        # false positive") is only true if this is enforced rather than hoped
        # for. Drawing again rather than skipping keeps the transfer count exact.
        while a["id"] in family_ids and b["id"] in family_ids:
            a, b = rng.sample(clients, 2)
        transfer(a["id"], b["id"], rng.uniform(5, 400))
    for _ in range(n_tx // 2):
        c = rng.choice(clients)
        m = rng.choice(merchants)
        txid[0] += 1
        paid_merchant.append((f"T{txid[0]:06d}", c["id"], m["id"],
                              round(rng.uniform(3, 250), 2), ts()))

    # --- RING-A: shared device, closed cycle ----------------------------------
    ring_a = clients[:4]
    dev_a = devices[n_clients]["id"]      # a spare, not anyone's own
    for c in ring_a:
        used_device.append((c["id"], dev_a, (start + dt.timedelta(days=1)).date().isoformat()))
    amount = 9200.0
    for i in range(len(ring_a)):
        src = ring_a[i]["id"]
        dst = ring_a[(i + 1) % len(ring_a)]["id"]
        transfer(src, dst, amount, day_jitter=0)
        amount *= 0.97          # a small skim each hop, the rest goes round

    # --- RING-B: shared device, fan-in to a collector, then one merchant ------
    ring_b = clients[4:7]
    collector = clients[7]
    dev_b = devices[n_clients + 1]["id"]  # a spare
    for c in ring_b + [collector]:
        used_device.append((c["id"], dev_b, (start + dt.timedelta(days=2)).date().isoformat()))
    for c in ring_b:
        transfer(c["id"], collector["id"], rng.uniform(2600, 3100))
    txid[0] += 1
    paid_merchant.append((f"T{txid[0]:06d}", collector["id"], merchants[8]["id"], 8400.00, ts()))

    # --- the honest false positive: a family sharing a tablet, no transfers ---
    # Reserved as family_ids above, so background traffic cannot have put a
    # transfer between any two of them.
    dev_f = devices[n_clients + 2]["id"]  # a spare
    for c in clients[8:11]:
        used_device.append((c["id"], dev_f, (start - dt.timedelta(days=200)).date().isoformat()))

    return clients, devices, merchants, used_device, paid, paid_merchant


def write_csv(path: pathlib.Path, rows) -> int:
    """No header row — see the module docstring."""
    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        n = 0
        for r in rows:
            w.writerow(r)
            n += 1
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="generated")
    ap.add_argument("--clients", type=int, default=300)
    ap.add_argument("--transactions", type=int, default=2000)
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--seed", type=int, default=20260819)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    # Fixed start date, not "today" — a demo whose data changes per run cannot
    # have a last_verified date that means anything.
    start = dt.datetime(2026, 7, 1)

    clients, devices, merchants, used_device, paid, paid_merchant = build(
        rng, args.clients, args.transactions, args.days, start)

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    payloads = {
        "Client": [(c["id"], c["name"], c["email"], c["opened"], c["risk"]) for c in clients],
        "Device": [(d["id"], d["kind"], d["first_seen"]) for d in devices],
        "Merchant": [(m["id"], m["name"], m["category"]) for m in merchants],
        "UsedDevice": used_device,
        "Paid": paid,
        "PaidMerchant": paid_merchant,
    }

    counts = {}
    for spec in TABLES:
        name = spec["tableName"]
        counts[name] = write_csv(out / spec["filePatterns"][0], payloads[name])

    # The filename Spanner's CSV import looks for. Not configurable.
    (out / "csv-export.json").write_text(json.dumps({"tables": TABLES}, indent=2) + "\n")

    print(f"  {out}/")
    for name, n in counts.items():
        print(f"    {name:<16} {n:>7} row(s)")
    print(FINDINGS)


if __name__ == "__main__":
    main()
