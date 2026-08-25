-- Proof that this is really a schemaless graph, in one statement.
--
-- The obvious check proves nothing. `MATCH (n) RETURN DISTINCT n.label` tells
-- you a column called `label` has seven values in it — and a perfectly ordinary
-- static graph could have a column called `label` too. What cannot be faked is
-- the GAP between what the catalog knows and what the data contains.
--
-- This is plain SQL, not GQL, which is why it is .sql and not .gql: the schema
-- half reads INFORMATION_SCHEMA, and the data half reaches into the graph with
-- GRAPH_TABLE so both can be one result set. Run it like any other query file:
--
--     ../../../gxr omni query kineviz-paysim-demo 05-prove-schemaless.sql
--
-- Expected:
--
--     source      dynamic_label_column  labels
--     the schema  label                 GraphNode
--     the data    label                 bank, client, email, merchant,
--                                       phonenumber, ssn, transaction
--
-- Two facts in one result. The graph DECLARES a dynamic label column, and the
-- catalog knows exactly ONE label while the data carries seven. The labels are
-- not in the schema, because in this graph labels are not schema.
--
--
-- THE CONTROL, if you want to see the other side of it
--
-- Run the same shape against the standard-schema demo:
--
--     ../../../gxr omni query kineviz-fraud-demo 05-prove-schemaless.sql   # after
--                                       # swapping PaysimGraph -> FraudGraph
--
-- The schema half comes back with dynamic_label_column NULL and every real
-- label listed — the catalog knows everything. The data half does not even
-- compile, and the error is the clearest statement of the difference anywhere
-- in this repo:
--
--     Property label is not exposed by element type
--     GRAPH_NODE(FraudGraph)<category STRING, email STRING, first_seen DATE,
--     id STRING, kind STRING, name STRING, opened_date DATE, risk_tier STRING>
--
-- That angle-bracket list is the whole schema, frozen at CREATE time. Adding to
-- it takes a DDL migration.
--
--
-- THE LIVE PROOF — the one nobody argues with
--
-- Add a node type and an edge type with no DDL, no schema update and no
-- restart. These are DML, so they go through the CLI: the database proxy runs
-- everything in a read-only snapshot and answers "DML statements may not be
-- performed in single-use transactions". Writes come from the CLI or an
-- application; you watch the result arrive in Kineviz.
--
--     ./gxr omni sql kineviz-paysim-demo        (semicolons required)
--
--     INSERT INTO GraphNode (id, label, properties)
--     VALUES ('regulator_R01', 'regulator',
--             JSON'{"name": "Financial Conduct Authority", "jurisdiction": "UK"}');
--
--     INSERT INTO GraphEdge (id, dest_id, edge_id, label, properties)
--     VALUES ('client_C0394', 'regulator_R01', 'sar1', 'reported_to',
--             JSON'{"filed": "2026-02-01", "reason": "structuring"}');
--
--     GRAPH PaysimGraph
--     MATCH (c:client)-[r:reported_to]->(g:regulator)
--     RETURN STRING(c.name) AS client, STRING(g.name) AS regulator,
--            STRING(g.jurisdiction) AS jurisdiction, STRING(r.reason) AS reason;
--
-- A node type and an edge type that did not exist, queryable by label, seconds
-- later. Re-run this file and the data side now lists eight labels. Reload the
-- schema in Kineviz and `regulator` is a category — no restart, no migration.
--
-- Undo:
--
--     DELETE FROM GraphEdge WHERE id='client_C0394'
--       AND dest_id='regulator_R01' AND edge_id='sar1';
--     DELETE FROM GraphNode WHERE id='regulator_R01';

WITH schema_side AS (
  SELECT
    'the schema' AS source,
    IFNULL(JSON_VALUE(t, '$.dynamicLabelExpr'), '(none - labels are fixed)') AS dynamic_label_column,
    (SELECT STRING_AGG(JSON_VALUE(x), ', ')
       FROM UNNEST(JSON_QUERY_ARRAY(t, '$.labelNames')) AS x) AS labels
  FROM INFORMATION_SCHEMA.PROPERTY_GRAPHS AS pg,
       UNNEST(JSON_QUERY_ARRAY(pg.PROPERTY_GRAPH_METADATA_JSON, '$.nodeTables')) AS t
  WHERE pg.PROPERTY_GRAPH_NAME = 'PaysimGraph'
),
data_side AS (
  SELECT
    'the data' AS source,
    'label' AS dynamic_label_column,
    ARRAY_TO_STRING(ARRAY_AGG(label ORDER BY label), ', ') AS labels
  FROM GRAPH_TABLE(PaysimGraph MATCH (n) RETURN DISTINCT n.label AS label)
)
SELECT * FROM schema_side
UNION ALL
SELECT * FROM data_side
