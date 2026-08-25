---
name: spanner-graph-gql
description: Spanner Graph GQL reference for Kineviz projects backed by Spanner or Spanner Omni through the database proxy, including schemaless graphs that use DYNAMIC LABEL and DYNAMIC PROPERTIES. Use when writing or debugging GQL against a Spanner-backed project — GRAPH/MATCH/NEXT/FILTER syntax, JSON property coercions, label rules — instead of reaching for KoreDB Cypher.
---

# Spanner Graph (GQL) for Kineviz

> **Read this first.** This project is **not** backed by KoreDB. It talks to
> **Spanner Graph** through the Kineviz database proxy, and the query language is
> **GQL** (ISO/IEC 39075), not KoreDB Cypher. The two look alike and are not.
> If you write `MATCH (n:Person) RETURN n.name` you are usually fine; almost
> everything past that differs.

## The single most common mistake

Every GQL statement begins by naming the graph:

```sql
GRAPH PaysimGraph
MATCH (c:client)-[:performs]->(t:transaction)
RETURN c.id, STRING(t.action)
```

Without the `GRAPH <name>` line, nothing runs. The graph name is a property
graph declared in the database — not the database name, and not a table.

## GQL is not Cypher

| You want | Cypher | Spanner GQL |
|---|---|---|
| Filter after aggregating | `HAVING` | `NEXT` then `FILTER` |
| Chain query stages | `WITH` | `NEXT` |
| Return a whole path | `RETURN p` | not supported — return the elements |
| Label on a node | `(n:Person)` | same |
| Any of several edge types | `-[:A\|B]->` | same |
| Variable-length | `-[:R*1..4]->` | `-[:R]->{1,4}` |

Aggregating and then filtering is the one that bites hardest:

```sql
GRAPH PaysimGraph
MATCH (c:client)-[:has_ssn]->(s:ssn)
RETURN STRING(s.name) AS ssn, COUNT(DISTINCT c.id) AS accounts
GROUP BY ssn
NEXT
FILTER accounts > 1
RETURN ssn, accounts
ORDER BY accounts DESC
```

## Schemaless graphs: labels and properties are data

A schemaless Spanner graph declares one node table and one edge table, with
`DYNAMIC LABEL (label)` and `DYNAMIC PROPERTIES (properties)`. The label is a
`STRING` column; the properties are a `JSON` column. Five rules follow, and
four of them fail *silently or confusingly* rather than obviously.

### 1. Dynamic properties are JSON — coerce them

`n.name` on a schemaless node is a JSON value, not a string. Comparing,
aggregating or sorting it fails with `No matching signature for function ...`,
which reads like a missing column.

```sql
STRING(n.name)          -- text
FLOAT64(t.amount)       -- money
LAX_INT64(t.globalstep) -- integers that may be stored loosely
BOOL(m.highrisk)        -- predicates
```

### 2. `id` and `label` are columns, and columns SHADOW dynamic properties

Real columns on the node table are *defined* properties, and defined properties
take precedence over dynamic ones. So `n.id` and `n.label` are plain `STRING`s
that need **no** coercion — and a JSON key that shares a name with a column is
unreachable.

### 3. Use `n.label`, never `LABELS(n)[OFFSET(0)]`

Every schemaless node carries **two** labels: its own, and the table's (e.g.
`GraphNode`). `LABELS()` returns them sorted, so `[OFFSET(0)]` silently yields
`GraphNode` for every label alphabetically after it, and the real label for the
rest. Half-right output, no error. Read the column instead.

(GoogleSQL also refuses to `GROUP BY` an `ARRAY`, so `LABELS()` always needs
indexing anyway.)

### 4. Labels are lowercase

Spanner requires schemaless label values to be stored lowercase; matching is
case-insensitive but storage is not. `MATCH (n:Client)` finds nothing when the
data says `client`.

### 5. A subquery may not redefine an outer element variable

```sql
-- rejected: "The name 'p' is already defined"
WHERE EXISTS { MATCH (p)-[:has_ssn]->(s) }

-- correct: bind a new name, tie it back
WHERE EXISTS {
  MATCH (same:client)-[:has_ssn]->(s)
  WHERE same.id = p.id
}
```

## Comma-joined patterns multiply rows

Two patterns separated by a comma are a join, so they produce one row per
combination. Joining an identity pattern to a money pattern makes a
three-account cluster count every transaction twice, and `SUM(amount)` comes
back doubled — plausible-looking and wrong.

Use `EXISTS` when you mean "does a match exist?" rather than "for every match":

```sql
GRAPH PaysimGraph
MATCH (p:client)-[:performs]->(t:transaction)-[:to_client]->(c:client)
WHERE EXISTS {
        MATCH (same:client)-[:has_ssn]->()<-[:has_ssn]-(other:client)
        WHERE same.id = p.id AND other.id <> p.id
      }
RETURN c.id, ROUND(SUM(FLOAT64(t.amount)), 2) AS total_in
GROUP BY c.id
```

## Discovering the schema

Do not guess labels. Ask the data:

```sql
GRAPH PaysimGraph
MATCH (n) RETURN DISTINCT n.label AS label ORDER BY label
```

```sql
GRAPH PaysimGraph
MATCH (n)-[r]->(m)
RETURN DISTINCT n.label AS from_label, r.label AS edge, m.label AS to_label
ORDER BY from_label, edge
```

In Kineviz, `gxr.getDatabaseSchema()` returns the categories and relationships
the proxy discovered, which for a schemaless graph it found by reading data.
Note it samples **one row per label**, so a property present on only some nodes
may be missing from that schema even though it queries fine.

## Working inside Kineviz

- `runJavaScript` against the `gxr` API is the lever; batch related steps into
  one call.
- Query results reach the canvas as nodes and relationships when the query
  returns graph elements. A query that returns only scalars comes back as a
  table.
- The proxy rewrites a graph-shaped query into a path projection internally, so
  prefer returning elements (`RETURN n, r, m`) when you want something drawn,
  and scalars when you want a table.

## Spanner Omni specifics

- Project and instance are both the literal string `default`. There is no other
  value, and the connector ignores anything else typed into those fields.
- The preview build has **no TLS and no authentication**. It must stay on a
  network you control.
- A deployment stops accepting **writes** 90 days after it is created. Reads
  keep working, which is what makes it confusing.
- The Omni CLI cannot render a `JSON` column — it prints `(Unspecified)`.
  Project scalars out of the JSON rather than returning `n.properties`.
- `TO_JSON_STRING` on a graph element is unsupported *through the CLI*; through
  a client library `TO_JSON` / `SAFE_TO_JSON` work normally.

## Reference

- [Spanner Graph overview](https://docs.cloud.google.com/spanner/docs/graph/overview)
- [Manage schemaless data](https://docs.cloud.google.com/spanner/docs/graph/manage-schemaless-data)
- [GQL schema statements](https://docs.cloud.google.com/spanner/docs/reference/standard-sql/graph-schema-statements)
