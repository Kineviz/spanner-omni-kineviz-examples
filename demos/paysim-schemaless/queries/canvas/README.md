# Canvas queries

The same four questions as [`../`](../), returning **nodes and edges** instead of
rows, so the answer arrives on the Kineviz canvas as a shape rather than a table.

| | Question | File |
|---|---|---|
| 1 | Which accounts share an SSN, email or phone? | [`01-shared-identifiers.gql`](01-shared-identifiers.gql) |
| 2 | Which of those also move money to each other? | [`02-fraud-rings.gql`](02-fraud-rings.gql) |
| 3 | Which accounts collect from an identity cluster? | [`03-collector-accounts.gql`](03-collector-accounts.gql) |
| 4 | Where does the value leave the network? | [`04-cash-out.gql`](04-cash-out.gql) |
| 5 | Is this actually schemaless? | [`05-prove-schemaless.gql`](05-prove-schemaless.gql) |

Paste one into the **Query** tab of the Kineviz query panel and run it. Each is a
single statement; they accumulate on the canvas, so running 1 then 2 leaves the
identity clusters in place and draws the money over them.

### The shortest proof is `:schema`

Type `:schema` into the Query tab. Kineviz draws its schema as a graph — one node
per label, one edge per relationship type — and on this database every one of
those labels was discovered by **reading rows**, because the catalog knows only
`GraphNode` and `GraphEdge`. A picture of a schema that is not in the schema.

`:schema` draws the cached copy, fetched once when the project opened, so a label
added mid-session appears only after you reopen the project. That is the one
thing query 5 below does that `:schema` cannot.

### The insert runs here too

You do not have to leave Kineviz to make the point. Paste these into the same
Query tab:

```sql
INSERT INTO GraphNode (id, label, properties)
VALUES ('regulator_R01', 'regulator',
        JSON'{"name": "Financial Conduct Authority", "jurisdiction": "UK"}')
```

```sql
INSERT INTO GraphEdge (id, dest_id, edge_id, label, properties)
VALUES ('client_C0394', 'regulator_R01', 'sar1', 'reported_to',
        JSON'{"filed": "2026-02-01", "reason": "structuring"}')
```

Each answers `rows_affected 1`. Re-run query 5 and the new type is on the
canvas. Undo in the same panel:

```sql
DELETE FROM GraphEdge WHERE id='client_C0394' AND dest_id='regulator_R01' AND edge_id='sar1';
```
```sql
DELETE FROM GraphNode WHERE id='regulator_R01';
```

This works because `connect/proxy/spanner_omni_driver.py` routes writes to a
read-write transaction; the proxy's own driver runs everything in a read-only
snapshot and answers *"DML statements may not be performed in single-use
transactions"*. `../../scripts/prove-schemaless.sh` does the same thing from a
terminal, with an assertion attached and cleanup on every exit path — use that
when you want it checked rather than shown.

**The deployment accepts writes from anything that can reach the proxy.** That
is a smaller change than it sounds, since the preview build of Spanner Omni has
no authentication at all, but it is the reason the proxy binds to 127.0.0.1 and
nothing else.

### Query 5 is the live view

**It works either side of the insert.** As-is it draws the four mule
accounts and their SSN, email and phone — sixteen nodes. Run
`../../scripts/prove-schemaless.sh --keep` in a terminal and run it again: a
seventeenth node joins the same picture, a `:regulator` with no table and no
schema entry, sitting beside `:ssn` and `:email`, which are no more real than it
is. `--undo` puts it back.

The `->{0,1}` on its last hop is what makes that work. A zero-or-one quantifier
makes the step optional, and at zero hops the tail binds to the account itself
so nothing extra is drawn. The obvious way to write it — an `OPTIONAL` clause —
does not survive the rewrite, for the same reason subqueries do not.

## These do not run in the CLI

`gxr omni query` will refuse them:

```
Returning expressions of type GRAPH_ELEMENT is not allowed
```

That is Spanner Omni, not Kineviz — the database will not hand a graph element
back to a client. They work in Kineviz because the database proxy rewrites the
statement into a path projection before it reaches Spanner. Use [`../`](../) for
anything you want to run in a terminal; those are tables, and they work in both
places.

## Three rules these files follow

Each one is a rewrite the proxy performs, and each cost a debugging session.

**One continuous path, never comma-joined patterns.** A path variable binds only
the first pattern in a comma-joined list. The second one still filters the
result, so the numbers look right while its nodes and edges never reach the
canvas — a picture quietly missing half of itself. Query 02 is written as a
closed loop, out through the shared identifier and back through the money, for
exactly this reason.

**No subqueries.** An `EXISTS { ... }` block contains its own pattern, and the
rewrite splits on keywords rather than parsing, so a nested block lands in the
wrong half and Spanner rejects the result. Query 03 expresses the same
constraint as one path instead.

**Keep `MATCH`, `RETURN` and `LIMIT` out of the comments.** The split is
case-insensitive and does not know what a comment is, so the word `match` in
ordinary prose is enough to corrupt the statement. Kineviz strips comments
before sending, so this only bites when a file is posted to the proxy directly —
which is worth staying safe against anyway.

## What ordering and row caps cost

The rewrite discards everything after the projection, so `ORDER BY`, `GROUP BY`,
`NEXT` and `FILTER` do not survive. Ranking and totals live in [`../`](../),
which is why both sets exist rather than one replacing the other.
