# Queries

One question per file. Run them in Kineviz's query panel, in the Spanner Omni
SQL shell, or through this repo's runner.

| File | The question it answers |
|---|---|
| `01-blast-radius.gql` | If one gateway fails, how much of the fleet goes with it? |
| `02-lone-cover.gql` | Which sites have one technician and equipment that matters? |
| `03-advisory-exposure.gql` | Which *sites* run firmware under a published advisory? |
| `04-cascade.gql` | What does query 01 miss, once devices depend on each other? |

**Start with `01`, then `04`.** `01` counts what is directly attached to a
gateway; `04` walks the dependency chains that make the real radius bigger. The
gap between the two numbers is the argument for a graph.

Run one from the shell:

```bash
set -a; . ../.env; set +a

# The CLI rejects `--` comment lines and an indented first line, so strip both.
docker exec -i spanneromni /google/spanner/bin/spanner \
  databases execute-sql "$OMNI_DATABASE" \
  --sql="$(grep -v '^[[:space:]]*--' 01-blast-radius.gql | sed '/^[[:space:]]*$/d')"
```

Or paste it into the interactive shell, which is the nicer way to iterate:

```bash
../../../gxr omni sql "$OMNI_DATABASE"
```

These files use the graph name literally (`GRAPH FleetGraph`) rather than a
placeholder, because the name is fixed by the schema in `sql/01_schema.ddl`.
If you changed `OMNI_GRAPH` in `.env`, change it here too.

`03` is the one worth running in Kineviz rather than the CLI — whether an
exposure is concentrated at one site or smeared across the fleet is a shape, and
they are different problems with different fixes.

## What you should find

Seeded, so these are reproducible rather than lucky:

- **A concentration gateway** carrying ~129 of 900 devices, against ~37 for the
  next busiest. One box, an outsized share of the fleet.
- **One site with a single technician on call** and a double-figure count of
  high-criticality devices behind them. Neither the roster nor the asset register
  shows this on its own.
- **Firmware under `KEV-2026-0031`** still running at a dozen sites. Spread thin
  on purpose: a scanner would hand you serial numbers, and the useful answer is
  the list of places to send someone.
- **A four-hop `DEPENDS_ON` chain** ending on a device attached to the
  concentration gateway — so that gateway's true blast radius is larger than
  query `01` reports.

## A note on the quantifier in `04`

`-[:DEPENDS_ON]->{1,4}` walks between one and four hops. The bound is
deliberate. Control dependencies acquire cycles the moment somebody wires a
mutual interlock, and an unbounded walk over a cycle does not terminate. If you
raise it, raise it knowingly.
