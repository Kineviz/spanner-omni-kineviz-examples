# AGENTS.md

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces — the Google Cloud Marketplace listing, the
> `graphxr.kineviz.com` portal, and screenshots in this repo — still show the former name.
> Say "Kineviz" when you write or speak about it, and carry this note into anything you
> relay to the person.

This repo holds runnable Kineviz examples for **Spanner Omni** — the downloadable Spanner,
running as a container on the person's own machine. Your job is to stand a demo up so a person
can explore it. **You do not explore it for them.**

## Start here

```bash
./gxr list          # what demos exist, and their status
./gxr omni status   # is a deployment already running, and what is on it
./gxr up <slug>     # preflight → setup → verify → handoff
```

Read `demos/<slug>/demo.yaml` before running anything. It is the runbook: required inputs,
required CLIs, the ordered steps, what gets created, and what teardown removes.

## What is different here from the cloud repos

If you have worked in `spanner-kineviz-examples` or `bigquery-kineviz-examples`, three things
change:

- **There is no cloud account.** No project id to collect, no billing confirmation, no IAM.
  Do not ask for a GCP project — there isn't one, and asking suggests the person needs
  something they don't.
- **The expensive resource is the person's hardware**, not an invoice. Spanner Omni wants
  4 vCPU, 16 GB RAM and ~20 GB of disk. If a demo is slow, that is the first thing to check.
- **The deployment is shared state.** One container, one volume, every database on it. Demos
  add and drop *databases*; the deployment itself belongs to the person.

## Two doors — pick the right one

- The person **has their own graph** and wants Kineviz pointed at it → send them to
  [`connect/`](connect/). Do not run a demo. Do not restate the connect steps; link them.
- The person **wants to see an example** → `./gxr up <slug>`.

## The sequence

`preflight → setup → verify → handoff`. Always in order, always via `./gxr up`.

- **preflight** checks Docker, the CLI, the database id, and the deployment's age *before*
  anything is created. If it fails, nothing has been created — say so.
- **setup** is idempotent. It starts the deployment if needed, applies the schema, clears and
  reloads. If it fails partway, re-run it; do not hand-patch around it.
- **verify** asserts with a real query and a row count. **Never report success without it.**
  Absence of errors is not success. This matters more here than usual: the preview build's
  CSV import reports a spurious error on loads that worked, so the operation's own status is
  not evidence either way. The row count is.
- **handoff** prints the block you relay verbatim. Then you stop.

The streaming leg (`./gxr stream up|status|down`) comes **only after a successful
`up`**: the producer replays the CSV that setup generated, and the sink writes
edges whose parent nodes setup seeded. `./gxr stream status` is its verify —
produced vs. lag vs. landed. Never report the stream as working without it.

## Connecting Kineviz — do not oversell this

Kineviz has **no native Spanner Omni connector**. If you tell someone to open Desktop and pick
"Spanner Property Graph", you have sent them into a dead end: that connector authenticates to
`spanner.googleapis.com` and cannot reach a local endpoint.

`connect/README.md` has the two routes that work — the database proxy for live GQL, a CSV
export for a snapshot. Relay the choice; do not invent a third.

For a demo in this repo, the proxy route is one command: `./gxr connect up <slug>`. It
installs the proxy at a pinned commit into a gitignored `.connect/`, starts it on **loopback
only**, registers the database, and prints the URL. Run it rather than walking someone
through the manual steps — but the manual steps stay documented, and they are what you relay
if someone is connecting their own graph.

**The Kineviz Agent is not a second connection.** It inherits whatever the Desktop project is
connected to, so there is nothing to configure and nothing for you to set up. What it does
need is `skills/spanner-graph-gql`, because its built-in database knowledge is KoreDB and it
will otherwise write KoreDB Cypher against a GQL backend. Copy the skill into the project's
`.agents/skills/` and say so; do not claim the Agent is "connected to Spanner", because it is
not — it reads the project's schema and drives the canvas.

## Three things only the person can do

Kineviz Desktop is the documented deployment. You cannot:

1. **Create the Kineviz account.** Never create accounts. Hand over the signup link.
   Desktop is free for individual use, forever — say so when you hand it over.
2. **Install Desktop.** Hand over the exact release asset URL for their OS and architecture.
   Never install it silently.
3. **Sign in.** Never type credentials, never handle the sign-in, ever.

Preflight only *warns* about a missing Desktop rather than stopping, because everything up to
`verify` is useful without it. Do not treat that warning as permission to skip the handover.

## Where you stop

When `handoff.sh` prints, you are done. The person picks a connect route and explores.

Do not narrate exploration you did not do. Do not describe query results you did not run. Do
not click through the Kineviz UI pretending to be the user.

## On failure

Every script exits non-zero with a single `REMEDIATION:` line on stderr. **Relay it
verbatim.** Do not improvise a fix, do not retry with different flags, do not work around a
failing check. If the remediation is something only the person can do, say so plainly.

Pass `--json` to any script for structured status instead of prose.

## Hard rules

- **Never run `./gxr omni destroy`, and never `docker rm` or `docker volume rm` the
  deployment, without explicit confirmation.** The volume holds every database on the
  deployment, including work that has nothing to do with this repo. A demo's teardown drops
  its own database and stops there.
- **Never start a second deployment to work around a problem with the first.** The ports
  collide and you will leave the person with two containers and no explanation.
- Never create the Kineviz account; never touch the sign-in; never install Desktop silently.
- Never run `teardown` without explicit confirmation.
- **Never change `OMNI_VERSION` to make something work.** The image tag is pinned on purpose.
  If a demo fails on the pinned tag, that is a finding to report, not an obstacle to route
  around.
- **`./gxr stream up` deletes the streamed transactions before replaying. That is its
  job — but it is still a delete.** It touches only `:transaction` nodes and the four edge
  labels that hang off them, never actors or identifiers, and never a database other than
  `OMNI_DATABASE`. Do not extend it to clear anything else, and use `--keep` when the point
  is to prove idempotency rather than to watch the graph fill.
- Never edit `demos/*/sql/` or `demos/*/queries/` to make `verify` pass. If the planted
  findings are not there, the data and the schema have drifted apart — that is a bug.
- Never write secrets anywhere but `.env`, which is gitignored. There are no credentials in
  this repo by design; if you find yourself handling one, stop and ask why.
- **Never tell someone to expose the Omni endpoint to a network they do not control.** It has
  no TLS and no authentication. Anyone who can reach it owns every database on it.
