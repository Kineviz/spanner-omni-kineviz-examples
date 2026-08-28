# The live dashboard

[`paysim-live.dashboard.json`](paysim-live.dashboard.json) is a Kineviz Dashboard
whose numbers come from Spanner Omni and re-run while the graph fills underneath
them. Start the stream and it moves without anyone touching anything — the replay
takes about two minutes end to end.

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
| Transactions landed | `db`, 2s | the number that climbs |
| Volume moved ($M) | `db`, 2s | divided in the query, so the card does not overflow |
| **Money at risk ($)** | `db`, 2s | fraud volume in dollars |
| **Largest single fraud ($)** | `db`, 2s | the outlier, called out instead of buried |
| **Fraud as % of VALUE** | `db`, 2s | gauge — not the count rate |
| Volume per simulated day | `db`, 2s | stacked, fraud on top of legitimate |
| **Shared identities → rings** | `db`, 10s | how many flagged identities are actually rings |
| **Who moved the fraud money** | `db`, 10s | named accounts, ranked by value |
| **Where ring money lands** | `db`, 10s | receivers of money from identity-sharing accounts |
| % of each size band that is fraud | `db`, 2s | share, not count |
| Taken by mules | `db`, 10s | two hops: victim → transaction → mule |
| Where value leaves | `db`, 10s | high-risk vs normal merchants |
| Selected on canvas | `canvasSelection` | live with the selection |

## Why it looks like this

An earlier version of this dashboard was twelve widgets of accurate statistics that
nobody could act on. Each change below fixes something specific, and each was
measured against the data rather than guessed.

**Value, not count.** Fraud is **0.27%** of transactions and **2.91%** of money —
eleven times worse by the measure a fraud desk answers for. The old gauge showed
0.27, in green. It reported the flattering number.

**One day carries the fraud.** 20 January moves **$251,004 of the month's $321,337**,
78% of it, in two transactions. The old daily chart drew that as a gentle purple
bump with no fraud series and no marker. Now fraud is stacked on top, so the day
stands up.

**A size band that is 100% fraud must not be invisible.** Band `1e5` holds exactly
one transaction: a $250,000 fraudulent TRANSFER, the only band that is entirely
fraud. Counting transactions per band drew it as nothing next to 7,019
legitimate payments in `1e2` — under a title that claimed "fraud lives in the big
bands". Plotting the **share** of each band makes it the tallest bar.

**Fan-in by itself is a popularity contest.** Ranking accounts by distinct senders
put ordinary clients with 12–14 senders on top, while the planted collector —
`client_C0394`, Iris Xavier, a MULE — has a fan-in of **3** and never appeared.
Restricting the senders to accounts that share an identity with someone puts the
ring members first, Iris Xavier second.

**The biggest fraudster was on none of the twelve widgets.** `client_C0388`, Nilo
Gomes, moved **$257,542 across four fraudulent transactions — 80% of all fraud
value**. He is a sender, so fan-in missed him; he is not a mule, so the mule chart
missed him. *Who moved the fraud money* is a table, not a chart, because one
account dwarfs the rest and a bar chart would render the other seven as nothing.

**Flagged and confirmed belong in one picture.** They used to be two unlinked
cards, 8 and 4, with nothing saying that 4 was a subset. One chart now splits the
flagged identities into *ring confirmed* and *innocent so far* — and because
identity edges load up front while money arrives on the stream, the confirmed bar
grows from zero during a replay while the total stays at 8. The bar that never
grows is the Oliveira family: three people who share a phone and never transfer to
each other. That is the false positive a relationship query declines to raise, and
the whole argument for the graph.

**Two charts were removed.** A treemap gave risk — the only variable that mattered
— the smallest tile, an unreadable sliver labelled "R", with merchant names
truncated. A heatmap rendered five populated cells out of eight with overlapping
labels. Both are now single bars that answer their question directly.

### Colour and shape

**Fraud is red, everywhere it is a category** — the daily area chart and the
identity pie. It used to be whatever colour the palette assigned by series order,
which on the first build made fraud *green*. `styleChartOption` recolours a
single-series chart to the source accent and leaves multi-series charts to palette
order, which is right for arbitrary groups and wrong when the category means
something. A chart widget can now carry `chart.colors`, a series-name → colour map
applied after styling. Part-to-whole charts keep their categories as data items
inside one unnamed series, so the map matches those too — otherwise it would
silently do nothing on exactly the charts where category colour matters most.

**Axis labels are money, not exponents.** The size bands were built as `1e0`…`1e5`,
which asks the reader to decode powers of ten before they can see anything. They
are dollar ranges now — `under $10`, `$1k–10k`, `$100k+` — ordered by the decade
they came from rather than alphabetically, so "$100k+ is 100% fraud" reads
straight off the axis.

**No two charts share a shape.** Six chart widgets, six types: area for the day
series, pie for a 4-of-8 split, a ranked bar for named receivers, lollipop for
percentages, pyramid for three ranked mules, and a single stacked bar for the
high-risk share. Five identical bar charts read as one undifferentiated block; the
shape should say something about the data before the labels do.

**Numeric table columns are right-aligned**, with tabular figures, so digits sit
under digits and a column of money is comparable at a glance. Which columns count
as numeric is decided from the data — from the first row that actually holds a
value, so a leading null does not make a money column read as text.

**Numbers are formatted.** `formatNumber` in `web/libs/Dashboard/theme.ts`
separates thousands and keeps decimals only where they inform — `12,033`,
`321,337`, but `2.91` for a rate. Axis ticks use `formatCompact` (`6.6M`, `506k`),
because a tick that reads `6,607,031` costs more room than it earns. Before this
the dashboard rendered raw JS numbers, which is how `11056695.31` came to overflow
its card.

### Two cadences

Headline numbers poll every **2s**; the graph traversals poll every **10s**. They
are multi-hop queries whose answers barely move between ticks. This needs
`pollGroups()` in `shared/dashboard/spec.ts` and the per-source versions in
`DashboardPanel.tsx` — before those, one timer ran every widget at the fastest
interval any source asked for.

### Clicking

Every chart is a canvas selector for free: `ChartWidget` registers
`dispatchAction({type: "selectByProperty"})` on click, so clicking a suspect's bar
selects those nodes on the canvas.

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
forever. The timers now exist in `DashboardPanel.tsx`, driven by `pollGroups` in
`shared/dashboard/spec.ts`.

Two things worth knowing about how it behaves:

- **One timer per declared period**, each marking only the sources that asked for
  it (`pollGroups`). A source that does not poll falls back to the panel's own
  counter, which still bumps on every canvas change — so canvas, file and inline
  widgets behave exactly as they did.
- **2 seconds is the floor** (`INTERVAL_FLOOR_MS`). A lower `everyMs` is raised
  to it rather than honoured. The floor guards the project database against a
  spec that would hammer it; it is not a pacing preference. These queries take
  ~0.1s, so a 2s poll is a 5% duty cycle.

You can also set it from the GUI now: the **Re-run** dropdown under a db source's
query. Editing the query does not clear it.
