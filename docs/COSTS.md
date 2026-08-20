# What this repo costs

> **Kineviz** (formerly **GraphXR**) is Kineviz's graph visualization and analytics
> platform. Some product surfaces still show the former name.

**Nothing here is billable.** No cloud resources are created, so there is no invoice to be
surprised by. That makes Spanner Omni the cheapest way to try Spanner Graph that exists, and
it is a real answer to "we can't put this data in someone else's cloud."

The cost is your machine. This page is about that, because a demo that quietly fills a laptop
is a real harm even with no bill attached.

## Against the other repos in this family

| | Billing | Idle cost | The thing that bites |
|---|---|---|---|
| **BigQuery** | per byte scanned | nothing | a runaway query |
| **Spanner** (managed) | provisioned capacity, per hour | **the full rate** | an instance left running |
| **Spanner Omni** | **nothing** | nothing | your RAM and disk |

If you came from `spanner-kineviz-examples`, the mental shift is that there is no instance to
leave running and forget about. If you came from `bigquery-kineviz-examples`, there is no
`maximum_bytes_billed` to set, because there is no meter.

## What a deployment consumes

Google's [system requirements](https://docs.cloud.google.com/spanner-omni/system-requirements),
for a single-server development deployment:

| | |
|---|---|
| **CPU** | x86-64, or Apple Silicon on macOS |
| **RAM** | 4 GB per vCPU allocated — 16 GB for the 4-vCPU minimum |
| **Disk** | 20+ GB on Linux, 10 GB for a macOS developer setup |
| **Image** | ~1 GB pulled once |
| **Ports** | `15000`–`15025` for the servers, `15026` for the console |

Kineviz Desktop is on top of that: ~600 MB installed, 16 GB RAM. Running both on one laptop
works at demo scale and is tight beyond it.

Under the minimum, the deployment starts and then behaves badly under load — slow queries that
look like a Spanner problem and are not.

## What the demos create

| Demo | Creates | Consumes |
|---|---|---|
| `fraud-rings` | one **database** on a deployment you run | a few MB — 620 nodes, ~3,300 edges |

**No demo creates a deployment behind your back** in the sense that matters: `setup` will
start the container if it isn't running, and says so, but it never provisions anything metered
and never touches the volume.

## Teardown

```bash
./gxr down <demo>
```

Drops the demo's database and deletes its generated CSVs. **It never removes the container or
the volume** — the volume holds every database on the deployment, including any you built
yourself, so throwing it away to clean up one demo is not teardown's call.

To remove the deployment entirely, which is a separate and deliberate act:

```bash
./gxr omni destroy          # container only; databases survive in the volume
./gxr omni destroy --all    # container AND volume — every database goes
```

Both ask first.

## The one recurring cost that isn't money

A Spanner Omni deployment **stops accepting writes 90 days after it is created**. Reads keep
working, so nothing looks broken until the next load silently has nowhere to go. Budget on
recreating it — which is cheap, because every demo regenerates its data from a seed. See
[PREVIEW_NOTES.md](PREVIEW_NOTES.md).

## If something surprised you

Open an issue. An unexpected resource bill — RAM, disk, or hours of your afternoon — from an
example repo is a bug in the example.
