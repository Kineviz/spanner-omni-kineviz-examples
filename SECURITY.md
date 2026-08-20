# Security

## Reporting a vulnerability

Email **security@kineviz.com**. Please do not open a public issue for a security report.

## What this repo is

Example code and documentation. It runs a **Spanner Omni** deployment on **your** hardware. It
creates no cloud resources, uses no cloud credentials, and contains no secrets — and it never
should.

## The thing to understand about Spanner Omni preview

**The preview build has no TLS and no authentication.** The endpoint speaks plain text and
checks nothing. Anyone who can reach `localhost:15000` — or wherever you put it — can read and
write every database on that deployment.

That is a property of the preview build, not of this repo, and it is not something a
configuration flag fixes. Encrypted deployments exist but are gated behind early access
through Google's consulting team.

Practical consequences, in order of how badly they bite:

- **Keep a deployment on loopback**, or inside a network you would already trust with
  unauthenticated database access. Every default in this repo is `localhost`, deliberately.
- **Do not expose it alongside a proxy that is reachable from the internet.** Route A in
  [`connect/`](connect/) puts `graphxr-database-proxy` in front of the deployment. If you move
  that proxy somewhere routable, the endpoint behind it must not follow.
- **Do not put real data on one.** No backups, no restores, and writes stop after 90 days.
  Everything in `demos/` is synthetic and regenerable from a seed for exactly this reason.

## Handling credentials

There are none, and that is the point — no service account, no key file, no IAM roles.

If a demo ever does need one:

- **Never commit it.** `.env.example` holds defaults; `.env` is gitignored. CI blocks both
  secret contents (gitleaks) and credential filenames.
- **Agents never handle credentials.** See `AGENTS.md`: an agent does not create the Kineviz
  account, does not sign in, and does not echo a key.

## If you find a credential in this repo

Report it as above and treat it as live: assume it is compromised and needs rotating, even if
it looks like a placeholder.

## Resource exhaustion as a safety property

A demo that fills a laptop's disk is a real harm, even with no bill attached. Every demo here
declares what it consumes under `cost.local_resources`, generates a bounded dataset, and ships
a teardown that drops what it created. Never raise a demo's data volume to make something
look more impressive.
