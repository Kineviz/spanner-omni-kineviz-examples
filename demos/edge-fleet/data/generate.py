#!/usr/bin/env python3
"""Generate a synthetic edge-fleet inventory with planted fragility.

The premise Spanner Omni is actually for: a fleet of sites — factories, depots,
stores — whose operational data is not allowed to leave the premises, or which
spend most of their life without a usable uplink. The graph is the same shape
whether you run it at one site or in a cloud region; only where it runs changes.

Deterministic: same seed, same graph, including the fragilities the queries find.

Output is what `spanner databases import --format=csv` expects: one headerless
CSV per table plus a `csv-export.json` manifest. Headerless is not an oversight —
Spanner's CSV import reads the first line as data, so a header row lands as a row
of literal column names and fails on the first DATE column.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import pathlib
import random

FINDINGS = """
Planted fragility — what the demo's queries should surface:

  1. A CONCENTRATION gateway carrying far more devices than any other, so a
     single box failing takes an outsized share of the fleet with it.

  2. A site covered by exactly ONE technician that also holds high-criticality
     devices. Two unrelated tables; only the graph puts them next to each other.

  3. A firmware build under advisory KEV-2026-0031, still running on devices
     spread across several sites — the exposure is a set of sites, not a set of
     serial numbers.

  4. A DEPENDS_ON chain four hops deep ending at a device on the concentration
     gateway, so the real blast radius is larger than the direct device count.
"""

REGIONS = ["north", "south", "east", "west", "central"]
SITE_KINDS = ["Plant", "Depot", "Yard", "Terminal", "Works"]
SITE_NAMES = ["Alder", "Birch", "Cedar", "Dogwood", "Elm", "Fir", "Gorse",
              "Hazel", "Ivy", "Juniper", "Larch", "Maple", "Oak", "Pine",
              "Quince", "Rowan", "Spruce", "Thorn", "Willow", "Yew"]
DEVICE_KINDS = ["temp-sensor", "vibration-sensor", "flow-meter", "plc",
                "camera", "rfid-reader", "valve-controller", "power-meter"]
TECH_FIRST = ["ada", "bo", "cai", "dara", "eve", "finn", "gita", "hugo",
              "ida", "jules", "kira", "liam", "mira", "noor", "otto", "pia"]
TECH_LAST = ["alvarez", "boateng", "chen", "duarte", "ekwueme", "fischer",
             "grant", "haruki", "ivanov", "jonsson", "kaur", "lindgren",
             "mbeki", "novak", "oyelaran", "pereira"]
CERTS = ["L1", "L2", "L3", "electrical", "hazmat"]

TABLES = [
    {"tableName": "Site", "filePatterns": ["Site.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "name", "typeName": "STRING(128)"},
        {"columnName": "region", "typeName": "STRING(32)"},
        {"columnName": "opened_date", "typeName": "DATE"},
    ]},
    {"tableName": "Gateway", "filePatterns": ["Gateway.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "model", "typeName": "STRING(32)"},
        {"columnName": "installed_date", "typeName": "DATE"},
    ]},
    {"tableName": "Device", "filePatterns": ["Device.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "kind", "typeName": "STRING(32)"},
        {"columnName": "serial", "typeName": "STRING(64)"},
        {"columnName": "criticality", "typeName": "STRING(16)"},
    ]},
    {"tableName": "Firmware", "filePatterns": ["Firmware.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "version", "typeName": "STRING(32)"},
        {"columnName": "released_date", "typeName": "DATE"},
        {"columnName": "advisory", "typeName": "STRING(32)"},
    ]},
    {"tableName": "Technician", "filePatterns": ["Technician.csv"], "columns": [
        {"columnName": "id", "typeName": "STRING(32)"},
        {"columnName": "name", "typeName": "STRING(128)"},
        {"columnName": "certification", "typeName": "STRING(32)"},
    ]},
    {"tableName": "HostedAt", "filePatterns": ["HostedAt.csv"], "columns": [
        {"columnName": "gateway_id", "typeName": "STRING(32)"},
        {"columnName": "site_id", "typeName": "STRING(32)"},
        {"columnName": "rack", "typeName": "STRING(16)"},
    ]},
    {"tableName": "ConnectedTo", "filePatterns": ["ConnectedTo.csv"], "columns": [
        {"columnName": "device_id", "typeName": "STRING(32)"},
        {"columnName": "gateway_id", "typeName": "STRING(32)"},
        {"columnName": "port", "typeName": "INT64"},
    ]},
    {"tableName": "RunsFirmware", "filePatterns": ["RunsFirmware.csv"], "columns": [
        {"columnName": "device_id", "typeName": "STRING(32)"},
        {"columnName": "firmware_id", "typeName": "STRING(32)"},
        {"columnName": "applied_date", "typeName": "DATE"},
    ]},
    {"tableName": "Covers", "filePatterns": ["Covers.csv"], "columns": [
        {"columnName": "technician_id", "typeName": "STRING(32)"},
        {"columnName": "site_id", "typeName": "STRING(32)"},
        {"columnName": "since_date", "typeName": "DATE"},
    ]},
    {"tableName": "DependsOn", "filePatterns": ["DependsOn.csv"], "columns": [
        {"columnName": "device_id", "typeName": "STRING(32)"},
        {"columnName": "depends_on_id", "typeName": "STRING(32)"},
        {"columnName": "reason", "typeName": "STRING(32)"},
    ]},
]

# The advisory the exposure query looks for. One string, used by the generator
# and named in queries/03; changing it here means changing it there.
KEV = "KEV-2026-0031"


def build(rng: random.Random, n_sites: int, n_devices: int, start: dt.date):
    sites, gateways, devices, firmware, techs = [], [], [], [], []
    hosted, connected, runs, covers, depends = [], [], [], [], []

    # --- sites -------------------------------------------------------------
    names = SITE_NAMES[:]
    rng.shuffle(names)
    for i in range(n_sites):
        base = names[i % len(names)]
        suffix = "" if i < len(names) else f" {i // len(names) + 1}"
        sites.append({
            "id": f"S{i:03d}",
            "name": f"{base} {rng.choice(SITE_KINDS)}{suffix}",
            "region": rng.choice(REGIONS),
            "opened": (start - dt.timedelta(days=rng.randint(400, 5000))).isoformat(),
        })

    # --- firmware ----------------------------------------------------------
    # One build carries an advisory. Everything else is clean, so the exposure
    # query has something to actually separate.
    for i, (ver, adv) in enumerate([
        ("2.4.1", ""), ("2.5.0", ""), ("3.0.2", ""), ("3.1.0", ""),
        ("2.3.7", KEV), ("3.2.0", ""),
    ]):
        firmware.append({
            "id": f"F{i:02d}",
            "version": ver,
            "released": (start - dt.timedelta(days=rng.randint(60, 900))).isoformat(),
            "advisory": adv,
        })
    vulnerable = firmware[4]
    clean = [f for f in firmware if not f["advisory"]]

    # --- gateways: two or three per site ------------------------------------
    for s in sites:
        for _ in range(rng.randint(2, 3)):
            gid = f"G{len(gateways):04d}"
            gateways.append({
                "id": gid,
                "model": rng.choice(["EG-100", "EG-200", "EG-200X", "RX-40"]),
                "installed": (start - dt.timedelta(days=rng.randint(30, 2200))).isoformat(),
            })
            hosted.append((gid, s["id"], f"R{rng.randint(1, 8)}"))

    gw_ids = [g["id"] for g in gateways]

    # The concentration gateway. Chosen up front so device assignment can favour
    # it; picking it afterwards by counting would make the finding an accident of
    # the seed rather than a property of the data.
    hub = gw_ids[0]
    hub_site = hosted[0][1]

    # --- devices ------------------------------------------------------------
    for i in range(n_devices):
        did = f"D{i:05d}"
        devices.append({
            "id": did,
            "kind": rng.choice(DEVICE_KINDS),
            "serial": f"SN-{rng.randint(10**7, 10**8 - 1)}",
            "crit": rng.choice(["low"] * 6 + ["medium"] * 3 + ["high"]),
        })
        # 12% land on the hub; the rest spread evenly. That is enough to make it
        # the clear outlier without making every other gateway look empty.
        gid = hub if rng.random() < 0.12 else rng.choice(gw_ids)
        connected.append((did, gid, rng.randint(1, 48)))
        fw = clean[rng.randrange(len(clean))]
        runs.append((did, fw["id"], (start - dt.timedelta(days=rng.randint(1, 500))).isoformat()))

    # --- technicians and coverage -------------------------------------------
    n_techs = max(4, n_sites // 2)
    pairs = set()
    while len(pairs) < n_techs:
        pairs.add(f"{rng.choice(TECH_FIRST)}.{rng.choice(TECH_LAST)}")
    for i, p in enumerate(sorted(pairs)):
        techs.append({
            "id": f"T{i:03d}",
            "name": p.replace(".", " ").title(),
            "cert": rng.choice(CERTS),
        })

    # Two or three technicians per site, so "one technician" means something.
    lonely_site = sites[1]["id"]
    for s in sites:
        if s["id"] == lonely_site:
            continue
        for t in rng.sample(techs, rng.randint(2, 3)):
            covers.append((t["id"], s["id"],
                           (start - dt.timedelta(days=rng.randint(30, 1800))).isoformat()))
    # The planted single point of failure: one site, one technician.
    solo = techs[0]
    covers.append((solo["id"], lonely_site,
                   (start - dt.timedelta(days=900)).isoformat()))

    # ...and give that site high-criticality devices, otherwise "one technician"
    # is a staffing note rather than a risk. Reassign a handful of devices on the
    # site's own gateways to high.
    lonely_gws = {g for g, s, _ in hosted if s == lonely_site}
    by_id = {d["id"]: d for d in devices}
    n_high = 0
    for did, gid, _ in connected:
        if gid in lonely_gws and n_high < 5:
            by_id[did]["crit"] = "high"
            n_high += 1

    # --- the vulnerable firmware, spread across sites ------------------------
    # Deliberately across several sites rather than concentrated in one, because
    # the point of the query is that exposure is a set of sites.
    site_of_gw = {g: s for g, s, _ in hosted}
    seen_sites, exposed = set(), 0
    for idx, (did, gid, _) in enumerate(connected):
        site = site_of_gw[gid]
        if site in seen_sites and exposed >= 12:
            continue
        if rng.random() < 0.25 or site not in seen_sites:
            runs[idx] = (did, vulnerable["id"],
                         (start - dt.timedelta(days=rng.randint(200, 700))).isoformat())
            seen_sites.add(site)
            exposed += 1
        if exposed >= 18:
            break

    # --- background control dependencies ------------------------------------
    # Sparse and shallow, so the planted chain is the deep one.
    for _ in range(n_devices // 6):
        a, b = rng.sample(devices, 2)
        depends.append((a["id"], b["id"], rng.choice(["clock", "interlock", "setpoint"])))

    # --- the planted 4-hop chain, ending on the hub --------------------------
    hub_devices = [d for d, g, _ in connected if g == hub]
    tail = hub_devices[0]
    chain = [tail]
    pool = [d["id"] for d in devices if d["id"] not in hub_devices]
    rng.shuffle(pool)
    for i in range(4):
        nxt = pool[i]
        # nxt DEPENDS_ON chain[-1] — walk the arrow forwards to find everything
        # that falls over when the tail does.
        depends.append((nxt, chain[-1], "interlock"))
        chain.append(nxt)

    return (sites, gateways, devices, firmware, techs,
            hosted, connected, runs, covers, depends,
            {"hub": hub, "hub_site": hub_site, "lonely_site": lonely_site,
             "solo_tech": solo["name"], "chain": chain, "exposed": exposed})


def write_csv(path: pathlib.Path, rows) -> int:
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
    ap.add_argument("--sites", type=int, default=12)
    ap.add_argument("--devices", type=int, default=900)
    ap.add_argument("--seed", type=int, default=20260820)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    # Fixed date, not "today" — a demo whose data changes per run cannot have a
    # last_verified date that means anything.
    start = dt.date(2026, 7, 1)

    (sites, gateways, devices, firmware, techs,
     hosted, connected, runs, covers, depends, planted) = build(
        rng, args.sites, args.devices, start)

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    payloads = {
        "Site": [(s["id"], s["name"], s["region"], s["opened"]) for s in sites],
        "Gateway": [(g["id"], g["model"], g["installed"]) for g in gateways],
        "Device": [(d["id"], d["kind"], d["serial"], d["crit"]) for d in devices],
        "Firmware": [(f["id"], f["version"], f["released"], f["advisory"]) for f in firmware],
        "Technician": [(t["id"], t["name"], t["cert"]) for t in techs],
        "HostedAt": hosted,
        "ConnectedTo": connected,
        "RunsFirmware": runs,
        "Covers": covers,
        "DependsOn": depends,
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
    print(f"  concentration gateway : {planted['hub']} at site {planted['hub_site']}")
    print(f"  single-cover site     : {planted['lonely_site']} ({planted['solo_tech']})")
    print(f"  devices on {KEV} : {planted['exposed']}")
    print(f"  dependency chain      : {' <- '.join(planted['chain'])}\n")


if __name__ == "__main__":
    main()
