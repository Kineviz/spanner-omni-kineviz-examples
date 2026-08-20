#!/usr/bin/env python3
"""Check that the Spanner Python client can reach a Spanner Omni deployment.

Route A has two halves that fail in different places: the client library
reaching the deployment, and the proxy being wired up correctly. This tests the
first half on its own, so a failure tells you which one you are looking at.

    ./connect/proxy/check_client.py --database kineviz-fraud-demo --graph FraudGraph

Needs google-cloud-spanner — `./gxr deps` installs it into .venv/, and this
script re-execs itself into that venv if it finds one. Reads only.

It connects exactly the way connect/proxy/spanner_omni_driver.py does, so if
this passes and the proxy still cannot connect, the problem is the proxy's
configuration — most often a Project ID or Instance ID that is not `default`.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

OMNI_PROJECT = "default"
OMNI_INSTANCE = "default"
MIN_CLIENT = "3.65.0"

# Re-exec into the repo venv if we are not already running from it. Saves the
# "works in my shell" confusion when python3 and .venv/bin/python differ.
#
# The test is sys.prefix, not the interpreter path. `.venv/bin/python` is a
# symlink chain ending at the system interpreter, so resolve()-ing both sides
# makes them compare equal and the re-exec never happens — which then fails with
# "google-cloud-spanner is not installed" while it is sitting right there in the
# venv. sys.prefix is the thing that actually differs.
_VENV_DIR = pathlib.Path(__file__).resolve().parents[2] / ".venv"
_VENV_PY = _VENV_DIR / "bin" / "python"
if _VENV_PY.exists() and pathlib.Path(sys.prefix) != _VENV_DIR:
    os.execv(str(_VENV_PY), [str(_VENV_PY), *sys.argv])


def fail(msg: str, remediation: str) -> "None":
    print(f"\n  ✗ {msg}\n    REMEDIATION: {remediation}\n", file=sys.stderr)
    sys.exit(1)


def build_client(endpoint: str):
    """Prefer the current API; fall back to the deprecated one for 3.65–3.68.

    Google's Omni docs still show `experimental_host=`. The client deprecated it
    in favour of `client_options={"api_endpoint": ...}` plus
    `instance_type="omni"`. `use_plain_text=True` is required on both paths —
    without it the client demands a CA certificate and the preview build of
    Spanner Omni serves no TLS at all.
    """
    from google.cloud import spanner

    try:
        return spanner.Client(
            project=OMNI_PROJECT,
            client_options={"api_endpoint": endpoint},
            instance_type="omni",
            use_plain_text=True,
        ), "client_options + instance_type='omni'"
    except TypeError:
        pass
    try:
        return spanner.Client(
            project=OMNI_PROJECT,
            experimental_host=endpoint,
            use_plain_text=True,
        ), "experimental_host (deprecated)"
    except TypeError:
        fail(f"This google-cloud-spanner is too old for Spanner Omni (need >={MIN_CLIENT}).",
             "Run './gxr deps', or in the proxy's environment: uv pip install -U 'google-cloud-spanner>=3.65.0'")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--database", required=True)
    ap.add_argument("--graph", help="optional: also run a GQL count against this graph")
    ap.add_argument("--endpoint", default=os.environ.get("OMNI_ENDPOINT", "localhost:15000"))
    args = ap.parse_args()

    try:
        import google.cloud.spanner as _s
    except ImportError:
        fail("google-cloud-spanner is not installed.", "Run './gxr deps' from the repo root.")

    print(f"\n  client   : google-cloud-spanner {_s.__version__}")
    client, how = build_client(args.endpoint)
    print(f"  connect  : {how}")
    print(f"  endpoint : {args.endpoint}  (plain text, no auth)")
    print(f"  ids      : project={OMNI_PROJECT} instance={OMNI_INSTANCE} database={args.database}")

    db = client.instance(OMNI_INSTANCE).database(args.database)
    try:
        with db.snapshot() as snapshot:
            tables = list(snapshot.execute_sql(
                "SELECT COUNT(*) FROM information_schema.tables "
                "WHERE table_schema = ''"))[0][0]
    except Exception as e:  # noqa: BLE001
        msg = str(e)
        if "NotFound" in msg or "not found" in msg:
            fail(f"Database '{args.database}' not found at {args.endpoint}: {msg[:200]}",
                 "Check the name with './gxr omni status'. Project and instance must both be 'default'.")
        fail(f"Could not query the database: {msg[:200]}",
             "Check the deployment is running: ./gxr omni status")
    print(f"\n  ✓ connected; the database has {tables} table(s)")

    if args.graph:
        with db.snapshot() as snapshot:
            n = list(snapshot.execute_sql(
                f"GRAPH {args.graph} MATCH (n) RETURN COUNT(n) AS c"))[0][0]
        print(f"  ✓ GQL works; graph '{args.graph}' has {n} node(s)")

    print("\n  The client half of Route A is good. If the proxy still cannot connect,")
    print("  the problem is its configuration — check Project ID and Instance ID are")
    print("  both `default`, and that the Omni driver is registered in factory.py.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
