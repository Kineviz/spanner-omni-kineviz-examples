#!/usr/bin/env python3
"""Seeded synthetic PaySim-style payments, emitted as a SCHEMALESS Spanner graph.

Standard library only — no JVM, no Gradle, nothing to pip install.

WHAT MAKES THIS THE SCHEMALESS DEMO

Every node lands in ONE table, `GraphNode`, and every edge in ONE table,
`GraphEdge`. The label lives in a STRING column and the properties live in a
JSON column, and `CREATE PROPERTY GRAPH ... DYNAMIC LABEL / DYNAMIC PROPERTIES`
turns those two columns into a real property graph. Adding a node type is an
INSERT, not a schema change — which is the whole reason a POC picks schemaless.

Spanner allows AT MOST ONE node table and ONE edge table to use DYNAMIC LABEL,
so reifying transactions into nodes is not a stylistic choice: it is how a
polymorphic transaction (the receiver may be a client, a merchant or a bank)
fits a single-edge-table world.

The model deliberately matches the published Kineviz/paysim schemaless script
(data-injection/spanner-schemaless/) label for label, so this demo and the blog
repo tell the same story:

  nodes  client · transaction · merchant · bank · email · phonenumber · ssn
  edges  performs · to_client · to_merchant · to_bank
         has_email · has_phone · has_ssn

Labels and property names are LOWERCASE throughout. That is a Spanner
requirement for schemaless matching, not a house style — see
https://docs.cloud.google.com/spanner/docs/graph/manage-schemaless-data

It is PaySim-*inspired*, original MIT-licensed code: same actors (clients,
mules, merchants, banks), same five actions, same fraud typologies —

  · FIRST-PARTY RINGS   synthetic accounts built from a recombined pool of
                        stolen SSNs / emails / phones, moving money among
                        themselves and cashing out;
  · THIRD-PARTY FRAUD   account takeovers wiring money to mules, who cash
                        out at high-risk merchants;
  · one INNOCENT FAMILY sharing a phone with no transfers between them — the
                        false positive a shared-identifier rule would flag
                        and the graph query correctly ignores.

Seeded, so the same arguments always produce the same graph — including the
findings the queries and verify.sh assert. It prints what it planted.

Output: GraphNode.csv, GraphEdge.csv (both HEADERLESS — Spanner's CSV import
wants no header row), csv-export.json, and PLANTED.json, into --out.

Also transactions.csv, which nothing imports: it is the same transactions as a
flat fact stream, with a header, for the Kafka replay in streaming/. The batch
path does not read it and the two CSVs above do not change because of it.
"""

import argparse
import csv
import json
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

FIRST = """Ana Bruno Carla Daniel Elena Felipe Gina Hugo Iris Jonas Karla Luis
Marta Nadia Omar Paula Quinn Rosa Samir Tania Ulric Vera Wagner Xenia Yara
Zeca Alice Bento Clara Diego Edith Fabio Greta Henry Ivana Jorge Kiara Lucas
Mona Nilo""".split()

LAST = """Almeida Barros Costa Duarte Evans Ferraz Gomes Haddad Ibarra Jensen
Klein Lima Mendes Novak Ortiz Pires Quaresma Rocha Silva Teixeira Ueda Vidal
Weber Xavier Yamada Zettel Andrade Braga Castro Dias Estevez Fontes Guedes
Hori Inoue Junqueira Kern Lopes Moreira Nunes""".split()

MERCHANT_WORDS = """Corner General Rapid Golden Sunset Prime Metro Coastal
Union Vintage Cedar Harbor Summit Vista Grand Lunar Copper Ivory Falcon
Aurora""".split()

MERCHANT_KINDS = """Market Electronics Grocery Pharmacy Fuel Apparel Cafe
Hardware Telecom Travel Gaming Jewelry""".split()

EMAIL_DOMAINS = ["example.com", "mail.example", "inbox.example", "post.example"]

ACTIONS = ("CASH_IN", "CASH_OUT", "DEBIT", "PAYMENT", "TRANSFER")
ACTION_WEIGHTS = (14, 21, 6, 39, 20)  # roughly PaySim's aggregate mix

AMOUNTS = {  # (low, high) — uniform within, two decimals
    "CASH_IN": (50, 2500),
    "CASH_OUT": (40, 2000),
    "DEBIT": (20, 1500),
    "PAYMENT": (5, 800),
    "TRANSFER": (10, 3000),
}




def money2(x):
    """Round to cents before it becomes JSON.

    Spanner rejects JSON numbers that cannot round-trip through their string
    form — `SELECT JSON'{"amount": 286954.5962}'` is an error, not a value. Two
    decimals always round-trips, and money has no business carrying more.
    """
    return round(float(x), 2)
def money(rng, action):
    lo, hi = AMOUNTS[action]
    return round(rng.uniform(lo, hi), 2)


class Gen:
    def __init__(self, args):
        self.rng = random.Random(args.seed)
        self.args = args
        self.clients = []      # dicts: id,name,ssn,email,phone,client_type
        self.merchants = []
        self.banks = []
        self.txs = []          # dicts: step,action,amount,sender,receiver,fraud,flagged
        self.planted = {"seed": args.seed}

    # --- identities ---------------------------------------------------------

    def _name(self):
        return f"{self.rng.choice(FIRST)} {self.rng.choice(LAST)}"

    def _ssn(self):
        r = self.rng
        return f"{r.randint(100, 899):03d}-{r.randint(10, 99):02d}-{r.randint(1000, 9999):04d}"

    def _phone(self):
        r = self.rng
        return f"+1-{r.randint(200, 989):03d}-{r.randint(200, 989):03d}-{r.randint(1000, 9999):04d}"

    def _email(self, name):
        user = name.lower().replace(" ", ".")
        return f"{user}{self.rng.randint(1, 99)}@{self.rng.choice(EMAIL_DOMAINS)}"

    def _client(self, ctype="CLIENT", name=None, ssn=None, email=None, phone=None):
        cid = f"C{len(self.clients) + 1:04d}"
        name = name or self._name()
        c = {
            "id": cid,
            "name": name,
            "ssn": ssn or self._ssn(),
            "email": email or self._email(name),
            "phone": phone or self._phone(),
            "client_type": ctype,
        }
        self.clients.append(c)
        return c

    # --- actors -------------------------------------------------------------

    def build_actors(self):
        rng, a = self.rng, self.args

        for i in range(3):
            self.banks.append({"id": f"B{i + 1:02d}", "name": f"Bank of {rng.choice(LAST)}"})

        n_merchants = max(12, a.clients // 10)
        for i in range(n_merchants):
            self.merchants.append({
                "id": f"M{i + 1:03d}",
                "name": f"{rng.choice(MERCHANT_WORDS)} {rng.choice(MERCHANT_KINDS)}",
                "high_risk": False,
            })
        self.high_risk = rng.sample(self.merchants, 3)
        for m in self.high_risk:
            m["high_risk"] = True

        # Ordinary clients first; planted actors are appended after, so their
        # ids sit in a stable, seed-independent-looking range.
        n_planted = 4 + 4 + 3 + 3  # ring A + ring B(3+collector) + mules + family
        for _ in range(max(0, a.clients - n_planted)):
            self._client()

        # RING A — four synthetic identities recombining two stolen SSNs, two
        # emails and two phones. Every member shares at least one identifier
        # with another; together they form one connected component.
        s = [self._ssn(), self._ssn()]
        e = [f"ring.a{i}@{EMAIL_DOMAINS[0]}" for i in (1, 2)]
        p = [self._phone(), self._phone()]
        combos = [(s[0], e[0], p[0]), (s[0], e[1], p[1]), (s[1], e[0], p[1]), (s[1], e[1], p[0])]
        self.ring_a = [self._client("CLIENT", ssn=cs, email=ce, phone=cp) for cs, ce, cp in combos]

        # RING B — three synthetics sharing one SSN pool, fanning money into a
        # separate collector account. The collector is a MULE: it owns a clean
        # identity, which is exactly why the ring needs it.
        sb = [self._ssn(), self._ssn()]
        self.ring_b = [
            self._client("CLIENT", ssn=sb[0]),
            self._client("CLIENT", ssn=sb[0], phone=self._phone()),
            self._client("CLIENT", ssn=sb[1], email=f"ring.b@{EMAIL_DOMAINS[1]}"),
        ]
        # second and third share an email too, closing the component
        self.ring_b[2]["ssn"] = sb[0]
        self.collector = self._client("MULE")

        # Mules for the third-party leg.
        self.mules = [self._client("MULE") for _ in range(3)]

        # THE FAMILY — three people, one shared phone, one last name, nothing
        # else in common and no transfers between them. A device- or
        # identifier-only rule flags them; query 02 must not.
        fam_last = "Oliveira"  # not in LAST: keeps the family visually findable
        fam_phone = self._phone()
        self.family = [
            self._client("CLIENT", name=f"{self.rng.choice(FIRST)} {fam_last}", phone=fam_phone)
            for _ in range(3)
        ]

        self.victims = rng.sample(
            [c for c in self.clients if c["client_type"] == "CLIENT"
             and c not in self.ring_a and c not in self.ring_b and c not in self.family], 5)

    # --- transactions -------------------------------------------------------

    def _tx(self, step, action, amount, sender, receiver, rtype, fraud=False, flagged=False):
        self.txs.append({
            "step": step, "action": action, "amount": amount,
            "sender_id": sender["id"], "sender_type": sender["client_type"],
            "receiver_id": receiver["id"], "receiver_type": rtype,
            "is_fraud": fraud, "is_flagged_fraud": flagged,
        })

    def build_background(self):
        rng, a = self.rng, self.args
        steps = a.days * 24
        family_ids = {c["id"] for c in self.family}
        pool = [c for c in self.clients if c["client_type"] == "CLIENT"]

        for _ in range(a.transactions):
            c = rng.choice(pool)
            action = rng.choices(ACTIONS, weights=ACTION_WEIGHTS)[0]
            step = rng.randrange(steps)
            amt = money(rng, action)
            if action == "TRANSFER":
                other = rng.choice(pool)
                # the family's innocence is a fact the generator enforces
                while other["id"] == c["id"] or (c["id"] in family_ids and other["id"] in family_ids):
                    other = rng.choice(pool)
                self._tx(step, action, amt, c, other, "CLIENT")
            elif action == "DEBIT":
                self._tx(step, action, amt, c, rng.choice(self.banks), "BANK")
            else:  # CASH_IN / CASH_OUT / PAYMENT — counterparty is a merchant
                self._tx(step, action, amt, c, rng.choice(self.merchants), "MERCHANT")

    def build_fraud(self):
        rng, a = self.rng, self.args
        steps = a.days * 24
        late = lambda: rng.randrange(steps // 3, steps)  # noqa: E731

        # Ring A: three laps around the cycle, skimming 2–4% per hop, then one
        # member cashes the pot out at a bank. No single account looks unusual.
        amt = round(rng.uniform(2800, 3400), 2)
        ring_a_total = 0.0
        for _ in range(3):
            for i, sender in enumerate(self.ring_a):
                receiver = self.ring_a[(i + 1) % len(self.ring_a)]
                self._tx(late(), "TRANSFER", amt, sender, receiver, "CLIENT", fraud=True)
                ring_a_total += amt
                amt = round(amt * rng.uniform(0.96, 0.98), 2)
        self._tx(late(), "CASH_OUT", round(amt * 0.9, 2), self.ring_a[0],
                 rng.choice(self.banks), "BANK", fraud=True)

        # Ring B: members fan into the collector, who makes one large cash-out
        # at a high-risk merchant. Fan-in is the shape query 03 hunts.
        pot = 0.0
        for m in self.ring_b:
            for _ in range(rng.randint(2, 3)):
                x = round(rng.uniform(700, 1900), 2)
                pot += x
                self._tx(late(), "TRANSFER", x, m, self.collector, "MULE", fraud=True)
        self._tx(late(), "CASH_OUT", round(pot * 0.93, 2), self.collector,
                 rng.choice(self.high_risk), "MERCHANT", fraud=True)

        # Third-party: five takeover victims wire mules; mules cash out at
        # high-risk merchants. The victims are ordinary clients — that is the
        # point of a takeover.
        for v in self.victims:
            for _ in range(rng.randint(1, 2)):
                self._tx(late(), "TRANSFER", round(rng.uniform(400, 2400), 2),
                         v, rng.choice(self.mules), "MULE", fraud=True)
        for m in self.mules:
            self._tx(late(), "CASH_OUT", round(rng.uniform(1500, 4000), 2),
                     m, rng.choice(self.high_risk), "MERCHANT", fraud=True)

        # One blocked whale: PaySim flags huge transfer attempts, so one shows
        # up here for the is_flagged_fraud column to mean something.
        self._tx(late(), "TRANSFER", 250000.00, self.ring_a[1], self.ring_a[2],
                 "CLIENT", fraud=True, flagged=True)

        self.planted.update({
            "ring_a": {"members": [c["id"] for c in self.ring_a],
                       "moved_approx": round(ring_a_total, 2)},
            "ring_b": {"members": [c["id"] for c in self.ring_b],
                       "collector": self.collector["id"],
                       "fanned_in_approx": round(pot, 2)},
            "third_party": {"victims": [c["id"] for c in self.victims],
                            "mules": [c["id"] for c in self.mules]},
            "family": {"members": [c["id"] for c in self.family],
                       "shared_phone": self.family[0]["phone"]},
            "high_risk_merchants": [m["id"] for m in self.high_risk],
        })

    # --- output -------------------------------------------------------------

    # --- output: the schemaless pair ---------------------------------------

    def write(self, out: Path):
        out.mkdir(parents=True, exist_ok=True)
        start = datetime(2026, 1, 1, tzinfo=timezone.utc)

        # Order by (step, jitter) then number globally, so globalstep and the
        # timestamp agree.
        for t in self.txs:
            t["_jitter"] = self.rng.randrange(3600)
        self.txs.sort(key=lambda t: (t["step"], t["_jitter"]))
        for i, t in enumerate(self.txs, start=1):
            t["global_step"] = i
            t["ts"] = (start + timedelta(hours=t["step"], seconds=t["_jitter"])).isoformat()

        # A NOTE ON WHAT IS *NOT* IN THE JSON.
        #
        # `id` and `label` are real columns on GraphNode, so Spanner exposes
        # them as DEFINED properties — and defined properties SHADOW dynamic
        # ones. A JSON key named "id" would be unreachable: `n.id` always
        # resolves to the column. So the business identifier lives in the
        # column (prefixed, e.g. client_C0387) and never in the JSON. This is
        # also what Kineviz/paysim's importer does, for the same reason.
        #
        # Practical upshot for queries: `n.id` and `n.label` are plain STRINGs
        # and need no coercion; every other property is JSON and does.
        nodes = []   # (id, label, props dict)
        edges = []   # (id, dest_id, edge_id, label, props dict)

        def nid(label, key):
            # GraphNode.id is one primary key across every label, so it has to
            # be unique across labels too. Prefixing with the label is the
            # cheapest way there, it keeps ids readable on the Kineviz canvas,
            # and it is what Kineviz/paysim's schemaless importer already does.
            return f"{label}_{key}"

        # --- nodes ---------------------------------------------------------
        for c in self.clients:
            mule = c["client_type"] != "CLIENT"
            props = {
                "name": c["name"],
                "client_type": c["client_type"],
                "isfraud": mule,
            }
            if mule:
                # Deliberately present on SOME clients only. In a schemaless
                # graph two nodes with the same label need not carry the same keys.
                props["fraud_typology"] = "mule_account"
            nodes.append((nid("client", c["id"]), "client", props))

        for m in self.merchants:
            props = {"name": m["name"], "highrisk": bool(m["high_risk"])}
            if m["high_risk"]:
                props["risk_reason"] = "elevated_cashout_volume"
            nodes.append((nid("merchant", m["id"]), "merchant", props))

        for b in self.banks:
            nodes.append((nid("bank", b["id"]), "bank", {"name": b["name"]}))

        # Identifier nodes are deduplicated by value — sharing one is precisely
        # what makes a ring visible, so two clients on one SSN must land on the
        # same node, not two.
        seen_ident = {}

        def ident(label, value):
            key = (label, value)
            if key not in seen_ident:
                node_id = nid(label, value)
                seen_ident[key] = node_id
                nodes.append((node_id, label, {"name": value}))
            return seen_ident[key]

        for c in self.clients:
            src = nid("client", c["id"])
            for label, field, edge_label in (
                ("ssn", "ssn", "has_ssn"),
                ("email", "email", "has_email"),
                ("phonenumber", "phone", "has_phone"),
            ):
                dst = ident(label, c[field])
                edges.append((src, dst, f"h_{label}", edge_label, {}))

        for t in self.txs:
            tx_id = f"T{t['global_step']:06d}"
            tx_node = nid("transaction", tx_id)
            nodes.append((tx_node, "transaction", {
                "amount": money2(t["amount"]),
                "timestamp": t["ts"],
                "action": t["action"],
                "globalstep": t["global_step"],
                "isfraud": bool(t["is_fraud"]),
                "isflaggedfraud": bool(t["is_flagged_fraud"]),
                "typeorig": t["sender_type"],
                "typedest": t["receiver_type"],
            }))

            gs = t["global_step"]
            edges.append((nid("client", t["sender_id"]), tx_node, f"p{gs}",
                          "performs", {"timestamp": t["ts"]}))

            rtype = t["receiver_type"]
            if rtype == "MERCHANT":
                dst, label = nid("merchant", t["receiver_id"]), "to_merchant"
            elif rtype == "BANK":
                dst, label = nid("bank", t["receiver_id"]), "to_bank"
            else:                       # CLIENT or MULE — both are client nodes
                dst, label = nid("client", t["receiver_id"]), "to_client"
            edges.append((tx_node, dst, f"t{gs}", label, {"timestamp": t["ts"]}))

        # --- files ---------------------------------------------------------
        # Headerless, because `spanner databases import --format=csv` reads the
        # column order from csv-export.json and treats row 1 as data.
        def dump(name, rows):
            with (out / name).open("w", newline="") as f:
                w = csv.writer(f)
                for r in rows:
                    w.writerow(list(r[:-1]) + [json.dumps(r[-1], allow_nan=False)])

        dump("GraphNode.csv", nodes)
        dump("GraphEdge.csv", edges)

        # transactions.csv — the same transactions again, as a flat fact stream
        # for the Kafka replay in streaming/. It is an ADDITIONAL file, not a
        # replacement: the two CSVs above are unchanged, so the batch path loads
        # exactly what it always loaded.
        #
        # The columns are the transaction as it happened, not as it is stored.
        # Turning one of these rows back into a node and two edges is the sink's
        # job (streaming/sink/sink.py), and it does it with the same rules used
        # thirty lines above — same `label_key` ids, same lowercase labels, same
        # rounded amount. That is what lets a streamed row and a batch-loaded row
        # be the same row, so replaying onto a full database changes nothing.
        #
        # WITH a header, unlike the two above: nothing imports this file into
        # Spanner, csv.DictReader in the producer reads it, and a header there is
        # worth more than consistency with a constraint that does not apply.
        # Already ordered by (step, jitter) with global_step assigned in that
        # order, so the producer can pace on `ts` without sorting.
        with (out / "transactions.csv").open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["global_step", "step", "ts", "action", "amount",
                        "sender_id", "sender_type", "receiver_id",
                        "receiver_type", "is_fraud", "is_flagged_fraud"])
            for t in self.txs:
                w.writerow([t["global_step"], t["step"], t["ts"], t["action"],
                            money2(t["amount"]), t["sender_id"],
                            t["sender_type"], t["receiver_id"],
                            t["receiver_type"],
                            "true" if t["is_fraud"] else "false",
                            "true" if t["is_flagged_fraud"] else "false"])

        # typeName must be the EXACT type in 01_schema.ddl. "STRING" instead of
        # "STRING(MAX)" fails the import with
        #   Column id has type STRING but it should be STRING(MAX)
        # and the CSV import reports that only in the operation, never inline.
        manifest = {"tables": [
            {"tableName": "GraphNode",
             "filePatterns": ["GraphNode.csv"],
             "columns": [{"columnName": "id", "typeName": "STRING(MAX)"},
                         {"columnName": "label", "typeName": "STRING(MAX)"},
                         {"columnName": "properties", "typeName": "JSON"}]},
            {"tableName": "GraphEdge",
             "filePatterns": ["GraphEdge.csv"],
             "columns": [{"columnName": "id", "typeName": "STRING(MAX)"},
                         {"columnName": "dest_id", "typeName": "STRING(MAX)"},
                         {"columnName": "edge_id", "typeName": "STRING(MAX)"},
                         {"columnName": "label", "typeName": "STRING(MAX)"},
                         {"columnName": "properties", "typeName": "JSON"}]},
        ]}
        (out / "csv-export.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (out / "PLANTED.json").write_text(json.dumps(self.planted, indent=2) + "\n")

        self.counts = {"nodes": len(nodes), "edges": len(edges)}
        by_label = {}
        for _, label, _ in nodes:
            by_label[label] = by_label.get(label, 0) + 1
        self.counts["by_label"] = by_label

    def report(self):
        p = self.planted
        print(f"planted findings (seed {p['seed']}) — what the queries should surface:")
        print(f"  · ring A: {len(p['ring_a']['members'])} synthetic accounts "
              f"({', '.join(p['ring_a']['members'])}) sharing recombined identifiers, "
              f"cycling ~${p['ring_a']['moved_approx']:,.0f} and cashing out")
        print(f"  · ring B: {', '.join(p['ring_b']['members'])} fanning "
              f"~${p['ring_b']['fanned_in_approx']:,.0f} into collector {p['ring_b']['collector']}, "
              f"cashed out at a high-risk merchant")
        print(f"  · third-party: {len(p['third_party']['victims'])} takeover victims wiring "
              f"mules {', '.join(p['third_party']['mules'])}")
        print(f"  · innocent family: {', '.join(p['family']['members'])} share one phone, "
              f"zero transfers between them — the deliberate false positive")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--seed", type=int, default=20260825)
    ap.add_argument("--clients", type=int, default=400)
    ap.add_argument("--transactions", type=int, default=12000)
    ap.add_argument("--days", type=int, default=30)
    args = ap.parse_args()

    if args.clients < 40 or args.transactions < 500 or args.days < 2:
        sys.exit("refusing tiny worlds: need >=40 clients, >=500 transactions, >=2 days")

    g = Gen(args)
    g.build_actors()
    g.build_background()
    g.build_fraud()
    g.write(args.out)
    g.report()
    labels = ", ".join(f"{k} {v}" for k, v in sorted(g.counts["by_label"].items()))
    print(f"wrote {g.counts['nodes']} nodes ({labels}) "
          f"and {g.counts['edges']} edges -> {args.out}/")


if __name__ == "__main__":
    main()
