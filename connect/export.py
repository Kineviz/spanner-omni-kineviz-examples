#!/usr/bin/env python3
"""Export a Spanner Omni property graph to CSV that Kineviz can import.

This is the connection route that needs nothing patched and nothing running
alongside it. You get a snapshot rather than a live connection — fine for a
demo, a screenshot, or a machine that will never be allowed to hold a database
credential; not what you want if you plan to keep querying from the canvas. For
live GQL, see connect/README.md § Route A.

Two files come out:

    nodes.csv   id, label, <one column per declared property>
    edges.csv   source, target, label, <one column per declared property>

For a SCHEMALESS graph (DYNAMIC LABEL / DYNAMIC PROPERTIES) the label comes from
its column rather than the schema, and the JSON properties column is expanded
one level into real columns — otherwise every row would export as one category
called `GraphNode` carrying a single unreadable blob.

Node ids are namespaced by their node table — `Client:C00042`, not `C00042` —
because two labels in the same graph can perfectly well both key on `id`, and
an unqualified id silently merges them into one node on the canvas.

HOW IT WORKS, AND WHY NOT THE OBVIOUS WAY

The obvious way is `MATCH (n) RETURN TO_JSON_STRING(n)`, one row per element.
That is unsupported in this build — Spanner Omni 2026.r1-beta.2 answers
"TO_JSON_STRING is not supported on values of type GRAPH_NODE". The next
obvious way is to run per-label queries and parse the CLI's output, but the CLI
renders results as a padded ASCII table, and any value containing whitespace
(`Wren Okafor`) cannot be recovered from it reliably.

So this uses Spanner's own bulk export instead. `databases export --format=csv`
writes real CSV plus a manifest naming each table's columns, and
`information_schema.property_graphs` says which of those tables are nodes,
which are edges, what their labels are, and which columns join an edge to its
endpoints. Nothing is parsed out of terminal output except one line of JSON.

Needs Docker and a stdlib Python 3. No client library, no pip install.

    ./connect/export.py --database kineviz-fraud-demo --graph FraudGraph --out ./export

Reads only. Creates nothing on the deployment beyond a scratch folder inside
the container, which it removes on the way out.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

CLI = "/google/spanner/bin/spanner"
WORKDIR = "/tmp/kineviz/graph-export"
ANSI = re.compile(r"\033\[[0-9;]*[A-Za-z]")


def fail(msg: str, remediation: str) -> "None":
    print(f"\n  ✗ {msg}\n    REMEDIATION: {remediation}\n", file=sys.stderr)
    sys.exit(1)


def docker(container: str, *args: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["docker", "exec", "-i", container, *args],
        capture_output=True, text=True,
    )
    out = ANSI.sub("", proc.stdout + proc.stderr).replace("\r", "")
    if check and proc.returncode != 0:
        fail(f"Command failed inside {container}: {' '.join(args)}\n    {out.strip()[:300]}",
             "Check the deployment is running: ./gxr omni status")
    return out


def spanner(container: str, *args: str, check: bool = True) -> str:
    return docker(container, CLI, *args, check=check)


def graph_metadata(container: str, database: str, graph: str) -> dict:
    """The property graph's metadata, as JSON.

    The CLI cannot render a JSON-typed column — it prints "(Unspecified)" — so
    ask for TO_JSON_STRING of it and pick the one output line that is JSON.
    """
    sql = (
        "SELECT TO_JSON_STRING(PROPERTY_GRAPH_METADATA_JSON) AS m "
        "FROM information_schema.property_graphs "
        f"WHERE property_graph_name = '{graph}'"
    )
    out = spanner(container, "databases", "execute-sql", database, f"--sql={sql}")
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            return json.loads(line)
    fail(f"No property graph named '{graph}' in {database}.",
         "Check the name with ./connect/verify.sh --database DB --graph G. Names are case-sensitive.")


def export_tables(container: str, database: str, out_dir: pathlib.Path) -> dict:
    """Bulk-export every base table to CSV and copy it out of the container.

    Returns {tableName: (csv_path, [column names in file order])}.
    """
    docker(container, "rm", "-rf", WORKDIR, check=False)
    docker(container, "mkdir", "-p", WORKDIR)

    started = spanner(container, "databases", "export", database,
                      f"--url=file://{WORKDIR}", "--format=csv")
    m = re.search(r"_auto_op_[0-9a-f]+", started)
    if not m:
        fail(f"Export did not start: {started.strip()[:300]}",
             "Check the deployment is healthy: ./gxr omni status")
    op = m.group(0)

    deadline = time.time() + 300
    while time.time() < deadline:
        status = spanner(container, "operations", "describe", f"--database={database}", op)
        if re.search(r"done:\s*true", status):
            break
        time.sleep(3)
    else:
        fail(f"Export operation {op} did not finish within 300s.",
             f"Check it by hand: docker exec -it {container} {CLI} operations describe --database={database} {op}")

    subprocess.run(["docker", "cp", f"{container}:{WORKDIR}/.", str(out_dir)],
                   capture_output=True, text=True, check=True)
    docker(container, "rm", "-rf", WORKDIR, check=False)

    manifest_path = out_dir / "csv-export.json"
    if not manifest_path.exists():
        fail("The export produced no csv-export.json manifest.",
             "Re-run; if it persists the database may have no tables yet.")
    manifest = json.loads(manifest_path.read_text())

    tables = {}
    for t in manifest["tables"]:
        name = t["tableName"]
        # filePatterns are relative names in the same folder.
        files = [out_dir / p for p in t["filePatterns"]]
        cols = [c["columnName"] for c in t["columns"]]
        tables[name] = (files, cols)
    return tables


def read_rows(files, columns) -> list[dict]:
    """Spanner's CSV export is headerless; column order comes from the manifest."""
    rows = []
    for path in files:
        if not path.exists():
            continue
        with path.open(newline="") as fh:
            for rec in csv.reader(fh):
                if not rec:
                    continue
                rows.append(dict(zip(columns, rec)))
    return rows


def dynamic_props(raw: str) -> dict:
    """Top-level keys of a JSON properties column, as CSV-safe scalars.

    Spanner models only TOP-LEVEL keys of a dynamic-properties column as graph
    properties, so this flattens exactly one level and no further: a nested
    object stays a JSON string rather than being invented into columns.
    """
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for key, value in data.items():
        if isinstance(value, bool):
            out[key] = "true" if value else "false"
        elif value is None:
            out[key] = ""
        elif isinstance(value, (dict, list)):
            out[key] = json.dumps(value)
        else:
            out[key] = str(value)
    return out


def element_props(table: dict, row: dict, props: list, fallback_label: str):
    """(label, properties) for one row, static or schemaless.

    A schemaless element carries its label in a STRING column and its
    properties in a JSON column (DYNAMIC LABEL / DYNAMIC PROPERTIES). Exporting
    those verbatim would give Kineviz one category called `GraphNode` and a
    single unreadable JSON blob per row, which is technically the data and
    practically useless. So: the dynamic label becomes the label, and the JSON
    is expanded into real columns.
    """
    dyn_label = table.get("dynamicLabelExpr")
    dyn_props = table.get("dynamicPropertyExpr")

    label = fallback_label
    if dyn_label and row.get(dyn_label):
        label = row[dyn_label]

    values = {name: row.get(expr, "") for name, expr in props}
    if dyn_props:
        # The raw JSON column is not a property, and the label column is the
        # category rather than a property of it.
        values.pop(dyn_props, None)
        if dyn_label:
            values.pop(dyn_label, None)
        values.update(dynamic_props(row.get(dyn_props, "")))
    return label, values


def node_id(table: str, values: list[str]) -> str:
    return table + ":" + "|".join(values)


def write_csv(path: pathlib.Path, fixed: list[str], rows: list[tuple[list, dict]]) -> int:
    """Union every property key seen, so a label with extra properties does not
    silently lose them and a label missing one gets an empty cell.

    Property names that collide with our own columns get a `_prop` suffix. This
    is not hypothetical: a node table keyed on `id` almost always also declares
    `id` as a property, which would otherwise emit two columns called `id` — and
    a CSV importer will keep one of them, with no way to know which.
    """
    reserved = set(fixed)
    keys, header, seen = [], [], set()
    for _, props in rows:
        for k in props:
            if k in seen:
                continue
            seen.add(k)
            keys.append(k)
            header.append(f"{k}_prop" if k in reserved else k)
    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(fixed + header)
        for head, props in rows:
            w.writerow(head + [props.get(k, "") for k in keys])
    return len(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--database", required=True)
    ap.add_argument("--graph", required=True)
    ap.add_argument("--out", default="export", help="output directory (created if absent)")
    ap.add_argument("--container", default=os.environ.get("OMNI_CONTAINER", "spanneromni"))
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    meta = graph_metadata(args.container, args.database, args.graph)

    scratch = pathlib.Path(tempfile.mkdtemp(prefix="omni-export-"))
    try:
        tables = export_tables(args.container, args.database, scratch)

        # --- nodes ---------------------------------------------------------
        # Remember each node table's key columns; edges are resolved against them.
        node_keys: dict[str, list[str]] = {}
        nodes: list[tuple[list, dict]] = []
        for nt in meta.get("nodeTables", []):
            base = nt["baseTableName"]
            keys = nt["keyColumns"]
            node_keys[nt["name"]] = keys
            label = (nt.get("labelNames") or [nt["name"]])[0]
            props = [(p["propertyDeclarationName"], p["valueExpressionSql"])
                     for p in nt.get("propertyDefinitions", [])]
            if base not in tables:
                fail(f"Node table '{base}' was not in the export.",
                     "The graph and the schema have drifted apart. Re-run the demo's setup.")
            files, cols = tables[base]
            for row in read_rows(files, cols):
                ident = node_id(nt["name"], [row.get(k, "") for k in keys])
                row_label, values = element_props(nt, row, props, label)
                nodes.append(([ident, row_label], values))

        # --- edges ---------------------------------------------------------
        edges: list[tuple[list, dict]] = []
        for et in meta.get("edgeTables", []):
            base = et["baseTableName"]
            label = (et.get("labelNames") or [et["name"]])[0]
            props = [(p["propertyDeclarationName"], p["valueExpressionSql"])
                     for p in et.get("propertyDefinitions", [])]
            src, dst = et["sourceNodeTable"], et["destinationNodeTable"]

            # An edge points at a node by whatever columns REFERENCES named. This
            # exporter identifies a node by its key columns, so the two have to
            # agree. They do for the ordinary `REFERENCES T(pk)` form. Rather
            # than emit edges that silently point at nothing, say so and stop.
            for side, ref in (("SOURCE", src), ("DESTINATION", dst)):
                want = node_keys.get(ref["nodeTableName"])
                if want is not None and ref["nodeTableColumns"] != want:
                    fail(
                        f"Edge table '{base}' joins its {side} on "
                        f"{ref['nodeTableColumns']}, but node table "
                        f"'{ref['nodeTableName']}' is keyed on {want}.",
                        "This exporter identifies nodes by their key columns, so it cannot "
                        "resolve that edge. Use Route A (the database proxy) for this graph, "
                        "or change the edge to reference the node's primary key.",
                    )

            if base not in tables:
                fail(f"Edge table '{base}' was not in the export.",
                     "The graph and the schema have drifted apart. Re-run the demo's setup.")
            files, cols = tables[base]
            for row in read_rows(files, cols):
                s = node_id(src["nodeTableName"], [row.get(c, "") for c in src["edgeTableColumns"]])
                d = node_id(dst["nodeTableName"], [row.get(c, "") for c in dst["edgeTableColumns"]])
                row_label, values = element_props(et, row, props, label)
                edges.append(([s, d, row_label], values))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    n = write_csv(out / "nodes.csv", ["id", "label"], nodes)
    m = write_csv(out / "edges.csv", ["source", "target", "label"], edges)

    print(f"  {out}/nodes.csv   {n} node(s)")
    print(f"  {out}/edges.csv   {m} edge(s)")
    print("\n  Import in Kineviz Desktop: Create New Project → CSV → nodes.csv, then")
    print("  edges.csv, mapping `source` and `target` to the node `id`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
