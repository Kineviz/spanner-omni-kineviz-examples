-- Two tables and one property graph — the whole schemaless demo.
--
-- Applied by scripts/setup.sh via `spanner databases ddl update --ddl-file`,
-- which submits the file as one DDL batch. It is plain Spanner GoogleSQL, the
-- same statements you would run against managed Spanner, because Spanner Omni
-- is the same database.
--
-- WHAT IS DIFFERENT HERE, AND WHY IT MATTERS
--
-- A standard Spanner property graph names a table per node type and a table per
-- edge type (see demos/fraud-rings/sql/01_schema.ddl for that shape). This one
-- names two tables, total. The label is a STRING column, the properties are a
-- JSON column, and DYNAMIC LABEL / DYNAMIC PROPERTIES tell Spanner to read the
-- graph out of the data rather than out of the schema.
--
-- The consequence worth demoing: adding a node type is an INSERT. No DDL, no
-- schema update, no downtime.
--
-- Three rules this file obeys, from
-- https://docs.cloud.google.com/spanner/docs/graph/manage-schemaless-data
--
--   * AT MOST ONE node table and ONE edge table may use DYNAMIC LABEL. That is
--     why transactions are reified into nodes: a PaySim transaction's receiver
--     may be a client, a merchant or a bank, and one edge table cannot bind
--     three destination types any other way.
--   * Label values and property names must be stored LOWERCASE. Matching is
--     case-insensitive, storage is not.
--   * Only TOP-LEVEL keys of the JSON become properties. Nested objects are
--     data, not properties.
--
-- The dynamic-label column must be STRING and the dynamic-property column must
-- be JSON. Both are named exactly as Google's example names them (`label`,
-- `properties`) — the database proxy's schemaless path reads `properties.label`
-- by that literal name, so renaming the column silently degrades the labels it
-- shows Kineviz.
--
-- No ${PLACEHOLDERS}: the database name is an argument to the loader, not part
-- of the DDL, so this file is used verbatim.

CREATE TABLE GraphNode (
  id         STRING(MAX) NOT NULL,
  label      STRING(MAX) NOT NULL,
  properties JSON,
) PRIMARY KEY (id);

-- INTERLEAVE IN PARENT co-locates every edge with its source node, so a
-- traversal out of a node is a local read rather than a distributed one.
CREATE TABLE GraphEdge (
  id         STRING(MAX) NOT NULL,
  dest_id    STRING(MAX) NOT NULL,
  edge_id    STRING(MAX) NOT NULL,
  label      STRING(MAX) NOT NULL,
  properties JSON,
) PRIMARY KEY (id, dest_id, edge_id),
  INTERLEAVE IN PARENT GraphNode;

CREATE PROPERTY GRAPH PaysimGraph
  NODE TABLES (
    GraphNode
      DYNAMIC LABEL (label)
      DYNAMIC PROPERTIES (properties)
  )
  EDGE TABLES (
    GraphEdge
      SOURCE KEY (id) REFERENCES GraphNode(id)
      DESTINATION KEY (dest_id) REFERENCES GraphNode(id)
      DYNAMIC LABEL (label)
      DYNAMIC PROPERTIES (properties)
  );
