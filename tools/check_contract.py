#!/usr/bin/env python3
"""Enforce the repo contract. Run by CI and by `./gxr doctor`.

Checks, in order of how often they catch something real:

1. Every demo has the required files.
2. Every demo.yaml validates against schema/demo.schema.json.
3. Every README has the required headings, in order.
4. The "formerly GraphXR" naming string is present on every required surface.
5. No demo README inlines the connect steps — they must link to connect/.
6. Teardown removes what setup creates, and nothing wider.
7. The Spanner Omni image tag is pinned, never `:latest`.
8. last_verified is not stale.

Usage: check_contract.py [repo_root]
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import re
import sys

STALE_DAYS = 120

REQUIRED_DEMO_FILES = [
    "demo.yaml",
    "README.md",
    "scripts/preflight.sh",
    "scripts/setup.sh",
    "scripts/verify.sh",
    "scripts/handoff.sh",
    "scripts/teardown.sh",
]

# Order matters — a reader should meet these in this sequence in every demo.
REQUIRED_DEMO_HEADINGS = [
    "What you'll build",
    "At a glance",
    "Architecture",
    "Prerequisites",
    "Quick start",
    "Or do it step by step",
    "Connect Kineviz",
    "Explore",
    "How the graph is modeled",
    "Troubleshooting",
    "Clean up",
    "What's next",
]

REQUIRED_CONNECT_HEADINGS = [
    "Before you start",
    "1 · Stand up Spanner Omni",
    "2 · Install Kineviz Desktop",
    "3 · Connect",
    "Verify",
    "Troubleshooting",
]

# The naming string must appear on every surface someone might hit first.
NAMING_RE = re.compile(r"formerly\s+\*{0,2}GraphXR", re.I)
NAMING_SURFACES = ["README.md", "AGENTS.md", "connect/README.md"]

# Signals that a demo README has copy-pasted the connect walkthrough instead of
# linking it. Keeps the repos in this family from drifting apart.
INLINE_CONNECT_RE = re.compile(
    r"(upload\s+(the\s+)?(service\s+)?account\s+key|select\s+instance.*select\s+graph)",
    re.I | re.S,
)

# Spanner Omni is preview software with a documented 90-day write window and no
# TLS. Every demo has to say so somewhere a reader will hit it.
PREVIEW_RE = re.compile(r"pre-?GA|preview", re.I)

errors: list[str] = []
warnings: list[str] = []


def err(where: str, msg: str) -> None:
    errors.append(f"{where}: {msg}")


def warn(where: str, msg: str) -> None:
    warnings.append(f"{where}: {msg}")


def load_yaml(path: pathlib.Path):
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.exit("PyYAML is required: pip install pyyaml")
    with path.open() as fh:
        return yaml.safe_load(fh)


def headings(md: str) -> list[str]:
    out = []
    for line in md.splitlines():
        m = re.match(r"^#{1,4}\s+(.*)", line)
        if m:
            # strip numbering, bold, trailing punctuation
            h = re.sub(r"^[0-9]+[.·)]\s*", "", m.group(1))
            out.append(h.replace("*", "").strip())
    return out


def check_headings(where: str, md: str, required: list[str]) -> None:
    found = headings(md)
    idx = -1
    for want in required:
        for i, got in enumerate(found):
            if i > idx and want.lower() in got.lower():
                idx = i
                break
        else:
            err(where, f"missing or out-of-order heading: {want!r}")
            return


def _stringify_dates(obj):
    """PyYAML turns an unquoted `2026-08-19` into a datetime.date, which then fails a
    `type: string` schema check. Authors should be able to write natural YAML dates, so
    normalize to ISO strings for validation only."""
    if isinstance(obj, dt.date):
        return obj.isoformat()
    if isinstance(obj, dict):
        return {k: _stringify_dates(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_stringify_dates(v) for v in obj]
    return obj


def validate_schema(where: str, data: dict, schema: dict) -> None:
    try:
        import jsonschema  # type: ignore
    except ImportError:
        warn(where, "jsonschema not installed — skipping schema validation")
        return
    data = _stringify_dates(data)
    validator = jsonschema.Draft7Validator(schema)
    for e in sorted(validator.iter_errors(data), key=lambda e: list(e.path)):
        loc = ".".join(str(p) for p in e.path) or "(root)"
        err(where, f"demo.yaml {loc}: {e.message}")


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

    # --- naming string on every required surface ---------------------------
    for surface in NAMING_SURFACES:
        p = root / surface
        if not p.exists():
            err(surface, "required file is missing")
        elif not NAMING_RE.search(p.read_text()):
            err(surface, 'missing the "Kineviz (formerly GraphXR)" note — see CONTRIBUTING.md')

    for doc in sorted((root / "docs").glob("*.md")):
        if not NAMING_RE.search(doc.read_text()):
            warn(f"docs/{doc.name}", 'missing the "formerly GraphXR" note')

    # --- the image tag is pinned -------------------------------------------
    # `:latest` on a preview image is how a repo silently starts failing: the
    # tag moves, the schema or the CLI changes, and nothing in git did.
    for sh in sorted(root.glob("shared/lib/*.sh")):
        text = sh.read_text()
        if "spanner-omni:latest" in text or re.search(r"OMNI_VERSION:?=\s*latest", text):
            err(f"shared/lib/{sh.name}", "the Spanner Omni image tag must be pinned, never ':latest'")

    # --- connect/ ----------------------------------------------------------
    connect = root / "connect" / "README.md"
    if connect.exists():
        check_headings("connect/README.md", connect.read_text(), REQUIRED_CONNECT_HEADINGS)
        vs = root / "connect" / "verify.sh"
        if not vs.exists():
            err("connect/", "verify.sh is required — it is what proves a connection works")
        elif vs.stat().st_mode & 0o111 == 0:
            err("connect/verify.sh", "not executable (chmod +x)")

    # --- demos -------------------------------------------------------------
    schema_path = root / "schema" / "demo.schema.json"
    schema = json.loads(schema_path.read_text()) if schema_path.exists() else None
    if schema is None:
        err("schema/", "demo.schema.json is missing")

    demo_dirs = [d for d in sorted((root / "demos").glob("*/")) if not d.name.startswith("_")]
    if not demo_dirs:
        warn("demos/", "no demos yet (fine for a fresh template)")

    today = dt.date.today()

    for d in demo_dirs:
        where = f"demos/{d.name}"

        for rel in REQUIRED_DEMO_FILES:
            p = d / rel
            if not p.exists():
                err(where, f"missing required file: {rel}")
            elif rel.startswith("scripts/") and p.stat().st_mode & 0o111 == 0:
                err(where, f"{rel} is not executable (chmod +x)")

        manifest = d / "demo.yaml"
        if manifest.exists():
            data = load_yaml(manifest) or {}
            if schema:
                validate_schema(where, data, schema)

            if data.get("slug") != d.name:
                err(where, f"demo.yaml slug {data.get('slug')!r} != directory name {d.name!r}")

            if data.get("status") != "stable" and not data.get("maturity_note"):
                err(where, "status is not 'stable' but maturity_note is missing")

            # Spanner Omni is pre-GA. A demo claiming 'stable' would be claiming
            # more than the backend does.
            if data.get("status") == "stable":
                err(where, "status 'stable' is not available while Spanner Omni is pre-GA — use 'preview'")

            # Anything the demo creates must be declared and removable.
            creates = [c for s in data.get("steps", []) for c in (s.get("creates") or [])]
            if not creates:
                err(where, "no step declares `creates:` — teardown has nothing to scope itself to")
            if not (d / "scripts/teardown.sh").exists():
                err(where, "no teardown.sh")

            cost = data.get("cost") or {}
            if cost.get("billable_resources") and not creates:
                err(where, "declares billable resources but no step declares `creates:`")

            lv = data.get("last_verified")
            if isinstance(lv, dt.date):
                age = (today - lv).days
                if age > STALE_DAYS:
                    warn(where, f"last_verified is {age} days old — re-run it or mark it pending")

        # --- teardown scope ------------------------------------------------
        teardown = d / "scripts/teardown.sh"
        if teardown.exists():
            t = teardown.read_text()
            # The named volume holds EVERY database on the deployment, including
            # other demos' and the person's own. A demo teardown drops its
            # database; it never removes the volume or the container.
            if re.search(r"docker\s+volume\s+rm", t):
                err(f"{where}/scripts/teardown.sh",
                    "removes the Docker volume — that destroys every database on the deployment, "
                    "not just this demo's. Drop the database instead.")
            if re.search(r"docker\s+rm\b", t):
                err(f"{where}/scripts/teardown.sh",
                    "removes the Spanner Omni container — teardown is scoped to the demo's database. "
                    "Use './gxr omni destroy' for the deployment itself.")

        readme = d / "README.md"
        if readme.exists():
            md = readme.read_text()
            check_headings(f"{where}/README.md", md, REQUIRED_DEMO_HEADINGS)
            if not NAMING_RE.search(md):
                err(f"{where}/README.md", 'missing the "Kineviz (formerly GraphXR)" note')
            if not PREVIEW_RE.search(md):
                err(f"{where}/README.md",
                    "never mentions that Spanner Omni is pre-GA — the 90-day write window and the "
                    "absence of TLS are things a reader has to meet before they build on it")
            if INLINE_CONNECT_RE.search(md):
                err(
                    f"{where}/README.md",
                    "looks like it inlines the connect walkthrough — link to ../../connect/ "
                    "instead, and state only the values this demo needs",
                )
            if "../../connect/" not in md and "connect/README.md" not in md:
                err(f"{where}/README.md", "does not link to connect/")

    # --- report ------------------------------------------------------------
    for w in warnings:
        print(f"warning  {w}")
    for e in errors:
        print(f"ERROR    {e}")

    if errors:
        print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)")
        return 1
    print(f"contract OK ({len(demo_dirs)} demo(s), {len(warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
