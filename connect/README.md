# Connect Kineviz to your own Spanner Omni graph

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces — the Google Cloud Marketplace listing, the
> `graphxr.kineviz.com` portal, and screenshots in this repo — still show the former name.

**You have a Spanner property graph in a Spanner Omni deployment and want to see it in
Kineviz.** That's this page.

Want a worked example instead, built for you from synthetic data? See [`../demos/`](../demos/).

---

## The proxy holds one Spanner connection, not one per request

`graphxr-database-proxy` builds a fresh driver for every HTTP call, and a Spanner
`Database` is not a cheap handle: it opens a gRPC channel and starts a background
thread to keep its multiplexed session alive. One per request is one thread per
request — measured at ~1.35 leaked threads per query against this deployment. A
proxy left serving a 2-second dashboard reached **9,217 threads**, stopped
answering, and pushed the host into swap; before that it exhausted its file
descriptors and died with `[Errno 24] Too many open files`.

Tearing the handle down per request does not work. `DatabaseSessionsManager.close()`
ends with `self._multiplexed_session.delete()`, an RPC the preview build of Spanner
Omni never answers, so the call blocks forever and wedges the request. Setting the
terminate event by hand does not help either: the maintenance loop is a plain
`sleep(600)` rather than a wait on the event, so the thread ignores it for up to
ten minutes and they pile up regardless.

So `connect/proxy/spanner_omni_driver.py` caches one client per
(endpoint, database) and `disconnect()` releases only this request's references.
The Spanner client is documented as thread-safe, and this is what every other
database driver does with a connection. Measured after: threads flat at 27 across
60 queries and six schema fetches, descriptors flat too.


## Read this first

**Kineviz has no native Spanner Omni connector yet.** Its Spanner connector authenticates
with a Google service account and talks to `spanner.googleapis.com`; a Spanner Omni
deployment is an endpoint on a host you control, with no credentials in the preview build,
and a project and instance both fixed to the literal string `default`. Those do not meet.

So this page is not the usual six-click walkthrough. It is two routes that do work today:

| | Route A — database proxy | Route B — CSV export |
|---|---|---|
| **What you get** | Live GQL from the canvas | A snapshot |
| **Needs** | [`graphxr-database-proxy`](https://github.com/Kineviz/graphxr-database-proxy) plus one drop-in driver file | Nothing beyond this repo |
| **Credential on the laptop** | No — the proxy holds the connection | No — there is no credential |
| **Good for** | Exploring, iterating, anything you'll query more than once | A demo, a screenshot, a one-off |
| **Not good for** | — | Anything you want to re-query as data changes |

Start with **B** if you just want to see the graph. Move to **A** when you want to keep
asking questions.

---

## Before you start

**1. A Spanner Omni deployment with a property graph in it.** Created with
[`CREATE PROPERTY GRAPH`](https://docs.cloud.google.com/spanner/docs/graph/set-up) — the same
DDL as managed Spanner, because it is the same database. If you have no graph yet,
[`../demos/fraud-rings/`](../demos/fraud-rings/) builds one from synthetic data in about
fifteen minutes.

> **Spanner Omni is pre-GA**, under Google's
> [Pre-GA Offerings Terms](https://cloud.google.com/terms/service-terms) — development,
> testing, prototyping and demonstration only. Three limits shape everything below:
>
> - **No TLS.** The preview build speaks plain text and checks no credentials. Anyone who
>   can reach the endpoint can read and write every database on it.
> - **Writes stop after 90 days.** A deployment stops accepting writes 90 days after you
>   create it. Reads keep working.
> - **No backups or restores.** Treat the data as reproducible, not precious.
>
> More in [`../docs/PREVIEW_NOTES.md`](../docs/PREVIEW_NOTES.md).

**2. A Kineviz account** — [sign up](https://www.kineviz.com/).

Kineviz Desktop is **free for individual use, forever** — no trial clock, no expiry. The app
does require sign-in, so create the account before downloading anything. For team or
commercial use, see [Kineviz licensing](https://www.kineviz.com/).

**3. What you do *not* need.** No Google Cloud project. No billing account. No service
account, no key file, no IAM roles. Spanner Omni runs on hardware you already have, and
nothing in this guide sends a request to Google. That is the reason to use it.

**4. Machines to run it on.** Spanner Omni asks for 4 vCPU, 16 GB RAM and ~20 GB of disk;
Kineviz Desktop wants ~600 MB installed and 16 GB RAM. On one laptop, both at once is
tight but workable at demo scale.

---

## 1 · Stand up Spanner Omni

If you already have a deployment, skip to [step 2](#2--install-kineviz-desktop) — you only
need its endpoint.

From this repo:

```bash
./gxr omni up          # starts the container, waits until it answers
./gxr omni status      # endpoint, console URL, and the databases it holds
```

Or by hand, which is [Google's documented setup](https://docs.cloud.google.com/spanner-omni/setup)
with one change:

```bash
docker volume create spanner

# Linux — host networking, as the docs have it:
docker run -d --network host --name spanneromni -v "spanner:/spanner" \
  us-docker.pkg.dev/spanner-omni/images/spanner-omni:2026.r1-beta.2 start-single-server

# macOS and Windows — publish the ports instead. The engine runs inside a VM
# there, so --network host is the VM's loopback, not yours.
docker run -d -p 15000-15026:15000-15026 --name spanneromni -v "spanner:/spanner" \
  us-docker.pkg.dev/spanner-omni/images/spanner-omni:2026.r1-beta.2 start-single-server
```

The named volume is what makes the data outlive the container. Without it, `docker rm`
silently discards every database.

Three facts you will need for both routes, and which nothing in the UI will infer for you:

| | |
|---|---|
| **Endpoint** | `localhost:15000` by default; ports `15000`–`15025` are the servers |
| **Project** | `default` — fixed by Spanner Omni, not yours to choose |
| **Instance** | `default` — likewise. The CLI takes no `--instance` flag at all |

There is also a read-only web console on `http://localhost:15026`, useful for confirming a
database exists before you blame the connection.

---

## 2 · Install Kineviz Desktop

Download the build for your machine from
[**Releases**](https://github.com/Kineviz/kineviz-desktop/releases) — v0.17.1 or later.

| Platform | File |
|---|---|
| macOS, Apple Silicon | `Kineviz-Desktop-<ver>-mac-arm64.dmg` |
| macOS, Intel | `Kineviz-Desktop-<ver>-mac-x64.dmg` |
| Windows x64 | `Kineviz-Desktop-Setup-<ver>-win-x64.exe` |
| Windows ARM64 | `Kineviz-Desktop-Setup-<ver>-win-arm64.exe` |
| Linux | `Kineviz-Desktop-<ver>-linux-x86_64.AppImage` or the `.deb` |

Not sure which Mac you have: menu → **About This Mac** → **Chip**.

Install, launch, and sign in with the account from *Before you start*.

**Prefer not to install anything?** [The hosted portal](https://graphxr.kineviz.com/) works
the same way — but note that it runs in Kineviz's cloud, so it can only reach a proxy that is
reachable from the internet. If your Omni deployment is on a laptop or inside a private
network, that is a point in favour of Desktop, or of Route B.

---

## 3 · Connect

### Route A — via the database proxy (live GQL)

> **If you are running one of this repo's demos, you do not have to do any of this by hand:**
>
> ```bash
> ./gxr connect up <slug>
> ```
>
> That performs every step in this section — installs the proxy at a pinned commit into a
> gitignored `.connect/`, applies the Omni driver, starts it on loopback, registers the
> database, checks the connection *and* the discovered schema, and prints the URL for
> Desktop. `./gxr connect status` and `./gxr connect down` manage it afterwards. The rest of
> this section is what it does, for your own graph or for when you want to see the parts.

[`graphxr-database-proxy`](https://github.com/Kineviz/graphxr-database-proxy) is Kineviz's
zero-trust middleware: it holds the database connection, exposes an HTTP API, and Kineviz
points at that API instead of at the database. Its Spanner driver builds a client for managed
Spanner, so it needs one file added to speak to Omni.

That file is in this repo: [`proxy/spanner_omni_driver.py`](proxy/spanner_omni_driver.py). It
subclasses the shipped driver and overrides only how the client is constructed, inheriting
schema introspection and query execution unchanged.

> **A wrinkle worth knowing before you debug it.** Google's
> [Python page](https://docs.cloud.google.com/spanner-omni/python) documents
> `experimental_host=`. The client has since deprecated that in favour of
> `client_options={"api_endpoint": ...}` together with `instance_type="omni"` — on 3.69.1 the
> documented form still works but warns. The driver here tries the current API first and
> falls back, so it works on 3.65 through 3.69+. Either way `use_plain_text=True` is
> mandatory: without it the client demands a CA certificate, and the preview build of Spanner
> Omni serves no TLS at all.

**1. Run the proxy**

```bash
git clone https://github.com/Kineviz/graphxr-database-proxy.git
cd graphxr-database-proxy
uv venv
uv pip install --python .venv/bin/python -r requirements.txt
uv pip install --python .venv/bin/python -U 'google-cloud-spanner>=3.65.0'   # Omni support
```

`--python .venv/bin/python` is not decoration. `uv venv` creates the environment but does not
activate it, and a bare `uv pip install` resolves to whatever interpreter uv finds first —
which, if you have conda on your PATH, is the **base conda environment**. It will report
success while upgrading packages system-wide and leaving `.venv` empty, and the failure
surfaces later as `ModuleNotFoundError: No module named 'google'` when you start the proxy.
Either pass `--python` as above, or `source .venv/bin/activate` first.

**2. Add the Omni driver**

```bash
cp ../spanner-omni-kineviz-examples/connect/proxy/spanner_omni_driver.py \
   src/graphxr_database_proxy/drivers/
```

Then register it in `src/graphxr_database_proxy/drivers/factory.py` — one import and one
changed line:

```python
from .spanner_omni_driver import SpannerOmniDriver
...
_drivers: Dict[DatabaseType, Type[BaseDatabaseDriver]] = {
    DatabaseType.SPANNER: SpannerOmniDriver,   # was SpannerDriver
    DatabaseType.ROCKETGRAPH: RocketGraphDriver,
}
```

The file's own docstring carries these instructions too, and names the upstream commit it was
written against — check it before assuming a mismatch is your fault.

**3. Create the proxy project**

```bash
npm run dev      # backend on :9080, web UI on a port webpack picks
```

**Two ports, and only one of them is stable.** `npm run dev` starts both halves: the FastAPI
backend on **9080** (fixed — see `nodemon.uv.json` and the `start` script) and a webpack dev
server for the UI whose port is `process.env.PORT || "auto"`, so it takes 8080 when that is
free and silently moves on when it is not. The UI proxies `/api` straight through to 9080.
Browse the UI on whichever port webpack announces; point *Kineviz* at 9080.

Running the backend on its own, without the UI, is enough for everything below:

```bash
PYTHONPATH=. .venv/bin/python -m uvicorn src.graphxr_database_proxy.main:app \
  --host 127.0.0.1 --port 9080
```

`--host 127.0.0.1` rather than `0.0.0.0`: the proxy holds an unauthenticated plain-text
connection to your deployment, so loopback is the right default unless you have a reason.

Create New Project → Database Type **Google Cloud Spanner**, then:

| Field | Value |
|---|---|
| Host | `localhost` — or wherever the deployment runs |
| Port | `15000` |
| Project ID | `default` — **not your GCP project**, this is fixed by Spanner Omni |
| Instance ID | `default` — likewise |
| Database ID | your database |
| Property Graph | your graph name |

Authentication type is ignored; the preview build has no auth. Fill in whatever the form
insists on — `username_password` with any two strings is fine, and the driver's `connect()`
discards it before it reaches the client.

Project ID and Instance ID are not read from the form either. The driver hardcodes both to
`default`, because honouring a typed-in GCP project would produce a `NotFound` against a
deployment that only ever has `default`. Host, Port and Database ID are the three fields that
actually reach the client.

Prefer not to click through the UI? The same project over the API — no web UI needed:

```bash
curl -X POST http://localhost:9080/api/project/create \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "my-project",
    "database_type": "spanner",
    "database_config": {
      "type": "spanner",
      "host": "localhost",
      "port": 15000,
      "project_id": "default",
      "instance_id": "default",
      "database_id": "my-db",
      "graph_name": "MyGraph",
      "auth_type": "username_password",
      "username": "omni",
      "password": "omni"
    }
  }'
```

It persists to `config/projects.json`, so it survives a restart. `POST /api/project/create`
requires an admin token only when `ADMIN_PASSWORD` is set; with no `.env` it is open.

**4. Point Kineviz at the proxy**

The API URL is the backend, the project name, and nothing else:

```
http://localhost:9080/api/spanner/<project-name>
```

In the web UI it is under **Actions**; you can also just assemble it — the name is the one you
gave the project, not its uuid. In Kineviz Desktop, Create New Project → Database Type
**Database Proxy** → paste the URL → **Connect**.

Prove the URL before you paste it, so a failure has one possible cause instead of two:

```bash
curl -X POST http://localhost:9080/api/spanner/<project-name>/test
# {"success":true,"message":"Connection successful"}

curl http://localhost:9080/api/spanner/<project-name>/graphSchema
# categories and relationships — the graph as Kineviz will see it

curl -X POST http://localhost:9080/api/spanner/<project-name>/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"GRAPH MyGraph MATCH (n) RETURN LABELS(n)[OFFSET(0)] AS label, COUNT(*) AS nodes GROUP BY label ORDER BY nodes DESC"}'
```

`/test` says the client reached the deployment. `/graphSchema` says the property graph is
registered and introspectable. Only the query proves rows come back. Kineviz needs all three,
and they fail in that order.

`LABELS(n)` returns an ARRAY, and GoogleSQL will not group by one — `GROUP BY LABELS(n)` fails
with *Grouping by expressions of type ARRAY is not allowed*. `[OFFSET(0)]` takes the first
label, which is what you want for a node-count-by-label sanity check.

The canvas opens. Hit **Search**, pick a node label, and run it.

**If it does not connect**, split the problem in half before touching the proxy:

```bash
./gxr deps                                    # optional venv; only Route A needs it
./connect/proxy/check_client.py --database my-db --graph MyGraph
```

That connects exactly the way the driver does. If it passes, the client library can reach
your deployment and the fault is in the proxy's configuration — nearly always a Project ID or
Instance ID that is not `default`, or the driver not actually registered in `factory.py`.

### Route B — via a CSV export (works today, nothing to patch)

```bash
./connect/export.py --database my-db --graph MyGraph --out ./export
```

Two files come out — `nodes.csv` and `edges.csv` — in the shape Kineviz's CSV import expects.
Needs Docker and a stdlib Python 3; no client library, nothing to install.

It reads the property graph's own metadata to decide what is a node, what is an edge, what
their labels are and which columns join an edge to its endpoints, then pulls the rows through
Spanner's bulk CSV export. So what you get is what the graph declares — a column that exists
on a table but was left out of the `CREATE PROPERTY GRAPH` does not appear, which is correct:
it is not part of the graph.

Node ids are namespaced by their node table (`Client:C00042`), because two labels in one graph
can perfectly well both key on `id`, and unqualified ids would silently merge them into a
single node on the canvas.

In Kineviz Desktop: Create New Project → **CSV** → load `nodes.csv`, then `edges.csv`, mapping
`source` and `target` to the node `id`.

It is a snapshot. Re-run the export when the data changes; there is no live link. If you find
yourself re-running it more than twice, that is the signal to set up Route A.

---

## 4 · Use the Kineviz Agent

**There is nothing to connect.** The Agent inherits whatever the project is already
connected to. Once Desktop is talking to your graph
through Route A, the Agent can see it: the client sends the project id and
`gxr.getDatabaseSchema()` in the socket handshake, and refreshes that snapshot as the canvas
changes, so the live schema and canvas state are already in the Agent's context.

**The Agent needs Desktop attached.** Its main lever is `runJavaScript` against the `gxr`
API, which runs in the browser/Desktop client. A cloud session with no Desktop bridge
attached is told so explicitly and cannot touch the canvas.

**The Agent's built-in database knowledge is KoreDB, not Spanner.** Its system prompt asserts
KoreDB naming unconditionally, and the only database skill it ships with is KoreDB's. Pointed
at a Spanner-backed project it will reach for KoreDB Cypher, which is close enough to GQL to
look right and fails in ways that read like a broken database.

Fix that by installing the skill in this repo:

```bash
mkdir -p "<your project folder>/.agents/skills"
cp -r skills/spanner-graph-gql "<your project folder>/.agents/skills/"
```

Skills are read from `<project folder>/.agents/skills/`. Start a new chat afterwards. You do
not need to load it by hand — the Agent reads skill descriptions and pulls in the body when
one is relevant, so asking a GQL question is enough. See [`../skills/`](../skills/).

### Things worth asking it

Once the graph is on the canvas:

- *"What node labels and relationship types does this graph have, and how many of each?"* —
  a good first question, and on a schemaless graph the answer comes from the data rather than
  from a schema.
- *"Find accounts that share an SSN, email or phone with another account, and show me which
  of those also transfer money to each other."* — the fraud-ring question. Ask it to put the
  result on the canvas, not in a table.
- *"Lay the result out so the rings are visible, and colour nodes by label."*
- *"One of these clusters is an innocent family sharing a phone. Which one, and how can you
  tell from the graph?"* — the question the whole demo exists for.
- *"Add a node with a label that doesn't exist yet, then re-read the schema."* — on a
  schemaless graph this works without a schema change. That is the pitch, demonstrated.

---

## Verify

Check the graph is reachable and queryable *before* involving Kineviz — that way, when
something does not work, you know which side is at fault:

```bash
./connect/verify.sh --database my-db --graph MyGraph
```

It opens the database, confirms the property graph is registered, prints the graph's **real
labels**, and runs an actual GQL query. If this passes and Kineviz still cannot see the graph,
the problem is the route, not Spanner Omni.

Note there is no `--project` and no `--instance` — Spanner Omni fixes both to `default`.

---

## Troubleshooting

**`Cannot connect to the Docker daemon`**

The deployment is a container. Start Docker first — `open -a Docker` on macOS,
`sudo systemctl start docker` on Linux — and wait for it to report ready.

**`connection refused` on localhost:15000**

Either nothing is running (`./gxr omni status`), or the container is up but the servers have
not finished electing — that takes 20–30 seconds after start. `./gxr omni up` waits for you.

On macOS and Windows, also check you published the ports. `--network host` binds inside
Docker's VM, not on your machine, so the container looks healthy and the endpoint is
unreachable.

**`ModuleNotFoundError: No module named 'httpx'` — and the Spanner route stops working**

Nothing to do with Spanner. The proxy's `factory.py` imports *every* driver at module load,
so a dependency missing for a driver you do not use still takes down the one you do: the
RocketGraph driver needs `httpx`, and if it is absent the import fails before the Spanner
driver is ever registered. Reinstall the proxy's current requirements — not a subset:

```bash
.venv/bin/python -m pip install -r requirements.txt
```

`./gxr connect up` does this on every run for exactly this reason.

**Kineviz shows a single category called `GraphNode` instead of your labels**

Only affects **schemaless** graphs. The proxy has two schema paths: static introspection from
`INFORMATION_SCHEMA`, and a schemaless path that discovers labels by reading data. It picks
the second only when the graph's metadata declares a dynamic label. One undifferentiated
`GraphNode` category means it took the static path, so check the DDL still says
`DYNAMIC LABEL (label)`.

Every schemaless failure mode returns **HTTP 200**. An empty or wrong schema
arrives as `success: true`, so "no error" is not evidence. `./gxr connect up` inspects the
returned categories and warns rather than letting it pass.

**A schemaless property is missing from Kineviz's schema panel but queries fine**

Expected, not a bug. The proxy samples **one row per label** to learn property names. In a
schemaless graph two nodes with the same label need not carry the same keys, so a property
present on only some of them may not appear in the panel. Querying it works regardless.

**`experimental_host` is an unexpected keyword argument**

The Spanner client predates Omni support. Install `google-cloud-spanner>=3.65.0` — in this
repo, `./gxr deps`; in the proxy's environment,
`uv pip install --python .venv/bin/python -U 'google-cloud-spanner>=3.65.0'`.

**`ModuleNotFoundError: No module named 'google'` right after a successful install**

`uv pip install` went somewhere other than `.venv`. `uv venv` does not activate anything, and
uv falls back to the first interpreter it resolves — with conda on your PATH, that is the base
conda environment, which it will happily upgrade instead. Check where it landed:

```bash
uv pip install --python .venv/bin/python -r requirements.txt   # the fix
.venv/bin/python -c "from importlib.metadata import version; print(version('google-cloud-spanner'))"
```

The install log names its target — `Using Python 3.x environment at: ...` — on every run. If
that line is not your `.venv`, nothing you install is going to the proxy.

**Kineviz cannot reach the proxy URL, but the web UI works fine**

Almost certainly the port. The backend is on **9080**; the webpack dev server that serves the
UI takes `PORT` or auto-assigns, so the address bar you are copying from may be 8080, 8081 or
anything else, and it only reaches the API by proxying to 9080. Kineviz Desktop is not going
through that dev server. Use `http://localhost:9080/api/spanner/<project-name>` and confirm it
with `curl -X POST .../test` first.

**`TLS/mTLS connection requires ca_certificate to be set for Spanner Omni`**

You pointed a client at the deployment without `use_plain_text=True`. The preview build serves
no TLS, so the client's default insistence on it cannot be satisfied. This is the error you
get from writing the connection by hand; the driver in `proxy/` passes the flag.

**`failed to build statement: invalid statement` from the CLI**

Not your SQL. `databases execute-sql --sql=` rejects `--` comment lines, and rejects a
statement whose first line is indented — indented *continuation* lines are fine. Both are easy
to hit when pasting a formatted query. `verify.sh` and the demo scripts strip them for you.

**`NotFound: Database not found` when the database plainly exists**

Almost always the project or instance. Both must be the literal string `default`. Typing your
own GCP project into the proxy's Project ID field produces exactly this error — the driver in
`proxy/` ignores that field for this reason, so if you are seeing it, check the driver is
actually registered.

**`Failed to find element label [X]`**

The most common Spanner Graph error by some margin. **Edge labels are frequently not the table
names** — a table `UsedDevice` may declare `LABEL USED_DEVICE`, and GQL wants the label.
`verify.sh` lists the real ones.

**Writes fail; reads are fine**

Check the deployment's age. Spanner Omni stops accepting writes 90 days after a deployment is
created. Recreate it (`./gxr omni destroy --all`, then `./gxr omni up`) and reload.

**The hosted portal cannot reach my proxy**

Expected if the proxy is on your laptop. The portal runs in Kineviz's cloud and can only reach
a proxy the internet can reach. Use Kineviz Desktop, or put the proxy somewhere routable —
and if you do, remember the Omni endpoint behind it is unauthenticated plain text, so it must
not be exposed alongside.

**Desktop won't sign in**

An account is required, and it's free for individual use.
[Sign up](https://www.kineviz.com/), then sign in.

**Still stuck?**
[Open an issue](https://github.com/Kineviz/spanner-omni-kineviz-examples/issues/new?template=demo-bug.yml)
with the error and your versions — Kineviz Desktop, the Omni image tag, and your OS. Never
paste data you did not mean to share.

---

## What's next

- [`../demos/`](../demos/) — worked examples that build a graph for you
- [`../docs/PREVIEW_NOTES.md`](../docs/PREVIEW_NOTES.md) — what pre-GA actually costs you
- [Spanner Omni docs](https://docs.cloud.google.com/spanner-omni/setup) ·
  [Spanner Graph](https://docs.cloud.google.com/spanner/docs/graph/overview)
- [`spanner-kineviz-examples`](https://github.com/Kineviz/spanner-kineviz-examples) — managed
  Spanner, where the native connector does exist ·
  [`bigquery-kineviz-examples`](https://github.com/Kineviz/bigquery-kineviz-examples)
