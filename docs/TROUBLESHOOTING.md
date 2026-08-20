# Troubleshooting

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces still show the former name.

Problems that span demos. Demo-specific issues are in each demo's README.

## Start here

```bash
./gxr doctor                                              # structural checks, same as CI
./gxr omni status                                         # is it running, what is on it
./connect/verify.sh --database D --graph G                # is the graph good
```

`connect/verify.sh` tells you which side is at fault, and prints the graph's real labels.

## The deployment

**`Cannot connect to the Docker daemon`**

Everything here is a container. Start Docker first: `open -a Docker` on macOS,
`sudo systemctl start docker` on Linux. Docker Desktop can take a minute or two to become
usable after the UI appears — `docker ps` hanging rather than failing is the tell.

**The first `./gxr omni up` takes minutes**

It is pulling ~1 GB. `docker logs spanneromni` shows progress. Later starts take seconds.

**`connection refused` on localhost:15000 right after starting**

The container reports itself up before the servers finish electing. `./gxr omni up` polls for
you; if you are driving Docker by hand, allow 20–30 seconds.

**The container is healthy but nothing can connect — macOS or Windows**

You almost certainly used `--network host`, which Google's setup page documents and which is
right on Linux only. Off Linux the engine runs inside a VM, so `--network host` binds the VM's
loopback rather than yours. Publish the ports instead:

```bash
docker run -d -p 15000-15026:15000-15026 --name spanneromni -v "spanner:/spanner" \
  us-docker.pkg.dev/spanner-omni/images/spanner-omni:2026.r1-beta.2 start-single-server
```

`./gxr omni up` picks the right form for your platform.

**Port 15000 is already in use**

Change `OMNI_PORT` in the demo's `.env`. The whole range `OMNI_PORT`–`OMNI_CONSOLE_PORT` is
published, so move both together.

**Writes fail; reads are fine**

Check the deployment's age — Spanner Omni stops accepting writes 90 days after a deployment is
created:

```bash
docker inspect -f '{{.Created}}' spanneromni
```

Preflight warns from day 75 and refuses from day 90. Recreate it with `./gxr omni destroy
--all` then `./gxr omni up`, and re-run the demo. See [PREVIEW_NOTES.md](PREVIEW_NOTES.md).

**Everything is slow**

Spanner Omni asks for 4 vCPU and 16 GB RAM. Below that it starts and then behaves badly under
load, which reads as a Spanner problem and is not. On Docker Desktop, check the resource
limits in Settings — the VM's allocation is what counts, not the host's.

## The CLI

**`failed to build statement: invalid statement` on SQL that is obviously valid**

Two causes, both in the CLI's `--sql` handling:

1. The statement contains `--` comment lines.
2. The statement's **first line is indented**. Continuation lines may be; the first may not.
   Writing a query as an indented shell heredoc hits this every time.

`shared/lib/omni.sh` strips both before sending, so this only bites when you call the CLI by
hand.

**A literal `[K` at the start of CLI output**

ANSI erase-line sequences from the CLI's progress display. `omni_clean` in
`shared/lib/omni.sh` strips them; pipe through it if you are scripting against the CLI
yourself.

**The import operation reports an error but the data is there**

Known, and specifically:

```
A step can generate output only if it's not a cleanup step and it's not the
last non-cleanup step of a workflow.
```

`2026.r1-beta.2` reports this on CSV imports that wrote every row correctly — internal
workflow bookkeeping leaking out of a preview build. `omni_wait_operation` downgrades exactly
that message to a warning and lets `verify` decide with a row count. Do not extend that
exception to other messages.

**`(Unspecified)` where a JSON column should be**

The CLI cannot render a JSON-typed column. Wrap it: `SELECT TO_JSON_STRING(col)`.

## Spanner Graph

**`Failed to find element label [X]`**

The most common Spanner Graph error by some margin. **Edge labels are frequently not the table
names** — a table `UsedDevice` may declare `LABEL USED_DEVICE`, and GQL wants the label.
`connect/verify.sh` lists them.

**`TO_JSON_STRING is not supported on values of type GRAPH_NODE`**

Graph elements cannot be serialised as JSON in this build, so the tempting
`MATCH (n) RETURN TO_JSON_STRING(n)` export does not work. `connect/export.py` goes through
the graph metadata and Spanner's bulk CSV export instead.

**`Syntax error: Unexpected keyword AT`**

`AT` is reserved. Don't alias a column `AS at`.

**`Returning expressions of type GRAPH_PATH is not allowed`**

Spanner GQL will not let you `RETURN` a path variable. Return the endpoints and a hop count.

**`Syntax error` on `HAVING`**

GQL has no `HAVING`. Aggregate, then chain: `... GROUP BY x NEXT FILTER agg > n RETURN ...`.

**"The name X is already defined" in a subquery**

You cannot rebind a graph variable inside a subquery. Bind a fresh name and tie it back with
an explicit id filter.

None of these five are Omni-specific — they are Spanner Graph, and they behave identically on
managed Spanner.

## Connecting Kineviz

**Kineviz Desktop's Spanner connector cannot see my deployment**

Correct, and expected. That connector authenticates with a Google service account and talks to
`spanner.googleapis.com`. Use one of the two routes in [`../connect/`](../connect/) instead.

**`NotFound: Database not found` when the database plainly exists**

Project and instance must both be the literal string `default`. Typing your own GCP project
into a proxy's Project ID field produces exactly this.

**`TLS/mTLS connection requires ca_certificate to be set for Spanner Omni`**

A client library was pointed at the deployment without `use_plain_text=True`. The preview build
serves no TLS.

**`experimental_host` is deprecated / unexpected**

Google's docs show `experimental_host=`; the client has moved to
`client_options={"api_endpoint": ...}` plus `instance_type="omni"`. Both work on 3.69;
`connect/proxy/spanner_omni_driver.py` handles either.

**Desktop won't sign in**

An account is required, free for individual use. [Sign up](https://www.kineviz.com/).

## Getting help

[Open an issue](https://github.com/Kineviz/spanner-omni-kineviz-examples/issues/new?template=demo-bug.yml)
with the demo, the step, the full error including its `REMEDIATION:` line, and your versions —
Kineviz Desktop, the Spanner Omni image tag, your OS, and Docker.

**Never paste data you did not mean to share.**
