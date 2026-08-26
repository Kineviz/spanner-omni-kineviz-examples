# Queries

> **Start on the canvas.** [`canvas/`](canvas/) has these same questions written
> to return **nodes and edges**, so the answer arrives in Kineviz as a shape
> rather than a table. That is the version to run in front of someone. The files
> below return rows, which is what you want in a terminal — and what you need
> before Kineviz is connected, since Spanner will not hand a graph element back
> to a client.

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

In Kineviz the shortest version is the built-in `:schema` command: it draws one
node per label and one edge per relationship type, and on this database every
one of those labels came from reading rows, because the catalog holds only
`GraphNode` and `GraphEdge`.

[`canvas/05-prove-schemaless.gql`](canvas/05-prove-schemaless.gql) is the live
companion to that, and it works either side of the insert: sixteen nodes as-is,
seventeen once `prove-schemaless.sh --keep` adds the type. `:schema` draws a
copy cached when the project opened, so it needs a reopen to show a new label;
query 5 queries the database, so it does not.

or paste it into the **Query** tab of the Kineviz query panel — that tab posts
whatever you type straight to the proxy, so all five files here work there.
Strip the `--` comments first if you paste the whole file.

```
source      dynamic_label_column  labels
the schema  label                 GraphNode
the data    label                 bank, client, email, merchant, phonenumber, ssn, transaction
```

The graph *declares* a dynamic label column, and the catalog knows one label
while the data carries seven. Labels are not in the schema, because here labels
are not schema.

### The live version

This adds a node type and an edge type that do not exist, queries them, shows both sides again, and removes
what it added:

```bash
../scripts/prove-schemaless.sh
```

```
  ✓ the catalog knows 1 label; the data carries 7
  ✓ inserted :regulator and :reported_to
  ✓ queryable immediately, with no migration in between
  ✓ schema unchanged (GraphNode); data went from 7 labels to 8
  ✓ Kineviz sees it too, with no reconnect: bank, client, …, regulator, …
  ✓ back to 7 labels — the dataset is as it was
```

The fourth line is the assertion. The catalog row is **identical** before and
after, while the data row grows, and the script fails if it is not.

It cleans up on every exit path — success, failure, or Ctrl-C — and clears any
rows a previous interrupted run left behind before it starts, so the demo
dataset is always left as it was found.

### In the Kineviz GUI

The version to run in front of an audience, because the schema panel changing
is the part people believe. Start the proxy and connect Desktop first
([`connect/README.md`](../../../connect/README.md) § 3 · Connect).

1. Open the query panel — the `</>` icon in the left rail — and pick the
   **Query** tab. For a Database Proxy project that tab posts what you type
   straight to the proxy, so every file in this folder works there, comments
   and all. The `limit` box does not apply: the request carries only your text.
2. Paste [`05-prove-schemaless.sql`](05-prove-schemaless.sql) and run it. Two
   rows: the schema knows `GraphNode`, the data carries seven labels.
3. In a terminal, add the new types and leave them there:

   ```bash
   ../scripts/prove-schemaless.sh --keep
   ```

4. Run the same query again in the Query tab, unchanged. The schema row is
   identical. The data row now lists eight, including `regulator`.
5. Put the new type on the canvas — this one returns graph elements rather than
   a table, so it draws:

   ```
   GRAPH PaysimGraph
   MATCH (c:client)-[r:reported_to]->(g:regulator)
   RETURN c, r, g
   ```

6. Reopen the project to see `regulator` in the schema panel. Kineviz fetches
   the graph schema once per project session and caches it, so a category added
   while the project is open does not appear until you reopen it. The proxy
   itself has it immediately — `GET /graphSchema` proves that without a restart.
7. Put it back:

   ```bash
   ../scripts/prove-schemaless.sh --undo
   ```

The writes run in either place. `connect/proxy/spanner_omni_driver.py` routes
DML to a read-write transaction, so the two `INSERT`s and the two `DELETE`s work
in the Kineviz Query tab as well as the CLI — see
[`canvas/README.md`](canvas/README.md). Without that override the proxy runs
everything in a read-only snapshot and answers *"DML statements may not be
performed in single-use transactions"*. The script is still the version with an
assertion attached and cleanup on every exit path.

If a statement you expect to work comes back as **0 rows with no message**,
your Kineviz build predates the fix that surfaces proxy-side errors: the
adapter used to read the response's `data` field and ignore `success` and
`error`, so a rejected statement looked exactly like one that matched nothing.
Re-run it with `gxr omni query`, which prints the real error either way.

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
