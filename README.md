# SightMetrics – privacy-friendly web access analytics

SightMetrics analyzes **web server logs** (Apache/nginx) and presents the
results as a dashboard in a **TYPO3 backend module** — no JavaScript
tracker, no cookies, visitor data never leaves your own system.

Instead of capturing every single pageview via a tracking API (as, e.g.,
Matomo does), SightMetrics reads the log files that already exist, reduces
them **once with [DuckDB](https://duckdb.org/)** into compact daily
aggregates ("cubes"), and stores only those in a database. This is fast,
resource-efficient, and **privacy-friendly** — a design particularly suited
for public-sector and government use (GDPR/BSI).

---

## How it works (in one picture)

```
   Apache/nginx          Package A: Ingestion (DuckDB)             MariaDB           Package B: TYPO3 extension
   ─────────────         ───────────────────────────────           ─────────         ──────────────────────────
   access.log    ──────► parse → sessionize → aggregate ─────────► cube DB   ◄────── backend module "Web Analytics"
   (raw lines)           (load_cube.sh / transform.sql)          (cube/daily/meta)   (read-only, renders charts)
                              ▲
   Matomo (legacy data) ──────┘
   Reporting API (JSON)   matomo_import.sh  (one-off import of historical data)
```

- **Package A writes** the cube (DB user `cube_rw`), **package B only reads**
  (`report_ro`, `SELECT` only).
- The two packages share **no code**, only the database — a deliberate
  architectural boundary (concept §11).

---

## Key terms

| Term | Meaning |
|---|---|
| **Cube** | Precomputed analytics data in MariaDB. Table `cube(site_id, datum, dim, parent, dimkey, pv, v)`: pageviews (`pv`) and visits (`v`) per day, per dimension, per value; `parent` holds the parent value for drill-down dimensions. `datum` is bucketed in the site's timezone (`meta.tz`). |
| **Dimension (`dim`)** | An analytics axis, e.g. `url`, `country`, `browser`, `os`, `device`, `referrer_type`, `keyword`, `hour`, `entry`/`exit`, `download`, `status`, `method`. |
| **`daily` / `meta`** | Daily metrics (visits, pageviews, unique visitors, bounces, bytes) and overall metadata per site, respectively. |
| **Sessionization** | Grouping individual hits into visits, based on IP+user-agent and 30-minute inactivity — happens in DuckDB, not in the database. |
| **Site / `site_id`** | A website being analyzed. Multiple sites with different `site_id`s live in **one** cube DB (multi-site). |
| **Schema contract** | The cube tables are the only interface between the two packages. The contract is versioned (`meta.schema_version`) and normatively documented in [`docs/SCHEMA.md`](docs/SCHEMA.md); the extension checks the version at startup. |

---

## Repository structure

| Path | Content |
|------|--------|
| `ingestion/` | **Package A – ingestion/analytics (DuckDB)**, the operational part. Log parser, aggregation SQL, import scripts, GeoIP data, the DuckDB binary. Sole writer of the cube DB. → [`ingestion/README.md`](ingestion/README.md) |
| `extension/` | **Package B – TYPO3 reporting extension** `sight_metrics`. Read-only backend module, no DuckDB. → [`extension/README.md`](extension/README.md) |
| `demo/` | **Disposable stack** to try things out: TYPO3 v13 + MariaDB (cube DB) via Docker Compose. Not for production. |
| `docs/` | Detailed documentation: [extension handbook](docs/extension-handbuch.md) (developer/admin) · [ingestion runbook](docs/ingestion-runbook.md) (ops) · [Matomo import](docs/matomo-import.md). |
| `logs/` | Sample/test logs. |

---

## Quick start (demo)

Requirements: Docker + Docker Compose, Bash, `curl`/`unzip`, Python 3. No
local PHP/Composer/Apache needed — TYPO3 runs in the container via the
built-in PHP dev server, Composer also runs containerized.

```bash
# 1) Start the stack. TYPO3 installs itself on first start (composer install,
#    non-interactive setup) via the web container's entrypoint.
docker compose -f demo/docker-compose.yaml up -d

# 2) Import a sample log: log -> DuckDB cube -> MariaDB
docker exec -it sightmetrics-ingestion bash
# inside the container:
python3 generate_demo_geo.py -o geo/country-ipv4-num.csv

# 2a) File-based logs
./generate_logs.py
./load_cube.sh logs/example_1k.log "Sample Authority" 1
# ./load_cube.sh <logfile> "<site name>" <site_id>
# (multi-site capable, idempotent per site)

# 2b) Loki logs
python3 generate_loki_logs.py --loki-url http://loki:3100 --label "namespace=foo" --hours $(( 24 * 14 )) --num $(( 10000 * 14 ))
SM_LOG_FORMAT=json_ecs ./fetch_loki_logs.sh --url http://loki:3100 --query '{job="nginx", namespace="foo"}' --site-id 1 --site-name "Authority A" --lookback-days 14

# 3) View in the backend:
#    http://localhost:8091/typo3/   (admin / SightMetrics-Admin-2026!)
#    -> module  Web > "Web Analytics"
```

For **production operation** see
[`ingestion/scheduling/README_scheduling.md`](ingestion/scheduling/README_scheduling.md)
and the [ingestion runbook](docs/ingestion-runbook.md). This includes:
a hardened container image (non-root UID 10001,
`readOnlyRootFilesystem`-capable), complete **Kubernetes manifests**
(`ingestion/scheduling/k8s/`, CronJob following pod security "restricted"),
**Prometheus** metrics (node_exporter textfile format), as well as secret
rotation, backup, and retention.

---

## Importing legacy data from Matomo

Migrating from Matomo lets you carry over **historical data once per site**
— via Matomo's Reporting API, without raw logs. Works even if Matomo's raw
tracking data has already been deleted, and scales for sites with millions
of hits/day:

```bash
cd ingestion
export MATOMO_TOKEN="…"   # view token from Matomo
export CUBE_DSN="host=… user=cube_rw password=… database=analytics"
./matomo_import.sh --url https://matomo.example.org --matomo-idsite 7 \
                   --site-id 1 --site-name "Sample Authority" \
                   --from 2020-01-01 --to 2024-12-31
```

Details, mapping, and limitations: [`docs/matomo-import.md`](docs/matomo-import.md).

---

## Dashboard feature set

- **Trend** over time, **world map** (choropleth), and country list
- **Visit times** (hourly heatmap), **browser / OS / device** with
  **drill-down** (→ versions/models)
- **Referrer** types and URLs, **search terms**
- **Entry/exit pages**, **downloads**, **status codes**, **HTTP methods**,
  **page-tree drill-down**
- **KPIs** including bounce rate and bandwidth
- **Time range selector** (a Matomo-style dropdown: relative / calendar /
  individual years / custom), **period comparison**
- **CSV and PDF export**, **dark mode**, full **localization**
  (English/German)
- **Bot/crawler filter** — only human visitors are counted; status codes
  also show 4xx/5xx for error diagnosis

Data quality and robustness of the ingestion (each switchable/optional):

- **Bot and browser/OS detection**, optionally based on
  [matomo/device-detector](https://github.com/matomo-org/device-detector)
  (Matomo-comparable, `tools/fetch_bot_list.sh` / `tools/fetch_ua_lists.sh`)
  — without these lists, a built-in UA heuristic is used instead.
- **IPv6-robust**: IPv6 addresses are counted; with an optional v6 geo
  dataset (`SM_GEO6_PATH`) they're also mapped to a country.
- **Local day buckets** (`SM_TZ`) and a **day-boundary cut** (no data loss
  at the day boundary; a day only appears once complete).

---

## Multi-site

The cube carries a `site_id`; multiple sites live together in one cube DB,
the dashboard has a site selector. The mapping **TYPO3 site → cube
`site_id`** is done via `sightmetrics_site_id` in the TYPO3 site
configuration. Designed for **one** TYPO3 instance with multiple sites in a
single namespace (cube in the same MariaDB).

---

## Development & tests

```bash
./run-tests.sh            # lint + all test suites (ingestion pipeline + extension)
extension/lint.sh         # lint only: PHPStan level max + strict-rules + TYPO3 coding standards
```

Testing happens at several levels (all in CI, see `.github/workflows/ci.yml`):
DuckDB pipeline suite, PHP unit/functional (TYPO3 13.4/14 × PHP 8.2–8.4),
JavaScript typecheck (`tsc --checkJs`) + jsdom smoke, a **contract test**
(ingestion writes → extension reads, against a real MariaDB), and an
**e2e** run (Puppeteer against the real TYPO3 backend).

The extension source (`extension/sight_metrics/`) is bind-mounted live into
the demo stack (see `demo/docker-compose.yaml`) — changes are visible in the
running container immediately, no copy/sync step needed.

---

## Technology stack

TYPO3 v13.4 LTS / v14 · PHP 8.2–8.4 · DuckDB 1.5.4 (static binary in
`ingestion/bin/`) · MariaDB · [Chart.js](https://www.chartjs.org/)
(trend/hourly chart) · [Leaflet](https://leafletjs.com/) (visitor map). The
backend module frontend consists of native ES modules (no build step),
loaded via TYPO3's `JavaScriptModules.php`.

---

## Versioning & upgrades

The extension follows SemVer; the cube DB carries its own schema version
(`meta.schema_version`, contract in [`docs/SCHEMA.md`](docs/SCHEMA.md)).

> **Upgrading to 2.0 (breaking):** version 2.0 changes the DB contract
> (local day buckets, `cube.parent` column instead of encoded keys, neutral
> `referrer_type` values). Migrate existing cube DBs once —
> `mysql … analytics < ingestion/migrations/v1_to_v2.sql` (idempotent) — or
> re-import. Extension 2.x refuses older data with a clear message.
> Details: [`docs/SCHEMA.md`](docs/SCHEMA.md) and
> [`CHANGELOG`](extension/sight_metrics/CHANGELOG.md).
