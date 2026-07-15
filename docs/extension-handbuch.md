# SightMetrics – Extension Handbook (Package B)

> **Note:** The authoritative, maintained extension documentation is the
> ReST documentation in
> [`extension/sight_metrics/Documentation/`](../extension/sight_metrics/Documentation/)
> (for docs.typo3.org). This handbook remains as an additional
> operator-focused guide; in case of conflict, the ReST documentation and
> [`docs/SCHEMA.md`](SCHEMA.md) (for the DB contract) take precedence.

TYPO3 backend module for web access analytics. **Read-only** access to the
cube DB (MariaDB, user `report_ro`); no DuckDB, no writing.

---

## Table of contents

1. [File structure](#1-file-structure)
2. [Requirements](#2-requirements)
3. [Installation](#3-installation)
4. [Configuring the cube connection](#4-configuring-the-cube-connection)
5. [Mapping a TYPO3 site to a cube site](#5-mapping-a-typo3-site-to-a-cube-site)
6. [Configuring the error page](#6-configuring-the-error-page)
7. [Multiple sites (one instance)](#7-multiple-sites-one-instance)
8. [TYPO3 version matrix](#8-typo3-version-matrix)
9. [Using the backend module](#9-using-the-backend-module)
10. [Architecture & extension](#10-architecture--extension)
11. [Tests & CI](#11-tests--ci)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. File structure

```
extension/
├── lint.sh                         Lint runner: PHPStan + TYPO3 coding standards
├── run-tests.sh                    Local test runner (2a unit, 2b functional, 2c smoke, 2d JS)
│
└── sight_metrics/                  Composer package sightmetrics/sight-metrics
    ├── composer.json               Package metadata + require-dev (phpstan, testing-framework, …)
    ├── ext_emconf.php              TYPO3 extension metadata (version constraints open for v14)
    ├── ext_localconf.php           Registers the "sight_metrics" cache (cache framework)
    ├── ext_conf_template.txt       Extension configuration (error page, windowDays, cacheLifetime)
    ├── package.json                Dev tooling: JS tests + version-pinned vendor assets (npm)
    ├── package-lock.json           Version pinning for Chart.js/Leaflet/jsdom
    ├── CHANGELOG.md                Extension change history
    ├── ROADMAP.md                  Open items / review findings
    ├── REUSE.toml · LICENSES/      REUSE-compliant license structure
    ├── phpstan.neon                PHPStan configuration (local, level 6)
    ├── phpstan.ci.neon             PHPStan configuration (CI, no baselineExtensions noise)
    ├── phpunit.xml.dist            PHPUnit configuration for unit tests
    ├── phpunit.functional.xml.dist PHPUnit configuration for functional tests (SQLite)
    ├── .php-cs-fixer.dist.php      TYPO3 coding standards (php-cs-fixer)
    ├── .gitignore
    │
    ├── Classes/
    │   ├── Command/
    │   │   ├── SmokeCommand.php    TYPO3 CLI: sightmetrics:smoke — checks the cube connection + tables
    │   │   └── HealthCommand.php   TYPO3 CLI: sightmetrics:health — data freshness, Nagios exit codes
    │   ├── Controller/
    │   │   ├── DashboardController.php  Backend controller: loads data, renders the Fluid template
    │   │   └── TopNAjaxController.php   Ajax: Top-N lazy loading ("+ N more", drill-down)
    │   ├── Domain/
    │   │   └── Repository/
    │   │       └── CubeRepository.php   All queries against the cube DB (incl. topN/dimSummary, caching)
    │   └── Support/
    │       ├── ErrorPage.php       Renders a configurable error page (DB unreachable)
    │       ├── SiteSelector.php    Site selection + webmount-based tenant separation
    │       ├── TopNDims.php        Whitelists: which dimensions are server-side Top-N-limited
    │       └── WindowResolver.php  Server-side time window (windowDays, from/to clamping)
    │
    ├── Configuration/
    │   ├── Backend/
    │   │   ├── Modules.php         Backend module registration (web_sightmetrics)
    │   │   └── AjaxRoutes.php      Ajax route sightmetrics_topn (inherits module permission)
    │   ├── Commands.php            CLI command registration (sightmetrics:smoke, :health)
    │   ├── Icons.php               Icon registration (EXT:sight_metrics/module.svg)
    │   └── Services.yaml           Symfony DI configuration (controller public, rest private)
    │
    ├── Resources/
    │   ├── Private/
    │   │   ├── Language/
    │   │   │   └── locallang_mod.xlf   Module title (default: English)
    │   │   └── Templates/
    │   │       └── Dashboard/
    │   │           └── Index.html  Fluid template: JSON data block + panel scaffold
    │   └── Public/
    │       ├── Css/
    │       │   └── dashboard.css   Module styles (bar lists, map panel, drill-down, a11y)
    │       ├── Icons/
    │       │   └── module.svg      Backend module icon
    │       ├── JavaScript/
    │       │   └── dashboard.js    Rendering: Chart.js charts, Leaflet map, Top-N/drill-down
    │       └── Vendor/             (provenance/checksums: NOTICE.md; sourced via npm run vendor:update)
    │           ├── chart.umd.min.js  Chart.js (MIT, self-hosted, no CDN)
    │           ├── leaflet.js · leaflet.css · images/  Leaflet (BSD-2-Clause)
    │           ├── world.js        World map GeoJSON (Natural Earth via world-atlas)
    │           └── NOTICE.md       Versions, licenses, SHA-256 checksums
    │
    ├── scripts/
    │   └── update-vendor.mjs       Copies Chart.js/Leaflet from node_modules into Vendor/
    │
    └── Tests/
        ├── bootstrap.php           PHPUnit bootstrap for unit tests (without TYPO3 core)
        ├── Functional/
        │   └── CubeRepositoryFunctionalTest.php  Functional tests (TYPO3+SQLite)
        ├── JavaScript/
        │   └── dashboard.smoke.test.mjs  DOM smoke test (jsdom, Chart.js/Leaflet fakes)
        └── Unit/
            ├── ErrorPageTest.php   Unit tests for ErrorPage (configurable messages)
            ├── SiteSelectorTest.php  Unit tests for SiteSelector (incl. tenant separation)
            └── WindowResolverTest.php  Unit tests for the time window (incl. iso() validation)
```

---

## 2. Requirements

| Component | Version |
|---|---|
| PHP | ^8.2 |
| TYPO3 CMS | ^13.4 or ^14.0 |
| MariaDB | ≥ 10.5 (cube DB, write: `cube_rw`, read: `report_ro`) |
| Composer | v2 |

The extension contains **no** DuckDB and writes **nothing** to the cube DB.
Writing is done exclusively by package A (`ingestion/`).

---

## 3. Installation

### 3a. Composer (production)

The extension can be included as a composer package from a local path
(until it's published on Packagist):

```json
// in the TYPO3 instance's composer.json:
{
    "repositories": [
        {
            "type": "path",
            "url": "/opt/sightmetrics/extension/sight_metrics",
            "options": { "symlink": false }
        }
    ],
    "require": {
        "sightmetrics/sight-metrics": "*"
    }
}
```

```bash
composer require sightmetrics/sight-metrics
vendor/bin/typo3 extension:activate sight_metrics
```

### 3b. Local development (demo stack)

```bash
cd demo && docker compose up -d
```

The `web` service bind-mounts `extension/sight_metrics/` directly as
`packages/sight_metrics` (see `demo/docker-compose.yaml`). Together with the
`path` repository entry in `demo/app/composer.json`, changes to the
extension code are immediately visible in the container — no sync/copy step
and no `composer update` needed for class changes.

---

## 4. Configuring the cube connection

The extension expects a TYPO3 DB connection named **`cube`** in
`$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube']`.

### additional.php (production)

```php
// config/system/additional.php of the TYPO3 instance
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube'] = [
    'driver'   => 'mysqli',
    'host'     => getenv('CUBE_RO_HOST') ?: 'db-host',
    'port'     => (int)(getenv('CUBE_RO_PORT') ?: 3306),
    'dbname'   => getenv('CUBE_RO_DB')   ?: 'analytics',
    'user'     => getenv('CUBE_RO_USER') ?: 'report_ro',
    'password' => getenv('CUBE_RO_PASSWORD'),   // never in plain text
    'charset'  => 'utf8mb4',
];
```

**Security note:** always read the password from an environment variable or
a secret file — never store it as plain text in `additional.php`. For
containers: inject via `docker-compose.yaml` / a Kubernetes secret.

### Testing the connection

```bash
vendor/bin/typo3 sightmetrics:smoke
```

Checks: the `cube` connection exists, tables `cube`, `daily`, `meta` are
reachable.

### Production hardening: diverging from the demo defaults

The demo environment (`demo/`) is deliberately configured permissively so
the local Docker Compose stack works without fixed IPs/hostnames. **These
two defaults must not be carried over unchanged into production:**

- **`trustedHostsPattern`**: `demo/app/config/system/additional.php` sets
  `$GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = '.*'`
  (accepts any `Host` header → host-header-injection risk). In production,
  always restrict this to the actual domain name, e.g.
  `'^(www\.)?my-domain\.example$'` (see the
  [TYPO3 documentation on `trustedHostsPattern`](https://docs.typo3.org/permalink/t3coreapi:trustedhostspattern)).
- **DB grant host for `report_ro`**: `demo/initdb/01-analytics.sh` creates
  the cube DB user with `'report_ro'@'%'` (any host may connect as this
  user). In production, restrict the grant to the actual web
  subnet/host, e.g. `CREATE USER 'report_ro'@'10.0.1.0/255.255.255.0' ...`
  or, for a fixed IP, `'report_ro'@'10.0.1.42'`. Additionally secure the
  connection via network segmentation/firewalling — MySQL host grants alone
  are not a complete network safeguard.
- **Set up cache garbage collection**: the `cache_sight_metrics` table
  (TYPO3 DB) grows unbounded without cleanup — set up the core task
  "Caching framework garbage collection" (e.g. daily) with the
  `sight_metrics` cache selected. Details in §10 "Known limitations:
  scaling & caching".

---

## 5. Mapping a TYPO3 site to a cube site

In a TYPO3 instance with multiple sites (e.g. multiple department domains),
each TYPO3 site can be mapped to its own `site_id` in the cube.

### Configuration in `config/sites/<identifier>/config.yaml`

```yaml
# Example: config/sites/authority_a/config.yaml
rootPageId: 1
base: 'https://authority-a.example/'
languages: ...

# SightMetrics: associated site_id in the cube
sightmetrics_site_id: 1
```

```yaml
# Example: config/sites/authority_b/config.yaml
rootPageId: 2
base: 'https://authority-b.example/'

sightmetrics_site_id: 2
```

### Behavior

| State | Module behavior |
|---|---|
| **No** `sightmetrics_site_id` on any TYPO3 site | All cube sites appear in the dropdown (backward compatibility) |
| **One** TYPO3 site with a mapping | Only that site_id is visible, auto-selected (given webmount access) |
| **Multiple** TYPO3 sites with mappings | The dropdown only shows sites the user has webmount access to (based on rootPageId); admins see all mapped sites |
| A mapping exists, but the user has webmount access to **none** of the mapped sites | **Empty dashboard** — deliberately no fallback to "all sites" (tenant separation) |

> **Important for multi-tenant operation:** tenant separation only applies
> when sites are mapped. Without any mapping at all (first row), **every**
> user with module access sees **all** cube sites — in a multi-tenant
> installation, always assign `sightmetrics_site_id` to every site.

### Importer assignment (Kubernetes/namespace)

One importer per namespace writes with a fixed `site_id`:

```bash
# Namespace A (Authority A): site_id=1
CUBE_DSN="..." ./load_cube.sh /logs/access.log "Authority A" 1

# Namespace B (Authority B): site_id=2
CUBE_DSN="..." ./load_cube.sh /logs/access.log "Authority B" 2
```

Both write into the same `analytics` database. TYPO3 only shows the sites
mapped via `sightmetrics_site_id` in the module — without a dropdown for a
single mapping, with a selector for multiple.

---

## 6. Configuring the error page

If the cube DB is unreachable, the module shows a configurable error page
instead of a PHP exception. Configuration in the TYPO3 backend under
**Admin Tools → Extensions → sight_metrics**:

| Setting | Default | Description |
|---|---|---|
| `errorTitle` | "Analytics currently unavailable" | Error page heading |
| `errorMessage` | "The connection …" | Explanatory text |
| `showTechnical` | `0` | Show the technical error message (admins/debug only) |
| `windowDays` | `92` | Server-side time window in days: only this window is loaded from the cube DB (limits transfer volume independently of retention). `0` = unlimited. |
| `cacheLifetime` | `60` | Cache TTL in seconds for cube DB reads (TYPO3 cache framework, `sight_metrics` cache). `0` = no caching, every call reads live. Operations: see "Cache cleanup is an operator responsibility" (§10). |

The cube connection is completely separate from the main TYPO3 connection —
a cube DB outage does not take down the TYPO3 backend.

---

## 7. Multiple sites (one instance)

Use case: **one** TYPO3 instance with multiple sites in **one** namespace,
cube in **your** MariaDB. All sites live in `analytics`, distinguished by
`site_id`. The mapping from a TYPO3 site to a cube `site_id` is done via
`sightmetrics_site_id` in the site config (§5); the GUI offers the site
selector accordingly.

> Tenant/DB isolation via separate databases per tenant is **not needed**
> for this single-instance setup and was deliberately not built in. Should
> real multi-tenant separation be required later, "its own DB + its own
> `cube` connection per instance" would be the way to go — the extension
> itself would remain unchanged.

---

## 8. TYPO3 version matrix

| sight_metrics | TYPO3 | PHP | Status |
|---|---|---|---|
| current | ^13.4 | ^8.2 | actively tested (functional + unit, CI) |
| current | ^14.0 | ^8.2 | **verified** against TYPO3 v14.3.4 + testing-framework 9.5 (functional 13/13 + unit 20/20); CI lane in place |

emconf constraint: `13.4.0-14.99.99`. CI (the `functional` job) tests both
major versions in a matrix (TYPO3 `^13.4`/`^14.0` × PHP 8.2/8.3), with the
matching `typo3/testing-framework` version (8.x for v13, 9.x for v14).

The extension is deliberately kept lean (no TypoScript, no frontend, no
TCA, no database migration scripts) to minimize exposure to v14 breaking
changes. Module labels come from
`Resources/Private/Language/locallang_mod.xlf` (no hardcoded text in
`Modules.php`).

---

## 9. Using the backend module

Module: **Web → Web Analytics** (`web_sightmetrics`)

### Site selection

A dropdown appears when there are multiple sites. The selection is passed
via the URL parameter `site` and stored in the user session.

### Time range selection

A single **"time range"** dropdown (Matomo-style), not several fields side
by side:
- **Relative:** Today, Yesterday, Last 7 / 30 / 90 days (anchored to the
  newest data available, never in the future).
- **Calendar:** This/Last month, This/Last year.
- **Specific years:** one entry per year present in the data (e.g. "Year
  2025").
- **Entire period** and **Custom …**.

Only **"Custom …"** expands the `from`/`to` fields (ISO date) and a
**month picker**; otherwise they stay collapsed. The default entry reflects
the initially loaded state (see the time window below) and doesn't trigger
a reload.

**Server-side time window (scaling):** the entire cube is not loaded into
the frontend — only a window (default 92 days, configurable via
`windowDays`, 0 = unlimited). A selection **within** the window filters
instantly client-side (including comparison); a selection **outside** the
window reloads the matching window from the server (reload with
`?from=&to=`). This keeps the transfer volume bounded independently of the
cube DB's retention.

### Dark mode

The module follows the TYPO3 backend color scheme (`data-color-scheme`
attribute, falling back to `prefers-color-scheme`): maps, text, bar lists,
and the Chart.js axes/labels are recolored for legibility in the dark
scheme. The switch happens client-side via the `sm-dark` class on the root
container.

### KPI bar

Visits, pageviews, unique visitors, bounce rate, total bandwidth — always
for the selected time range and site.

### Period comparison

A **"Compare to previous period"** checkbox in the bar. When enabled, the
selected time range is compared against the **immediately preceding period
of the same length** (e.g. the 30 days before). Each KPI gets a delta badge
(▲/▼ ± %), color-coded by direction (green = better, red = worse; for
bounce rate, "down" is good). In the trend chart, the previous period
appears as a dashed reference line (position-wise, day to day). Note: if
the previous period lies wholly or partially before the first available
data (`meta.von`), the delta stays empty — comparisons only run over
fully-present time ranges (no skewed partial comparisons). With the entire
period selected, there is therefore naturally no previous period.

### Export

Two buttons in the bar, purely client-side (no server round trip, CSP
compliant):
- **CSV** – downloads the current time range as CSV (UTF-8 with BOM,
  `;`-separated, Excel-compatible): a header (site/period/as-of), the daily
  trend, and all dimension breakdowns (country, browser, OS, device,
  referrer, search terms, pages, entry/exit, downloads, status, method,
  hour). Filename `sightmetrics_<site>_<from>_<to>.csv`.
- **PDF** – opens the browser print dialog ("Save as PDF"). A print
  stylesheet hides the control bar and reflows the panels for printing.

### Analytics panels

| Panel | Dimension (`dim`) |
|---|---|
| Trend chart | daily aggregate (`daily` table) |
| World map (choropleth) | `country` |
| Country bar list | `country` |
| Browsers | `browser` |
| Operating systems | `os` |
| Device types | `device` |
| Referrer types | `referrer_type` |
| Referrer URLs | `referrer` |
| Search terms | `keyword` |
| Entry pages | `entry` |
| Exit pages | `exit` |
| Downloads | `download` |
| Status codes | `status` |
| HTTP methods | `method` |
| Page tree | `url` (with drill-down) |
| Visit times (hour) | `hour` |

Notes on semantics (details: ingestion runbook §3/§8):

- **Status codes** also include 4xx/5xx (error diagnosis); `v` there is the
  number of *affected visitors*, not visits. All other panels only count
  successful requests (status < 400).
- **Bots/crawlers** are already filtered out during ingestion via a
  user-agent heuristic (`SM_BOT_FILTER`).
- **Day buckets and visit times** are computed, since schema v2, in the
  ingestion timezone `SM_TZ` (stored in `meta.tz`, default UTC; set
  `SM_TZ=Europe/Berlin` for German installations, for example). Relative
  time-range presets ("Today", "Last 7 days") anchor in this zone.
- A day only appears **once complete** (day-boundary cut of the incremental
  import) — a nightly run therefore always shows the previous day.

### Drill-down

Clicking a bar-list row opens a sub-level (e.g. browser → versions, OS →
versions, page tree → subpages). Keyboard-operable via Enter/Space,
ARIA-compliant (WCAG 2.1 AA).

---

## 10. Architecture & extension

```
HTTP request (admin browser)
        │
        ▼
DashboardController          ← loads SiteSelector, calls CubeRepository
        │                       catches all \Throwable → ErrorPage
        ▼
CubeRepository               ← TYPO3 ConnectionPool, connection 'cube' (read-only)
        │                       queries: sites() / meta() / daily() / cube()
        ▼
MariaDB analytics            ← tables: cube, daily, meta
(report_ro, SELECT only)

Fluid template Index.html    ← renders all panels; data as a JSON block in the HTML
        │
        ▼
dashboard.js                 ← Chart.js (trend/hourly), Leaflet (choropleth map), drill-down
```

### Known limitations: scaling & caching

**Server-side caching.** `daily()`/`cube()`/`topN()`/`dimSummary()` (the
reads whose volume/call frequency grows with the time window/cardinality)
go through the TYPO3 cache framework's `sight_metrics` cache
(`VariableFrontend` + `Typo3DatabaseBackend`, registered in
`ext_localconf.php`; the `cache_sight_metrics` table is created by TYPO3
itself via `extension:setup`/DB compare). TTL is set via the extension
configuration `cacheLifetime` (default 60s, 0 = disabled — every call then
reads live again). `sites()`/`meta()` are deliberately left uncached (small
individual rows/lists; a new site or a fresh ingestion run should be
visible without delay). If the cache configuration is missing (e.g. unit/
functional tests without a loaded `ext_localconf.php`),
`CubeRepository::cached()` falls back to the live query without erroring.

**Cache cleanup is an operator responsibility.** The `Typo3DatabaseBackend`
does **not** delete expired entries on its own — they remain as dead rows
in `cache_sight_metrics` until a garbage collection run happens. The cache
keys are high-cardinality (every combination of time range, dimension,
offset, and drill-down parent category creates its own entry with only a
60s TTL), so the table grows continuously in operation. Two options:

- **With EXT:scheduler:** set up the core task "Caching framework garbage
  collection" (e.g. daily) and select the `sight_metrics` cache.
- **Without a scheduler (cron/SQL):** delete expired rows directly on the
  TYPO3 DB, e.g. daily via cron:

  ```sql
  DELETE FROM cache_sight_metrics WHERE expires < UNIX_TIMESTAMP();
  ```

  (The associated `cache_sight_metrics_tags` table stays empty — the
  extension sets no cache tags — and needs no cleanup of its own.)

Running `vendor/bin/typo3 cache:flush` also clears the table (blunt, but
harmless — the cache refills on the next module load).

**Server-side cardinality limiting.** `windowDays` only limits the time
axis (how many days are loaded). For every dimension with potentially
unlimited distinct values — search terms, entry/exit pages, downloads,
status codes, HTTP methods, browser, OS, device type, and referrer
type/name/URL along with their version/model sub-categories —
`CubeRepository::topN()` only returns the top-N rows server-side (default
8, `TopNDims::DEFAULT_LIMIT`; referrer URLs 10), together with a total
(`dimSummary()`) for the percentage display and "+ N more". Lazy loading
(a date-range change in the picker, clicking "+ N more", expanding a
drill-down row) goes through the Ajax route `ajax_sightmetrics_topn`
(`TopNAjaxController`, `Configuration/Backend/AjaxRoutes.php`). Drill-down
children (e.g. browser versions under "Chrome") are never preloaded — they
are only requested on expansion via the `parentKey` parameter
(`CubeRepository::applyParentFilter()`, an equality check on the `parent`
column since schema v2, replacing the earlier `chr(31)`-prefix logic — see
[`docs/SCHEMA.md`](SCHEMA.md)). Country is deliberately left unlimited (the
choropleth map needs all countries, and ISO codes are bounded to ~250
values anyway).

The **page tree** (`url` dimension) is also limited server-side, but via
its own scheme: `CubeRepository::urlTree()` segments the URL paths in SQL
(portable `SUBSTR`/`INSTR` expressions, running on both MariaDB and SQLite)
and returns only the top-8 segments per level with subtree sums. The
initial payload contains the first two levels (first level expanded, as
before); deeper branches and "+ N more" are lazy-loaded by `dashboard.js`
via the Ajax route `ajax_sightmetrics_tree` (`TreeAjaxController`, path
prefix as a `path` parameter). This means no panel depends on the full row
set of a high-cardinality dimension anymore — the `cube` initial payload
now only contains the small dims (country, hour).

### Adding a new dimension

1. **Ingestion side:** `transform.sql` — add a new `UNION ALL SELECT ...`
   branch in the cube build with a new `dim` key (for drill-down
   dimensions, use the parent/child separator `chr(31)` in `dimkey`, see
   existing branches like `browser_version`).
2. **Extension side, template:** `Index.html` — add a new panel block with
   an empty container (e.g. `<div id="bl-new-key" class="barlist"></div>`);
   the template only contains the scaffold, the data arrives as a JSON
   block and is rendered client-side.
3. **Extension side, JavaScript:** `dashboard.js` — register the
   dimension:
   - **Unbounded cardinality** (URLs, search terms, etc.): add an entry to
     `TOPN_ROOT` (container ID + metric `pv`/`v`; for a drill-down child,
     also add `child` and the child entry to `TOPN_CHILD`).
   - **Small, fixed value set** (like country): a classic `barlist()` call
     in `render()` — the rows then arrive fully in the initial payload.
4. **Extension side, PHP (Top-N dimensions only):**
   `Classes/Support/TopNDims.php` — add the dimension to
   `ROOT_METRIC_BY_DIM` (or `CHILD_METRIC_BY_DIM`/`CHILD_OF_ROOT`).
   **Without this entry**, the Ajax endpoint returns 400 for the dimension
   (whitelist) and `DashboardController` doesn't preload any Top-N; without
   the entry, the dimension instead lands unbounded in the initial payload
   (`cube()` returns every `dim` key not listed in
   `TopNDims::excludedFromFullPayload()`).
5. Optional: add the dimension to `EXPORT_DIMS` in `dashboard.js` for the
   CSV export, and extend the JS smoke test (`Tests/JavaScript/`) to cover
   it.

---

## 11. Tests & CI

### Locally (demo stack needed for 2b + 2c)

```bash
./run-tests.sh          # all suites: lint + unit + functional + smoke + e2e
extension/lint.sh       # lint only: PHPStan level 6 + TYPO3 coding standards
```

### Suites

| Suite | Command | Requirement |
|---|---|---|
| **0 Lint** | `extension/lint.sh` | none |
| **2a Unit** | `phpunit -c phpunit.xml.dist` | none |
| **2b Functional** | `phpunit -c phpunit.functional.xml.dist` | no Docker (SQLite) |
| **2c Smoke** | `typo3 sightmetrics:smoke` | demo stack running |
| **2d JS Smoke** | `npm test` (in `sight_metrics/`) | Node.js, no Docker |
| **3 E2E** | `e2e/run.sh` | demo stack running, Puppeteer |

### CI (GitHub Actions)

Three parallel jobs (`.github/workflows/ci.yml`):

| Job | What | Matrix |
|---|---|---|
| `lint-and-unit` | PHPStan + TYPO3 CS + PHPUnit unit | PHP 8.2, 8.3 |
| `pipeline` | DuckDB transform.sql + backup/notify/rotation/lock | – |
| `functional` | PHPUnit functional tests (SQLite, no Docker) | PHP 8.2, 8.3 |

Smoke and e2e tests only run locally (need the Docker stack).

### Functional tests in detail

`Tests/Functional/CubeRepositoryFunctionalTest.php` — 10 tests:

| Test | Checks |
|---|---|
| `testSitesReturnsEmptyWhenNoData` | empty DB → empty array |
| `testSitesReturnsAllSitesOrdered` | alphabetical site sort order |
| `testMetaReturnsCorrectAggregatesForSite` | KPI values are correct |
| `testMetaReturnsEmptyArrayForUnknownSite` | unknown site_id → empty |
| `testDailyReturnsRowsForCorrectSite` | daily() filters by site_id |
| `testCubeReturnsRowsFilteredBySite` | cube() only returns its own dims |
| `testSiteIsolation` | two sites are mutually isolated |
| `testDailyReturnsEmptyForSiteWithoutData` | no daily data → empty |
| `testCubeReturnsEmptyWhenNoDimensionRows` | site without cube rows → empty |
| `testCubeReturnsEmptyForUnknownSite` | unknown site_id in cube() → empty |

---

## 12. Troubleshooting

### "Analytics currently unavailable"

The cube DB is unreachable. Diagnostic steps:

```bash
# 1. Check the connection parameters
vendor/bin/typo3 sightmetrics:smoke

# 2. Test MariaDB directly
mysql -h <host> -P <port> -u report_ro -p analytics -e "SELECT 1 FROM meta LIMIT 1;"

# 3. Check the TYPO3 log
tail -f var/log/typo3_*.log
```

### CSP errors (Content Security Policy)

The backend module embeds JSON data inline (a CSP-safe
`<script type="application/json">` block) and uses self-hosted
Chart.js/Leaflet, loaded via the TYPO3 `PageRenderer`
(`addJsFooterFile`/`addCssFile`). If the TYPO3 instance sets a strict CSP,
console errors can still occur (e.g. from the bar lists' `style`
attributes).

Solution: extend the backend CSP specifically in `additional.php` or
`Configuration/ContentSecurityPolicies.php` instead of loosening it
globally.

### `trustedHostsPattern` errors

The demo sets `trustedHostsPattern = '.*'` (all hosts allowed). For
production: set the actual hostname:

```php
$GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = 'analytics\.authority\.example';
```

### No access to the module

The backend module `web_sightmetrics` requires user-group permissions. In
the TYPO3 backend under **Admin Tools → Users → User groups**: add the
"Web Analytics" module to the relevant group.

### Empty analytics despite imported data

- The `site_id` in `sites.conf` must match the site selected in the
  dropdown.
- Date picker: the default is the initially loaded time window
  (`windowDays`, default the last 92 days of available data) — check
  whether data falls within this range; select "Entire period" if needed.
- Check `SELECT COUNT(*) FROM meta;` on the cube DB.
