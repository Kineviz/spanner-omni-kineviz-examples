# Canvas queries

The same four questions as [`../`](../), returning **nodes and edges** instead of
rows, so the answer arrives on the Kineviz canvas as a shape rather than a table.

| | Question | File |
|---|---|---|
| 1 | Which accounts share an SSN, email or phone? | [`01-shared-identifiers.gql`](01-shared-identifiers.gql) |
| 2 | Which of those also move money to each other? | [`02-fraud-rings.gql`](02-fraud-rings.gql) |
| 3 | Which accounts collect from an identity cluster? | [`03-collector-accounts.gql`](03-collector-accounts.gql) |
| 4 | Where does the value leave the network? | [`04-cash-out.gql`](04-cash-out.gql) |

Paste one into the **Query** tab of the Kineviz query panel and run it. Each is a
single statement; they accumulate on the canvas, so running 1 then 2 leaves the
identity clusters in place and draws the money over them.

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
