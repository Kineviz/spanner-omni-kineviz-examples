# Canvas queries

The same four questions as [`../`](../), returning **nodes and edges** instead of
rows, so the answer arrives on the Kineviz canvas as a shape rather than a table.

| | Question | File | Draws |
|---|---|---|---|
| 1 | What hangs off each gateway? | [`01-blast-radius.gql`](01-blast-radius.gql) | ~940 nodes — the whole fleet |
| 2 | Who covers which site? | [`02-lone-cover.gql`](02-lone-cover.gql) | 142 nodes |
| 3 | Who is exposed to the advisory? | [`03-advisory-exposure.gql`](03-advisory-exposure.gql) | 41 nodes |
| 4 | What falls over with what? | [`04-cascade.gql`](04-cascade.gql) | 291 nodes |

Paste one into the **Query** tab of the Kineviz query panel and run it. Query 1
draws the entire fleet on purpose: concentration is the finding, and one gateway
is visibly fatter than the rest.

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

Each is a consequence of that rewrite, and each cost a debugging session.

**One continuous path, never comma-joined patterns.** A path variable binds only
the first pattern in a comma-joined list. The second still filters the result,
so the numbers look right while its nodes and edges never reach the canvas — a
picture quietly missing half of itself.

**No subqueries and no second pattern clause.** The rewrite splits on keywords
rather than parsing, so a nested block lands in the wrong half and Spanner
rejects the statement.

**Keep `MATCH`, `RETURN` and `LIMIT` out of the comments.** The split is
case-insensitive and does not know what a comment is, so one of those words in
ordinary prose is enough to corrupt the statement. Kineviz strips comments
before sending, so this only bites when a file is posted to the proxy directly.

## What ordering and counts cost

The rewrite discards everything after the projection, so `ORDER BY`, `GROUP BY`,
`NEXT` and `FILTER` do not survive. Ranking and totals live in [`../`](../),
which is why both sets exist rather than one replacing the other.
