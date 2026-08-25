-- Proof that this is really a schemaless graph, in one statement.
--
-- The obvious check proves nothing: `MATCH (n) RETURN DISTINCT n.label` says a
-- column called `label` holds seven values, and a static graph could have a
-- column called `label` too. What cannot be faked is the GAP between what the
-- catalog knows and what the data contains.
--
--     source      dynamic_label_column  labels
--     the schema  label                 GraphNode
--     the data    label                 bank, client, email, merchant, ...
--
-- Two facts in one result: the graph DECLARES a dynamic label column, and the
-- catalog knows exactly one label while the data carries seven. The labels are
-- not in the schema, because here labels are not schema.
--
-- Plain SQL, not GQL — hence .sql. The schema half reads INFORMATION_SCHEMA and
-- the data half reaches into the graph with GRAPH_TABLE, which is what lets a
-- single statement hold both. (TO_JSON_STRING is unsupported on ARRAY<STRING>
-- in 2026.r1-beta.2, so both sides aggregate to plain strings.)
--
-- To watch it happen rather than read it, run ../scripts/prove-schemaless.sh:
-- it adds a node type with no DDL, asserts this query's schema row is unchanged
-- while its data row grows, and puts the dataset back.
--
-- The control: point this at the standard-schema demo (swap PaysimGraph for
-- FraudGraph, run against kineviz-fraud-demo). It does not return two rows —
-- it does not compile at all, and the error is the point:
--
--     Property label is not exposed by element type GRAPH_NODE(FraudGraph)
--     <category STRING, email STRING, first_seen DATE, id STRING, kind STRING,
--      name STRING, opened_date DATE, risk_tier STRING>
--
-- That angle-bracket list is the entire schema, frozen at CREATE time; there is
-- no `label` to read because labels are not data there. Run the schema_side CTE
-- on its own against that graph and it comes back with a NULL dynamic column
-- and every label named, which is the same fact from the other side.

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
