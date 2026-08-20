# Contributing

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces still show the former name.

Two audiences read this repo: a person following a README, and an agent following
[`AGENTS.md`](AGENTS.md). Everything below exists to keep both working.

## The rule that matters most

**The scripts are the single source of truth, and neither audience has a step the other
lacks.**

- `./gxr up <slug>` is the fast path for *people too*, not an agent shortcut.
- Every scripted step also appears in the demo README as the literal commands, in order,
  copy-pasteable. That serves the person who wants to understand it, the person in a
  restricted environment who cannot run an unreviewed script, and the reviewer who wants to
  see the API calls without reading bash. `docs-drift.yml` fails a PR where the two diverge.
- Nothing that matters lives only in a script. Decisions and gotchas go in the README prose
  **and** in `demo.yaml`.

## Dependencies: keep the floor at Docker and stdlib Python

A demo you have to `pip install` into before you can read it is a demo fewer people run. The
CLI inside the Spanner Omni image can create databases, apply DDL, run SQL and GQL, and bulk
import CSV — so the demos use it, and the only hard dependencies are Docker and a Python 3.9+
interpreter.

`./gxr deps` exists for the Spanner *client library*, which no demo needs. It is there for the
`connect/` database-proxy route and for people writing their own client code. Adding a demo
that requires it needs a reason in the PR.

## Adding a demo

```bash
cp -r demos/fraud-rings demos/my-demo   # nearest thing to a template
$EDITOR demos/my-demo/demo.yaml
./gxr doctor            # structural checks, same as CI
./tools/selftest.sh     # behavioural checks, no deployment needed
./tools/preview.sh      # see your README rendered before pushing
```

`contract.yml` will reject a PR that misses any of:

- The required files (`demo.yaml`, `README.md`, all five scripts, executable).
- A `demo.yaml` that validates against `schema/demo.schema.json`.
- The README headings, in order.
- The naming note (below).
- A statement, somewhere in the demo README, that Spanner Omni is pre-GA.
- A link to `connect/` — and **no inlined copy** of the connect steps.
- A `teardown.sh` and a `creates:` list.

## Script rules

Non-negotiable, most are CI-checked:

- **`set -euo pipefail`** at the top. Checked.
- **Executable.** Checked. Libraries under `shared/lib/` must *not* be — they are sourced.
- **Idempotent.** Re-running `setup.sh` after a partial failure converges. Both people and
  agents retry.
- **Non-interactive.** No prompts; inputs come from `.env` or flags. The one exception is
  `teardown`, which always confirms.
- **One `REMEDIATION:` line on failure.** Use `die "what broke" "what to do"`. Agents relay it
  verbatim, so it must be actionable by the person, not by the agent.
- **`--json` supported.** `source shared/lib/common.sh` gives you this free.
- **`verify.sh` asserts, it does not describe.** Run a real query, check a row count. This
  matters more here than in the cloud repos: the preview build's CSV import reports a spurious
  error on loads that succeeded, so an operation's own status is evidence of nothing. The row
  count is the check.
- **`preflight.sh` creates nothing.** It runs before anything exists, and it should say so
  when it fails.
- **`teardown.sh` deletes exactly what `setup.sh` created**, from the `creates:` list, and
  nothing else. See below.
- **Readable.** Commented, no clever one-liners. A person should be able to read `setup.sh`
  and learn to do it by hand.

## Teardown must never touch the deployment

The hard rule of this repo, and CI enforces it: a demo's `teardown.sh` may not run
`docker rm` or `docker volume rm`.

The volume holds **every** database on the deployment — other demos', and whatever the person
built themselves. Deleting it to clean up one demo destroys unrelated work to reclaim a few
megabytes. Dropping the demo's own database is the whole job. Removing the deployment lives in
`./gxr omni destroy`, where a person asks for it explicitly.

## The image tag is pinned

```
OMNI_VERSION=2026.r1-beta.2
```

Never `:latest`, and CI fails on it. A preview image's tag moves, the CLI and the schema move
with it, and an unpinned demo breaks with nothing in git to explain why. Newer tags appear in
the registry before they are documented — bump `OMNI_VERSION` deliberately, re-run every demo,
and update `last_verified` and `verified_with` in the same commit.

## Data

- **5 MB per demo, committed.** Above that, ship `data/generate.py` with a fixed seed. No Git
  LFS — it makes forking worse, and forking is how these repos get used.
- **Synthetic or public data only.** Never customer data, never anything under NDA. This is
  doubly true here: a preview deployment has no auth, no TLS and no backups.
- **Emit Spanner's CSV import layout** — one headerless CSV per table plus `csv-export.json`.
  That is what `spanner databases import --format=csv` expects, and it is what
  `spanner databases export --format=csv` produces, so the two stay symmetric.
- **A generated dataset must contain the finding its queries claim.** `fraud-rings` plants two
  rings *and* one innocent lookalike, and `verify.sh` asserts both — a demo whose headline
  query returns nothing interesting is worse than no demo.

## Resource claims

Any demo must declare `cost.local_resources` — vCPU, RAM, disk. There is no bill here, so this
is the honest equivalent, and a demo that quietly fills a laptop is a real harm. Never raise a
demo's data volume to make it look more impressive.

## The naming note

GraphXR is a retired brand; the product is Kineviz. The rename is mid-flight — the Marketplace
listing, the portal hostname, and existing screenshots still show the old name — so the note is
what reconciles a UI saying GraphXR with docs saying Kineviz. Without it, someone hitting that
mismatch assumes the docs are stale.

Use this string verbatim, at the top of every README, `AGENTS.md`, `connect/README.md`, and
each `docs/*.md`:

```markdown
> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces — the Google Cloud Marketplace listing, the
> `graphxr.kineviz.com` portal, and screenshots in this repo — still show the former name.
```

In prose, always write Kineviz. Leave proper nouns alone — the Marketplace listing name, the
portal hostname, existing repo names — because a reader will click them and must find what the
text promised.

## Don't oversell the connection

Kineviz has no native Spanner Omni connector. Do not write a demo README, a handoff block, or
a doc page that implies picking "Spanner Property Graph" in Desktop will work — it sends people
into a dead end. `connect/README.md` owns the two routes that do work; link it.

If that changes upstream, `connect/README.md` is the one place to update, and every demo
inherits it.

## Kineviz Desktop version

Declare a **floor**, not an exact pin:

```yaml
requires:
  kineviz_desktop: ">=0.17.1"
```

A floor is friendlier to someone already running Desktop and avoids a demo refusing to start
because the person is *ahead*. `desktop-floor.yml` opens a PR when a new release ships;
`last_verified` and `verified_with` record what was actually tested.

## What never goes in these repos

- Customer data, of any kind.
- Credentials. There are none here by design; if you add one, stop and ask why.
- Gated artifacts — no image that needs a password from an engineer.
- Internal material: benchmark submissions, sales decks, roadmaps.
