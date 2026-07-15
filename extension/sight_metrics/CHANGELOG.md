# Changelog

## Unreleased

### Performance
- **Query indexes on the cube tables** (`sm_dim_datum`, `sm_drilldown`,
  `sm_daily`): the sink creates them idempotently on every import; for large
  existing cubes, `ingestion/migrations/v2_add_indexes.sql` can be run at a
  maintenance window instead. Measured on a ~870k-row cube: panel queries
  went from a full-table scan (~1.2s per query, ~13 queries per dashboard
  load) to an indexed range scan (~0.3s); drill-down clicks become
  millisecond lookups (the `parent` filter is only indexable since schema
  v2).
- **Cache TTL default 60s -> 21600s** (`cacheLifetime`): safe, because the
  cache keys include the date window and the window shifts forward with
  every nightly import — the default view automatically gets fresh keys.
  Subsequent loads (all users) then come from cache.
- **Top-N precompute** (new additive `topn` table, see
  `docs/topn-precompute-spec.md`): for the standard time windows (`last30`,
  `last90`, `last365`, `thisyear`, `lastyear`, `all`), the sink additionally
  precomputes the top-100 rows per dimension (including drill-down children)
  on every import. `CubeRepository::topN()` only uses it when the frontend
  sends the matching preset label AND it matches the requested time range
  exactly server-side — otherwise the live query runs unchanged; no
  correctness risk, just a potentially faster path for high-cardinality
  dimensions (`referrer_url`, `keyword`, `url`) over long windows. Perf
  effect on a large cube not yet measured (see the spec, "To check after
  implementation").
- **Extension version** is shown in the module footer (2.0.1 follow-up).

## 2.0.1 (2026-07-08)

### Fixed
- **Visitor map: horizontal stripes at Russia/Fiji.** world.js
  (world-atlas/Natural-Earth TopoJSON) contained polygon rings that cross
  the 180-degree meridian without being split there (`topojson-client`
  doesn't cut that automatically); Leaflet drew this as a continuous line
  across the full map width. Affected rings split at the antimeridian
  (reproducible via the new `scripts/fix-world-antimeridian.mjs`); Antarctica
  removed (more complex pole-hole topology, irrelevant for visitor data).
- Leaflet map switched to `preferCanvas: true` (more robust against SVG
  renderer seams for pure vector choropleths without a base map).

## 2.0.0 (2026-07-08) - Schema v2

**Breaking:** the extension now requires cube schema version 2. Migrate
existing DBs with `ingestion/migrations/v1_to_v2.sql` (idempotent) or
re-import; otherwise the module and `sightmetrics:health` abort with a clear
message.

### Changed (DB contract, docs/SCHEMA.md v2)
- **Local-time day buckets:** `datum`/`hour` and the day-boundary cut follow
  the site timezone `SM_TZ` (stored in `meta.tz`, default UTC); the frontend
  anchors relative time ranges ("Today", "Last 7 days") in this zone,
  `sightmetrics:health` computes data age in it too.
- **`cube.parent` column** replaces the CHR(31)-encoded drill-down keys:
  child queries are now simple (indexable) equality, display labels are
  plain values.
- **Neutral `referrer_type` keys** (`direct`/`search`/`social`/`website`)
  instead of German display values in the stored data; labels come from the
  XLF.
- **Multi-day uniques remain deliberately approximated:** exact values are
  fundamentally incompatible with the daily-salt privacy design (no linking
  visitors across days) — documented as a permanent design decision in
  SCHEMA.md.

### New
- **Contract test** (`tests/contract/run.sh` + `CubeContractTest`): a real
  ingestion import -> a real MariaDB -> a real CubeRepository, in CI (e2e
  job).

## 1.3.0 (2026-07-07)

### Quality push (grading-scale measures 1-5)
- **Versioned DB contract** (`docs/SCHEMA.md`): the ingestion stamps
  `meta.schema_version`; `CubeRepository::SCHEMA_VERSION` checks it when the
  module builds and in the `sightmetrics:health` command — a NEWER writer
  version aborts with a clear message, legacy DBs (without the column)
  remain compatible.
- **Onboarding page**: an empty cube shows a guided 3-step page instead of an
  empty dashboard; a dedicated "no access" notice for webmount restrictions
  (both localized).
- **Data-driven bot detection**: `ingestion/tools/fetch_bot_list.sh` builds a
  validated RE2 list (~800 patterns, `SM_BOT_RE_PATH`) from
  matomo/device-detector (`bots.yml`); without the list, the built-in
  heuristic is still used as a fallback.
- **Screenshots** in the ReST docs (`Documentation/Images/`), the German
  handbook points to the ReST docs as the authoritative source.
- **Frontend as native ES modules** (`Configuration/JavaScriptModules.php`,
  `loadJavaScriptModule()`): dashboard.js + `modules/{util,i18n,export}.js`;
  `tsc --checkJs` type checking (`npm run typecheck`) and JS tests in CI;
  referrer_type data values are localized for display.

### TER preparation
- **Complete localization**: all UI text (template, dashboard.js, error
  page) sourced from `locallang_mod.xlf` (English default) with a German
  translation (`de.locallang_mod.xlf`). dashboard.js receives the labels as
  a `lang` map in the payload (`DashboardController::jsLabels()`), country
  names via `Intl.DisplayNames` in the backend user's language, number
  formats via the backend user's locale.
- **ReST documentation** under `Documentation/` (docs.typo3.org format,
  English): Introduction, Installation, Configuration, Usage, Known
  Problems — including a clear note that the separately operated
  SightMetrics ingestion is a prerequisite.
- **Formalities**: author/email in `ext_emconf.php`/`composer.json`,
  `support` links, English extension description; `ext_conf_template.txt`
  labels in English, error-page defaults in English (overridable via
  extension configuration).

### Changed (Ingestion, package A)
- Day-boundary cut in the incremental import (no data loss at the day
  boundary; a day only appears once complete), bot/crawler filter
  (`SM_BOT_FILTER`), IPv6-robust parsing (country `??`), status-code panel
  shows 4xx/5xx, Edge/Opera detection, anchored referrer heuristic, `SM_TZ`
  for visit times, configurable download extensions (`SM_DOWNLOAD_RE`).
- Container hardened (non-root UID 10001, readOnlyRootFilesystem-capable),
  complete k8s manifests (`ingestion/scheduling/k8s/`), GHCR image workflow.

## 1.2.0 (2026-07-03)

### Security
- **User-based tenant separation**: site visibility follows the TYPO3
  webmount model (`SiteSelector::allowedSiteIds()`); a user without a
  webmount on a mapped site no longer sees that site's analytics. An empty
  permission set is no longer confused with "no mapping configured" (no
  fallback to "all sites").
- **Ajax route inherits module permission** (`inheritAccessFromModule`):
  backend users without the `web_sightmetrics` module get a 403.
- **CSV export hardened against formula injection** (leading `=`/`+`/`-`/`@`
  neutralized); technical error messages now only shown to admins; error
  logging via `LoggerAwareInterface`.

### New
- **Server-side Top-N + lazy loading** for all high-cardinality bar lists
  (search terms, entry/exit pages, downloads, status codes, HTTP methods,
  browser, OS, device type, referrer): only the top 8 (referrer URLs: 10)
  are in the initial payload; "+ N more" and drill-down children (browser
  version etc.) are lazy-loaded via the Ajax route `ajax_sightmetrics_topn`
  (`TopNAjaxController`, `TopNDims` whitelists,
  `CubeRepository::topN()`/`dimSummary()` with `parentKey` prefix filter).
- **Server-side segmented + lazy page tree**: `CubeRepository::urlTree()`
  extracts path segments with subtree sums directly in SQL (portable
  SUBSTR/INSTR, MariaDB + SQLite); the initial payload contains two levels
  (top 8 per level), deeper branches and "+ N more" are lazy-loaded via the
  Ajax route `ajax_sightmetrics_tree` (`TreeAjaxController`). The `url` rows
  are therefore no longer fully present in the payload. The shared
  site-access check for both Ajax endpoints is bundled in `AjaxSiteGuard`.
- **Query caching**: cube DB reads go through the TYPO3 cache
  `sight_metrics` (extension configuration `cacheLifetime`, default 60s, 0 =
  off). Operations: set up cache GC, see the handbook's "Known limitations".
- **CLI `sightmetrics:health`**: data freshness per site, Nagios-compatible
  exit codes, optional JSON (monitoring agents). Validates `--crit-hours >=
  --warn-hours`.
- **JS smoke test** (`Tests/JavaScript/`, node:test + jsdom) including
  Top-N/drill-down lazy loading; new test stage 2d in `run-tests.sh`.

### Changed
- **Charting library**: Apache ECharts (Apache-2.0) replaced by
  [Chart.js](https://www.chartjs.org/) (MIT) for the trend and hourly
  charts.
- **Visitor map**: instead of the ECharts map type (or the initially tested
  but not mature `chartjs-chart-geo` plugin), [Leaflet](https://leafletjs.com/)
  (BSD-2-Clause) is now used with `L.geoJSON` choropleth styling.
- Reason: bundling Apache-2.0 into a GPLv2 project would have required a
  license review (the extension's GPLv3 upward compatibility was in place,
  but MIT/BSD-2-Clause can be bundled without issue regardless of the target
  project's GPL version).
- **World map geodata** (`world.js`) replaced with a verified source (Natural
  Earth via [world-atlas](https://github.com/topojson/world-atlas) 2.0.2,
  public domain; provenance/checksums in `NOTICE.md`).
- **Vendor assets sourced via npm with version pinning**
  (`package.json`/`package-lock.json`, `npm run vendor:update`) instead of
  ad-hoc `curl`; REUSE-compliant license structure (`LICENSES/`,
  `REUSE.toml`, `LICENSE`).

## 1.1.0
- See git history.
