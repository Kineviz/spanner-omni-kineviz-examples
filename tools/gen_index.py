#!/usr/bin/env python3
"""Regenerate the demo matrix in README.md from every demos/*/demo.yaml.

The taxonomy lives in metadata, not in folder names, so the index is generated
rather than hand-maintained. CI runs this with --check and fails if the committed
README is stale.

Usage:
  gen_index.py [repo_root]            rewrite README.md between the markers
  gen_index.py [repo_root] --check    exit 1 if README.md is out of date
"""

from __future__ import annotations

import pathlib
import sys

BEGIN = "<!-- BEGIN GENERATED DEMOS -->"
END = "<!-- END GENERATED DEMOS -->"

STATUS_BADGE = {
    "stable": "",
    "preview": " _(preview)_",
    "pending-upstream": " _(pending)_",
}


def load_yaml(path: pathlib.Path):
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.exit("PyYAML is required: pip install pyyaml")
    with path.open() as fh:
        return yaml.safe_load(fh)


def build_table(root: pathlib.Path) -> str:
    rows = []
    for d in sorted((root / "demos").glob("*/")):
        if d.name.startswith("_"):
            continue
        manifest = d / "demo.yaml"
        if not manifest.exists():
            continue
        m = load_yaml(manifest) or {}
        slug = m.get("slug", d.name)
        cost = (m.get("cost") or {}).get("estimate_usd", 0)
        cost_s = "free" if not cost else f"~${cost:.2f}"
        rows.append(
            "| [`{slug}`](demos/{slug}/){badge} | {summary} | {diff} | {mins} min | {cost} |".format(
                slug=slug,
                badge=STATUS_BADGE.get(m.get("status", "stable"), ""),
                summary=" ".join((m.get("summary") or "").split()),
                diff=m.get("difficulty", "—"),
                mins=m.get("time_minutes", "—"),
                cost=cost_s,
            )
        )

    if not rows:
        return "_No demos yet._"

    return "\n".join(
        ["| Demo | What it shows | Level | Time | Cost |", "|---|---|---|---|---|"] + rows
    )


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    check = "--check" in sys.argv
    root = pathlib.Path(args[0] if args else ".").resolve()

    readme = root / "README.md"
    text = readme.read_text()

    if BEGIN not in text or END not in text:
        print(f"README.md is missing the {BEGIN} / {END} markers")
        return 1

    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    new = f"{head}{BEGIN}\n\n{build_table(root)}\n\n{END}{tail}"

    if new == text:
        print("index up to date")
        return 0
    if check:
        print("README.md demo matrix is stale — run tools/gen_index.py and commit")
        return 1

    readme.write_text(new)
    print("README.md demo matrix regenerated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
