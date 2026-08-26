-- The four statements behind 05-prove-schemaless.gql, ready to run.
--
-- Paste them one at a time into the Kineviz Query tab: the first two add a node
-- type and an edge type with no DDL, the last two put it back. Each answers
-- rows_affected 1. Between them, re-run 05-prove-schemaless.gql and it goes
-- from sixteen nodes to seventeen.
--
-- All four together also run in `./gxr omni sql kineviz-paysim-demo`, which
-- takes semicolon-terminated statements. `gxr omni query` does not: it submits
-- a file as a single statement.

INSERT INTO GraphNode (id, label, properties)
VALUES ('regulator_R01', 'regulator',
        JSON'{"name": "Financial Conduct Authority", "jurisdiction": "UK"}');

INSERT INTO GraphEdge (id, dest_id, edge_id, label, properties)
VALUES ('client_C0394', 'regulator_R01', 'sar1', 'reported_to',
        JSON'{"filed": "2026-02-01", "reason": "structuring"}');

DELETE FROM GraphEdge
WHERE id = 'client_C0394' AND dest_id = 'regulator_R01' AND edge_id = 'sar1';

DELETE FROM GraphNode
WHERE id = 'regulator_R01';
