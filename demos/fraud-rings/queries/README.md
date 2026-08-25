# Queries

One question per file. Run them in Kineviz's query panel, in the Spanner Omni
SQL shell, or through this repo's runner.

| File | The question it answers |
|---|---|
| `01-shared-devices.gql` | Which accounts signed in from the same device? |
| `02-money-cycles.gql` | Which of those also move money between themselves? |
| `03-collector-accounts.gql` | Which account is the fan-in point of a ring? |
| `04-cash-out.gql` | Where does the value leave the network? |

**Start with `01`, then `02`.** On its own, a shared device is a weak signal —
families share tablets. `02` is what turns it into a finding.

Run one from the shell:

```bash
set -a; . ../.env; set +a
../../../gxr omni query "$OMNI_DATABASE" 01-shared-devices.gql
```

Or paste it into the interactive shell, which is the nicer way to iterate:

```bash
../../../gxr omni sql "$OMNI_DATABASE"
```

These files use the graph name literally (`GRAPH FraudGraph`) rather than a
placeholder, because the name is fixed by the schema in `sql/01_schema.ddl`.
If you changed `OMNI_GRAPH` in `.env`, change it here too.

`02` is the one worth running in Kineviz rather than the CLI — a cycle is a
shape.

## What you should find

Seeded, so these are reproducible rather than lucky:

- **A ring of 4 accounts** sharing one device, moving ~$9,200 in a closed cycle
  and skimming a little at each hop. Every account looks ordinary alone.
- **A ring of 3 accounts** sharing a device and fanning money into a **fourth
  collector account**, which then makes a single large merchant payment.
- **A family of 3 accounts** sharing a tablet with **no transfers between them**.
  A device-only rule flags this; `02` correctly does not. That false positive is
  in the data on purpose — it is the reason to use a graph rather than a
  shared-device list.
