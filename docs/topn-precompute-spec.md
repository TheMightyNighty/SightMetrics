# Spec: Top-N precompute (v2.1)

Status: Implemented (2026-07-15) — ingestion, reader, frontend, contract test
verified (local demo stack + real MariaDB round trip). Additive to schema v2
(`docs/SCHEMA.md`), no version bump needed. Open: perf measurement on a large
cube (see "To check after implementation").

**Implementation note:** the column is called `win`, not `window` —
reserved word in DuckDB and MariaDB (window functions). Applies to all SQL
snippets below.

## Problem

`CubeRepository::topN()` aggregates live over `cube` on every panel load:

```sql
SELECT dimkey, SUM(pv), SUM(v) FROM cube
WHERE site_id=? AND dim=? AND datum BETWEEN ? AND ?
GROUP BY dimkey ORDER BY <metric> DESC LIMIT ?
```

The `sm_dim_datum (site_id, dim(32), datum)` index (perf package, unreleased)
limits the **scan** to the right site/dim/date range, but doesn't reduce the
**aggregation cost**: for high-cardinality dimensions (`referrer_url`,
`keyword`, `url`) and long windows (a year, "entire period") the engine still
has to group and sort potentially tens of thousands of `(datum, dimkey)` rows
before cutting to `LIMIT`. For an existing customer with 2.5M visits/month
this becomes the next bottleneck for long windows, after the full-table scans
already fixed.

`dim` cardinality and window size are multiplicative: a year of data on a
large site can easily produce 50k+ distinct `dimkey` values for
`referrer_url` over 365 days, even though the frontend (`topn.js`) only shows
8–10 rows per panel (plus an optional "+ N more" via `TopNAjaxController`,
capped at `limit<=100`, `offset<=10000`).

## Non-goal

`cube` itself is **already** a precompute (daily rollup from the raw hits,
see `ingestion/transform.sql`). This spec adds a *second* precompute stage:
top-K over standard time windows, derived from `cube` — not from the raw
data.

## Design

### New additive table `topn`

```sql
CREATE TABLE IF NOT EXISTS topn (
  site_id INTEGER,
  win     VARCHAR(16),   -- window label, see "Covered windows" below; 'win' instead
                          -- of 'window' since that's a reserved word in DuckDB/MariaDB
                          -- (window functions)
  dim     VARCHAR(32),
  parent  VARCHAR(191) NULL,
  dimkey  VARCHAR(1024),
  pv      BIGINT,
  v       BIGINT,
  rnk     SMALLINT       -- 1..K, rank by the dim's fixed metric (TopNDims::ROOT_METRIC_BY_DIM)
);
CREATE INDEX IF NOT EXISTS sm_topn_lookup ON topn (site_id, dim(32), win(16), rnk);
```

Analogous to `sink_mysql.sql`/`v2_add_indexes.sql`: `CREATE TABLE/INDEX IF NOT
EXISTS`, no migration required for existing DBs (the table simply stays
empty/unused until the sink populates it on the next import — until then the
reader falls back to live queries, see below).

### Computation (ingestion, after the `cube` insert)

Per import and affected site: derive the windows whose end date falls within
the day range just written (effectively "all of them" for a daily run) fresh
from `cube` via `DELETE site_id+window` + `INSERT` — the same replace pattern
as `daily`/`cube` themselves (runbook §8, day-boundary cut).

```sql
-- For each (window, dim) with a dim-specific metric (see TopNDims):
INSERT INTO topn
  SELECT site_id, '<window>' AS win, dim, parent, dimkey, pv, v, rnk FROM (
    SELECT site_id, dim, parent, dimkey, SUM(pv) pv, SUM(v) v,
           ROW_NUMBER() OVER (PARTITION BY dim, parent ORDER BY SUM(<metric>) DESC) AS rnk
    FROM cube
    WHERE site_id=? AND dim IN (<root dims without parent>) AND datum BETWEEN <window_start> AND <window_end>
    GROUP BY site_id, dim, parent, dimkey
  ) WHERE rnk <= 100
```

`<metric>` is fixed per `dim` (pv or v, `TopNDims::ROOT_METRIC_BY_DIM`) — the
`UNION ALL` structure from `transform.sql` (lines 189ff.) can be reused
directly here, just with `cube` instead of `sess`/`visits` as the source, and
`ROW_NUMBER() ... QUALIFY`/subquery cutoff instead of a plain `GROUP BY`.

K=100 was chosen because `TopNAjaxController` caps `limit` at 100 — the
precompute thus covers exactly the first "page" of any pagination.

### Covered windows

Windows that are (a) calendar-deterministic from the import timestamp (no
"custom" ranges) and (b) actually expensive:

| window | Definition | Why precomputed |
|---|---|---|
| `last30` | rolling 30 days | most common preset, included as a precaution (not yet measured whether it's needed) |
| `last90` | rolling 90 days | this is where live `GROUP BY` becomes noticeable |
| `last365` | rolling 365 days | largest common window choice |
| `thisyear` / `lastyear` | calendar year | preset in the frontend (`presets.js`) |
| `all` | the site's entire dataset | most expensive query, meta.von..meta.bis |

**Not** precomputed: `today`, `yesterday`, `thismonth`, `lastmonth` — short
windows for which the index is already sufficient (see the perf measurement:
1.2s→0.3s at ~870k rows), and specific individual past years (`year:YYYY`) —
chosen rarely enough that the maintenance cost isn't justified (can be added
later if needed, since this is additive).

**Drill-down children (`parent` set) are precomputed in v1 too**, e.g.
`browser_version` under each `browser`, `referrer_url` under each
`referrer_name`. This multiplies the row count by the parent cardinality
(`window × dim × parent count × 100`) — not yet measured whether this
matters for referrer-heavy sites; see "To check after implementation" below.
The `INSERT` structure is identical to the root dims, just `PARTITION BY dim,
parent` instead of `PARTITION BY dim`, and `parent IS NOT NULL`.

### Reader integration (`CubeRepository::topN()`)

```
if window (sent by the frontend) in SUPPORTED_WINDOWS && offset < 100:
    → SELECT from `topn` (site_id, dim, parent, win, rnk BETWEEN offset+1 AND offset+limit)
else:
    → existing live query (unchanged)
```

The frontend already knows the selected preset (`w-preset` value in
`presets.js`) and sends it as an additional, optional query parameter
`window` to `TopNAjaxController` (additive, no break to the existing API —
old clients without the parameter automatically fall back to the live path).
The server **does not** trust the label blindly: it validates server-side
(site TZ `meta.tz`, today's date) that the `from`/`to` the client submitted
actually match the calendar definition of the claimed `window` value — if
they diverge (e.g. client clock drift, stale preset list), the request is
treated as "no precomputed window" and runs live. This validation is simpler
than reconstructing the window purely from `from`/`to` (no guessing which
preset was meant), while the server remains the sole source of the calendar
logic.

`dimSummary()` (total sum + `COUNT(DISTINCT dimkey)` for the percentage
display and "+ N more") stays **unchanged, live** — it's a single aggregate
scalar over the index, already cheap, and must be exact (not capped to
top-K).

### Migration / rollout

- Additive, no `schema_version` bump. `ingestion/migrations/v2_add_topn.sql`
  analogous to `v2_add_indexes.sql` for existing DBs (creates the
  table+index; the first population happens automatically on the next
  import).
- Bundled with the perf package as **v2.1** (see the `release-plan-v21`
  memory).
- CHANGELOG entry under "Unreleased" → "Performance", with the same
  before/after numbers as the index package, but specifically for
  `last365`/`all` on high-cardinality dimensions (`referrer_url`, `keyword`,
  `url`) on the 867k-row test cube.

### Tests

- **Contract test extension** (`tests/contract/run.sh` / `CubeContractTest`):
  for at least one high-cardinality root dimension and one drill-down
  dimension, verify that `topN()` with a precomputed window returns results
  identical to a reference query computed directly against `cube`
  (regression protection against drift between the `topn` and `cube`
  tables).
- **Fallback test**: `offset>=100`, an unknown/missing `window` label, and a
  `window` label that doesn't match the submitted `from`/`to`, all still
  return correct results via the live path.
- **Perf test** (see "To check after implementation" below): `last365`/`all`
  on `referrer_url`/`keyword`/`url` before/after, same 867k-row test cube as
  for the index package, so the numbers stay comparable.

## Decisions (2026-07-15, with Robert)

1. **Window list**: `last30`, `last90`, `last365`, `thisyear`, `lastyear`,
   `all` — `last30` added on top of the original proposal (as a precaution,
   unmeasured). Specific individual years (`year:YYYY`) stay out.
2. **Window label**: the frontend sends `window` (the preset label) in
   addition to `from`/`to` to `TopNAjaxController`; additive parameter, the
   server validates against it (see Reader integration above).
3. **Drill-down children**: precomputed directly in v1 (not deferred).
4. **Import overhead**: measured **after** implementation (not as an upfront
   gate) — build first, perf-check afterwards.

### To check after implementation

Because decisions 3+4 together raise the risk (drill-down precompute
multiplies the row count, and the measurement only happens afterwards):
after the first working run on the 867k-row test cube, explicitly check —
(a) import time before/after (target corridor <10% longer, not a hard gate,
but a warning sign if significantly over), (b) row count of the `topn` table
for referrer-heavy test data (`referrer_name`→`referrer_url` is the
highest-cardinality drill-down candidate). Include the result in the final
CHANGELOG entry.
