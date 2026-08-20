# Spanner Omni + Kineviz

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces — the Google Cloud Marketplace listing, the
> `graphxr.kineviz.com` portal, and screenshots in this repo — still show the former name.

[Spanner Omni](https://docs.cloud.google.com/spanner-omni/overview) is the downloadable
Spanner: the same distributed database, the same GoogleSQL, the same
[Spanner Graph](https://docs.cloud.google.com/spanner/docs/graph/overview) and GQL, running on
a container on your laptop, in your data centre, or in someone else's cloud. No Google Cloud
project. No billing account. No request leaving the host.

This repo puts a property graph in one and gets it onto the Kineviz canvas. Two ways in — pick
the one that matches why you're here.

---

### 🔌 I have my own Spanner Omni graph

**→ [`connect/`](connect/)** — the two routes that reach a Spanner Omni deployment from
Kineviz today, and how to prove your graph is good before you try either.

### 📊 Show me what this looks like

**→ [`demos/`](demos/)** — worked examples. Each stands up a deployment, builds a graph,
verifies it with a real query, and hands you questions to ask.

---

## Demos

<!-- BEGIN GENERATED DEMOS -->

| Demo | What it shows | Level | Time | Cost |
|---|---|---|---|---|
| [`edge-fleet`](demos/edge-fleet/) _(preview)_ | Build a Spanner property graph of a synthetic edge fleet — sites, gateways, devices, firmware and the technicians who cover them — in a Spanner Omni deployment on your own machine, then find what actually falls over when one box does. The premise Omni is for: the data never leaves the site. | intermediate | 12 min | free |
| [`fraud-rings`](demos/fraud-rings/) _(preview)_ | Build a Spanner property graph of synthetic P2P payments in a Spanner Omni deployment on your own machine, then find the accounts that share a device and move money between themselves. No cloud account, no bill, nothing leaves the laptop. | beginner | 15 min | free |

<!-- END GENERATED DEMOS -->

Generated from each demo's `demo.yaml` — edit that, not this table.

## Quick start

```bash
git clone https://github.com/Kineviz/spanner-omni-kineviz-examples
cd spanner-omni-kineviz-examples
./gxr omni up                          # pulls ~1 GB the first time
cd demos/fraud-rings && cp .env.example .env && cd -
./gxr up fraud-rings
```

`./gxr up` runs preflight, starts the deployment if it isn't running, builds the graph,
verifies it with the demo's own headline query, and then tells you what to do in Kineviz.
Prefer to see each command? Every demo README has a step-by-step section with the literal
`docker` and `spanner` calls.

## What you need

1. **Docker** — Engine 24.0+ or Docker Desktop. The deployment is a container.
2. **Python 3.9+** — standard library only. Nothing to `pip install`; every database
   operation goes through the CLI inside the image.
3. **Hardware.** Spanner Omni wants **4 vCPU, 16 GB RAM and ~20 GB of disk**. This is the
   real cost here, and it is the one that will actually bite you.
4. **A Kineviz account** — [sign up](https://www.kineviz.com/). Kineviz Desktop is **free
   for individual use, forever**; the app requires sign-in. Only needed at the last step.
5. **[Kineviz Desktop](https://github.com/Kineviz/kineviz-desktop/releases)** v0.17.1+ —
   Windows, macOS, or Linux.

> **Spanner Omni is pre-GA**, under Google's Pre-GA Offerings Terms — development, testing,
> prototyping and demonstration only. Three limits shape everything here: **no TLS and no
> auth**, **writes stop 90 days after a deployment is created**, and **no backups**. Read
> [`docs/PREVIEW_NOTES.md`](docs/PREVIEW_NOTES.md) before you build on it.

## Connecting Kineviz — read this before you start

**Kineviz has no native Spanner Omni connector yet.** Its Spanner connector authenticates with
a Google service account and talks to `spanner.googleapis.com`; an Omni deployment is an
endpoint on a host you control, with no credentials, whose project and instance are both fixed
to the literal string `default`.

[`connect/`](connect/) documents the two routes that do work:

| | Route A — database proxy | Route B — CSV export |
|---|---|---|
| **What you get** | Live GQL from the canvas | A snapshot |
| **Needs** | [`graphxr-database-proxy`](https://github.com/Kineviz/graphxr-database-proxy) plus one drop-in driver file, shipped here | Nothing beyond this repo |
| **Good for** | Anything you'll query more than once | A demo, a screenshot, a one-off |

Start with B to see the graph; move to A when you want to keep asking questions.

## Cost

**Nothing in this repo is billable.** No cloud resources are created, so there is no invoice
to be surprised by — which makes this the cheapest way to try Spanner Graph that exists.

What it does consume is your machine. Budget 4 vCPU, 16 GB RAM and ~20 GB of disk for the
deployment, plus ~600 MB and 16 GB RAM for Kineviz Desktop. Details in
[`docs/COSTS.md`](docs/COSTS.md).

```bash
./gxr down <demo>          # drops the demo's database
./gxr omni destroy --all   # removes the deployment and every database on it
```

## Using an agent

Point Claude Code, Codex, or Cursor at this repo — [`AGENTS.md`](AGENTS.md) tells it how to
stand a demo up. It will start the deployment, build the graph, verify with a real query, and
hand back. Three things it won't do, by design: create your Kineviz account, install Desktop,
or sign in for you.

## Repo layout

| Path | |
|---|---|
| [`connect/`](connect/) | Reach your own Omni graph from Kineviz — standalone |
| [`demos/`](demos/) | Worked examples |
| [`docs/`](docs/) | Costs, troubleshooting, pre-GA notes |
| [`AGENTS.md`](AGENTS.md) | Agent entry point |
| `gxr` | `list · deps · omni · preflight · up · verify · down · doctor` |
| `shared/lib/omni.sh` | Everything that drives the deployment |
| `tools/` | `check_contract.py`, `selftest.sh`, `preview.sh`, `gen_index.py` |

## Related

- [`spanner-kineviz-examples`](https://github.com/Kineviz/spanner-kineviz-examples) — managed
  Spanner Graph, where the native Kineviz connector does exist
- [`bigquery-kineviz-examples`](https://github.com/Kineviz/bigquery-kineviz-examples) —
  BigQuery Graph
- [`kineviz-desktop`](https://github.com/Kineviz/kineviz-desktop) — the app
- [`graphxr-database-proxy`](https://github.com/Kineviz/graphxr-database-proxy) — the
  middleware Route A uses

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Demo suggestions welcome — the dataset must be public
or synthetic.

## License

[MIT](LICENSE)
