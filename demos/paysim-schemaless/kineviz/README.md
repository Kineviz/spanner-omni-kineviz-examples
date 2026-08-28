# The live dashboard

[`paysim-live.dashboard.json`](paysim-live.dashboard.json) is a Kineviz Dashboard
whose numbers come from Spanner Omni and re-run every 2 seconds. Start the
stream and the KPIs climb without anyone touching anything — the replay takes
about two minutes end to end.

```bash
./scripts/install-dashboard.sh
./gxr stream up paysim-schemaless
```

Then open the Dashboard icon in the left rail → **PaySim · live**.

No project id to copy out of the URL: the script finds the Kineviz that is
running and, among its projects, the one **connected to this demo's proxy** —
not merely the one opened most recently, which would install into whatever you
happened to look at last. If several projects point at this demo, the most
recently active wins; if none does, it stops and tells you which Database Proxy
projects it did find.

It finds Kineviz Desktop the way Desktop finds itself: Desktop persists its port
to `<userData>/desktop-settings.json` (see `desktop/desktop-settings.js`), so
that file is read first, then `KINEVIZ_DESKTOP_PORT`, then Desktop's default
31380, then the ports a dev server binds. Override either half when you need to:

```bash
./scripts/install-dashboard.sh <projectId>              # force the project
./scripts/install-dashboard.sh --url http://host:port   # force the server
```

The install itself does what pressing Save does — `mkdir` `/dashboards`, write
the spec, rewrite `/dashboards/_index.json` — so the dashboard appears in the
library like any other. It reads the manifest first, so it never deletes someone
else's dashboards, and a re-install keeps your favourite flag and rail pin.

## What is in it

| widget | source | what it shows |
|---|---|---|
| Transactions landed | `db`, 2s | `COUNT(*)` of `:transaction` — the number that climbs |
| Volume moved | `db`, 2s | `SUM(amount)` over everything landed |
| Fraudulent transactions | `db`, 2s | `COUNTIF(isfraud)`, amber at 10, red at 25 |
| Selected on canvas | `canvasSelection` | live with the selection, no timer involved |
| By action | `db`, 2s | bar chart, five PaySim actions, busiest first |
| Fraud, newest first | `db`, 2s | the feed, newest 12 |

## Two rules for any query you add

Both are real constraints of the path, not style. Break either and the widget
shows an error rather than data.

**1 · The first thing after `RETURN` must be `something.` or `something(`.**

The proxy decides graph-vs-SQL with a regex
([`spanner.py:281`](https://github.com/Kineviz/graphxr-database-proxy)): a query
counts as a *graph* query — and gets rewritten into `MATCH __p=… RETURN
SAFE_TO_JSON(__p)` — unless a property accessor or a function call follows
`RETURN` immediately. A `DISTINCT` in between is enough to break it.

```
RETURN COUNT(*) AS landed              ✅ COUNT( → SQL, returns a table
RETURN STRING(t.action) AS action      ✅ STRING( → SQL
RETURN t.amount AS amount              ✅ t.      → SQL
RETURN DISTINCT t.action AS action     ❌ rewritten into a path query
```

**2 · Return scalars, never whole nodes.**

`resolveDb` reads `result.rows` without checking the result type
(`web/libs/Dashboard/gxrData.ts`), and on a GRAPH payload that getter throws. A
`db` widget must project scalar columns. Returning `n` gets you *"QueryResult.rows:
this is a GRAPH result"* in the widget body.

That is the difference between these files and [`../queries/canvas/`](../queries/canvas/),
which exist precisely to return nodes and edges — those go in the **Query** tab
and draw on the canvas. Dashboards read rows; the canvas reads shapes.

There is also a **6-second timeout** per db query (`DB_TIMEOUT_MS`). The
aggregates here run in about 0.1s over 12k transactions, so there is room, but a
query that fans out across every edge will hit it.

## Why the chart does not blink

It keeps its ECharts instance between refreshes. Rebuilding one per poll —
`dispose()` then `init()` — blanks the canvas for a frame, which reads as a
blink, and throws away the transition ECharts would otherwise animate from the
old values to the new ones. Now each refresh is a `setOption` on the live
instance, merged rather than replaced, so bars grow into their new heights.

The bar widget sorts by **value**, so categories re-rank as the replay runs and
the bars trade places. That is deliberate — the ranking is part of what there is
to watch — and it is also what makes the order deterministic: the query has no
`ORDER BY`, so without a sort the categories would arrive in whatever order
Spanner returns a `GROUP BY` in, which is not guaranteed stable between runs.

## About the refresh

`refresh: { mode: "interval", everyMs: 2000 }` is what makes these widgets live.
It has been in the dashboard spec since 2.1, and until recently nothing
implemented it — a source could ask to poll, validate, save, and then sit still
forever. The timer now exists in `DashboardPanel.tsx`, driven by `pollIntervalMs`
in `shared/dashboard/spec.ts`.

Two things worth knowing about how it behaves:

- **One timer per dashboard**, at the fastest interval any source asked for. A
  tick re-resolves every widget, not only the polling ones. Cheap — canvas and
  inline sources resolve from memory.
- **2 seconds is the floor** (`INTERVAL_FLOOR_MS`). A lower `everyMs` is raised
  to it rather than honoured. The floor guards the project database against a
  spec that would hammer it; it is not a pacing preference. These queries take
  ~0.1s, so a 2s poll is a 5% duty cycle.

You can also set it from the GUI now: the **Re-run** dropdown under a db source's
query. Editing the query does not clear it.
