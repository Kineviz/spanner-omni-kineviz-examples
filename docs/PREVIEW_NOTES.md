# Spanner Omni is pre-GA — what that actually costs you

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces still show the former name.

Spanner Omni is in **preview**, covered by Google's
[Pre-GA Offerings Terms](https://cloud.google.com/terms/service-terms): "developing, testing,
prototyping, and demonstrating" only. Every demo in this repo is `status: preview` for that
reason, and the contract checker rejects a demo that claims otherwise — a demo cannot be more
stable than the thing it runs on.

This page is the short list of limits that will actually bite, rather than a restatement of
the terms.

## The three that change how you build

**1. No TLS, and no authentication.**

The preview build speaks plain text and checks no credentials. Anyone who can reach the
endpoint can read and write every database on the deployment. Encrypted deployments exist but
are gated behind early access through Google's consulting team.

The practical rule: keep a deployment on loopback, or inside a network you already trust with
unauthenticated database access. Do not put one on a shared host, and do not expose it
alongside a proxy that *is* reachable from the internet. Every script in this repo defaults to
`localhost`, and that default is doing real work.

**2. Writes stop 90 days after a deployment is created.**

Not 90 days of use — 90 days from creation. Reads keep working, so the failure is quiet: your
graph is still there and still queryable, and the next load silently has nowhere to go.

If a demo that worked last quarter starts failing at the load step, check the deployment's age
before anything else:

```bash
docker inspect -f '{{.Created}}' spanneromni
```

The fix is to recreate it, which is cheap because nothing here holds state you cannot
regenerate:

```bash
./gxr omni destroy --all      # container AND volume
./gxr omni up
./gxr up <demo>
```

**3. No backups, no restores.**

Treat everything on an Omni deployment as reproducible. That is why every demo generates its
data from a seed rather than shipping a dump, and why teardown deleting a database is not a
big deal. Do not put anything on a preview deployment that you could not rebuild.

## Smaller limits worth knowing

| | |
|---|---|
| **Client libraries** | Java, Go and Python only. No Node, no C++, no .NET |
| **Python client** | `>=3.65.0` — the release that added `experimental_host` |
| **Console** | Read-only. `http://localhost:15026`. Writes go through the CLI or a client library |
| **Query plan visualization** | Not available |
| **Change streams** | Supported, but the Dataflow integration is not |
| **Full-text search** | Supported; enhanced query mode is not |
| **Sessions** | Multiplexed only |

## The image tag

The default in this repo is pinned:

```
us-docker.pkg.dev/spanner-omni/images/spanner-omni:2026.r1-beta.2
```

Pinned, never `:latest`, and CI fails the repo if that changes. A preview image's tag moves,
the CLI and the schema move with it, and an unpinned demo breaks with nothing in git to
explain why. Newer tags exist in the registry before they are documented — bump `OMNI_VERSION`
deliberately, re-run the demos, and update `last_verified` in the same commit.

## What is *not* a preview limitation

Worth separating, because it is easy to blame preview for things that are simply Spanner:

- **`Failed to find element label [X]`** — edge labels are not table names. Same in managed
  Spanner. `connect/verify.sh` prints the real ones.
- **GQL has no `HAVING`** — aggregate, then chain with `NEXT ... FILTER`. Same in managed
  Spanner.
- **You cannot `RETURN` a path variable** — return the endpoints and a hop count. Same in
  managed Spanner.
- **`AT` is a reserved keyword** — don't alias a column `AS at`.

Everything in `demos/*/sql/` and `demos/*/queries/` is ordinary Spanner DDL and GQL. Move to
managed Spanner and it runs unchanged; that portability is the point of Omni, and it is the
half of the story that is not a caveat.

## Where this is checked

- `tools/check_contract.py` rejects `status: stable` and requires every demo README to say
  the backend is pre-GA.
- Each demo's `preflight.sh` warns about the 90-day window and the missing TLS *before*
  anything is created.
- Each demo's `handoff.sh` repeats both at the end, when the person is about to point a tool
  at it.

Three times is deliberate. Someone who reads only the handoff block still learns it.
