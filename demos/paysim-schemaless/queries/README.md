# Queries

Four questions, in the order an investigator would actually ask them.

| | Question | File |
|---|---|---|
| 1 | Which accounts share an SSN, email or phone? | [`01-shared-identifiers.gql`](01-shared-identifiers.gql) |
| 2 | Which of those also move money to each other? | [`02-fraud-rings.gql`](02-fraud-rings.gql) |
| 3 | Which accounts collect from an identity cluster? | [`03-collector-accounts.gql`](03-collector-accounts.gql) |
| 4 | Where does the value leave the network? | [`04-cash-out.gql`](04-cash-out.gql) |
| 5 | *Is this actually schemaless?* | [`05-prove-schemaless.sql`](05-prove-schemaless.sql) |

## Running them

```bash
# run a file — strips the comments and submits the statement for you
../../../gxr omni query kineviz-paysim-demo 01-shared-identifiers.gql

# or open the interactive shell and paste, to iterate
../../../gxr omni sql kineviz-paysim-demo
```

Two things about the interactive shell, both of which look like the query is
broken when they are not. It needs a **trailing semicolon** — without one it
silently keeps reading. And you cannot pipe a file into it: it runs under
`docker exec -it`, so `... omni sql <db> < file.gql` fails with *"cannot attach
stdin to a TTY-enabled container"*. That is what `omni query` is for.

The graph name is hardcoded as `PaysimGraph`. If you changed `OMNI_GRAPH` in
`.env`, change it here too — a `${VAR}` in a query file is not substituted by
anything, and CI rejects one.

Run query 2 in Kineviz rather than in a terminal. A ring is a shape, and a
table of account ids is the one representation that hides it.

## Proving it is really schemaless

`MATCH (n) RETURN DISTINCT n.label` proves nothing — it says a column called
`label` has seven values, and a static graph could have a column called `label`
too. What cannot be faked is the gap between what the catalog knows and what the
data contains:

```bash
../../../gxr omni query kineviz-paysim-demo 05-prove-schemaless.sql
```

```
source      dynamic_label_column  labels
the schema  label                 GraphNode
the data    label                 bank, client, email, merchant, phonenumber, ssn, transaction
```

The graph *declares* a dynamic label column, and the catalog knows one label
while the data carries seven. Labels are not in the schema, because here labels
are not schema.

That file also carries the live proof — two `INSERT`s that add a node type and
an edge type with no DDL, no schema update and no restart — and the control that
shows the same move failing on the standard-schema demo. The writes go through
the CLI, not through Kineviz: the database proxy runs everything in a read-only
snapshot, so DML comes back as *"DML statements may not be performed in
single-use transactions"*. Write from the CLI or an application, and watch the
new category appear in Kineviz.

## What you should find

The dataset is seeded, so these are the same every run:

- **Ring A** — four synthetic accounts (`C0387`–`C0390`) built by recombining
  two stolen SSNs, two emails and two phones, cycling roughly $30,000 between
  themselves and cashing out. Query 1 shows the shared identifiers; query 2
  shows the money.
- **Ring B** — three accounts (`C0391`–`C0393`) sharing an SSN, fanning about
  $10,100 into collector `C0394`, which is a `MULE` with a clean identity of
  its own. Query 3 is the one that finds it; query 1 cannot, because the
  collector shares nothing with anyone.
- **Third-party fraud** — five takeover victims wiring mules `C0395`–`C0397`,
  who cash out at the three high-risk merchants. Query 4.
- **The innocent family** — `C0398`, `C0399`, `C0400`, three Oliveiras sharing
  one phone and making no transfers between them. They appear in query 1 and
  must **not** appear in query 2. That is the whole argument for the graph:
  a shared-identifier rule flags them, and the relationship does not.

`verify.sh` asserts the first and the last of those, so a drift between the
generator and the schema fails the demo rather than quietly weakening it.

## GQL notes, schemaless edition

Things that cost time the first time. All of them were hit building this demo,
not copied from a doc page.

- **`id` and `label` are real columns, so they need no coercion.** Everything
  else is a dynamic property, which means JSON. `STRING(n.name)`,
  `FLOAT64(t.amount)`, `BOOL(m.highrisk)`, `LAX_INT64(...)`. Skip the wrapper
  and you get `No matching signature for function ...`, which reads like a
  missing column.
- **Defined properties shadow dynamic ones.** `GraphNode.id` is a column, so a
  JSON key also called `id` would be unreachable. The generator therefore keeps
  the business identifier out of the JSON — `n.id` is `client_C0387`.
- **Use `n.label`, not `LABELS(n)[OFFSET(0)]`.** Every schemaless node carries
  *two* labels: its own, and the table's (`GraphNode`). `LABELS()` returns them
  sorted, so `[OFFSET(0)]` yields `GraphNode` for every label alphabetically
  after it — `merchant`, `phonenumber`, `ssn`, `transaction` — and the real
  label for the rest. Half-right output, no error.
- **Labels are lowercase.** Not a house style: Spanner requires schemaless
  label values to be stored lowercase. `MATCH (n:Client)` finds nothing.
- **No `HAVING`.** Aggregate, then `NEXT` into a new statement and `FILTER`
  there.
- **A subquery may not redefine an outer element variable.** `EXISTS { MATCH
  (p)-[...] }` is rejected even when `p` is exactly what you mean. Bind a new
  name and tie it back with equality — see query 3.
- **Comma-joined patterns multiply rows.** Joining an identity pattern to a
  money pattern gives one row per combination, so a three-account cluster
  counts every transfer twice and `SUM(amount)` comes out doubled. It looks
  plausible and it is wrong. Query 3 uses `EXISTS` for exactly this reason.
- **The CLI cannot render a JSON column** — it prints `(Unspecified)`. Project
  scalars out of the JSON rather than returning `n.properties`.
