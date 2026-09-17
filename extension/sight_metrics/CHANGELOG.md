# Changelog

## 2.1.0 (2026-09-17)

### Privacy
- **IP anonymization at import** (`ingestion/anonymize.sql`, both log
  importers, always on): IPv4 loses its last octet, IPv6 is cut to `/48`,
  an address that is not recognisable as an IP fails closed to `-`. Runs
  before geo lookup, visitor key and cube. `uniques` can drop marginally; geo
  stays at country level but is no longer exact for ranges finer than /24.
- **Query strings are dropped at import** (`/suche?q=maier` -> `/suche`).
  `SM_URL_KEEP_PARAMS` keeps named parameters for TYPO3 installations without
  slug URLs; empty by default.
- **The referrer loses its query string as well**, one step later: the
  referrer host and the `keyword` (`?q=`) are derived first, then the referrer
  is pruned for the `referrer_url` dimension — scheme, host and path remain.
  This closes the last path by which a query parameter could reach the cube,
  in particular a same-site referrer carrying the parameters that are stripped
  from `url`. The `keyword` dimension is unaffected.
- Side effect: `/style.css?v=3` used to pass the asset filter and count as a
  pageview; without its query string it is now filtered out correctly.

### Performance
- **Query indexes on the cube tables** (`sm_dim_datum`, `sm_drilldown`,
  `sm_daily`), created idempotently by the sink;
  `ingestion/migrations/v2_add_indexes.sql` for existing large cubes.
  Measured on ~870k rows: panel queries ~1.2s -> ~0.3s, drill-down clicks
  become millisecond lookups.
- **Cache TTL default 60s -> 21600s** (`cacheLifetime`). Cache keys contain
  the date window, which shifts with every nightly import.
- **Top-N precompute** (additive `topn` table, see
  `docs/topn-precompute-spec.md`): the sink precomputes the top 100 rows per
  dimension for the standard time windows. `CubeRepository::topN()` uses it
  only when the requested range matches a preset exactly, otherwise the live
  query runs unchanged.
- Extension version is shown in the module footer.

### Fixed
- **Loki import in the ingestion image**: `day_filter.sql` was missing from
  the image and `curl`/`jq` were not installed. SQL files are now copied via
  glob, and the Loki path is verified in the container.
- **Test suites 0 and 2 reported success without running**: the demo compose
  mount did not match `EXT_SRC`, PHPStan analysed through a symlink (73
  phantom errors), and suite 2 referenced a non-existent compose file and an
  invalid entrypoint. `./run-tests.sh` is green end to end again.

### Changed
- **Base images updated**: ingestion `debian:trixie-slim` (Debian 13), demo
  `php:8.4-cli`, `mariadb:11.8` (`MARIADB_AUTO_UPGRADE=1`), `grafana/loki:3.7`,
  `grafana/grafana:13.2` (previously untagged).
- **Documentation screenshots regenerated** against the current UI.
  `e2e/screenshot.js` gained `--site`/`--anchor`, light/dark control and waits
  for Ajax-loaded panels.
- Dependency updates: `guzzlehttp/guzzle` 7.15.2, TYPO3 13.4.35 and `undici`
  7.29.1 in the demo/dev tooling (Dependabot alerts).

## 2.0.1 (2026-07-08)

### Fixed
- **Visitor map: horizontal stripes at Russia/Fiji.** The TopoJSON world data
  contained polygon rings crossing the 180° meridian unsplit, which Leaflet
  drew across the full map width. Affected rings are now split at the
  antimeridian (`scripts/fix-world-antimeridian.mjs`); Antarctica removed.
- Leaflet map switched to `preferCanvas: true` (more robust for pure vector
  choropleths).

## 2.0.0 (2026-07-08) – Schema v2

**Breaking:** the extension requires cube schema version 2. Migrate existing
DBs with `ingestion/migrations/v1_to_v2.sql` (idempotent) or re-import;
otherwise the module and `sightmetrics:health` abort with a clear message.

### Changed (DB contract, docs/SCHEMA.md v2)
- **Local-time day buckets**: `datum`/`hour` and the day-boundary cut follow
  the site timezone `SM_TZ` (`meta.tz`, default UTC); relative time ranges and
  `sightmetrics:health` use the same zone.
- **`cube.parent` column** replaces CHR(31)-encoded drill-down keys: child
  queries become indexable equality comparisons.
- **Neutral `referrer_type` keys** (`direct`/`search`/`social`/`website`)
  instead of German display values; labels come from the XLF.
- **Multi-day uniques remain deliberately approximated** — exact values are
  incompatible with the daily-salt privacy design (documented in SCHEMA.md).

### New
- **Contract test** (`tests/contract/run.sh` + `CubeContractTest`): real
  ingestion import -> real MariaDB -> real `CubeRepository`, in CI.

## 1.3.0 (2026-07-07)

### New
- **Versioned DB contract** (`docs/SCHEMA.md`): the ingestion stamps
  `meta.schema_version`, the module and `sightmetrics:health` verify it; a
  newer writer version aborts with a clear message, legacy DBs stay
  compatible.
- **Onboarding page** for an empty cube, plus a dedicated notice for webmount
  restrictions (both localized).
- **Data-driven bot detection**: `ingestion/tools/fetch_bot_list.sh` builds a
  validated RE2 list (~800 patterns) from matomo/device-detector; the built-in
  heuristic remains as fallback.
- **Frontend as native ES modules** (`Configuration/JavaScriptModules.php`):
  dashboard.js + `modules/{util,i18n,export}.js`, `tsc --checkJs` type checks
  and JS tests in CI.

### TER preparation
- **Complete localization**: all UI text from `locallang_mod.xlf` (English
  default) with a German translation; country names via `Intl.DisplayNames`,
  number formats via the backend user's locale.
- **ReST documentation** under `Documentation/` (docs.typo3.org format),
  including the note that the separately operated ingestion is a prerequisite.
- **Formalities**: author/support metadata in `ext_emconf.php` and
  `composer.json`, English extension description and configuration labels.

### Changed (ingestion, package A)
- Day-boundary cut in the incremental import, bot filter (`SM_BOT_FILTER`),
  IPv6-robust parsing, 4xx/5xx in the status panel, Edge/Opera detection,
  anchored referrer heuristic, `SM_TZ`, configurable download extensions.
- Container hardened (non-root UID 10001, readOnlyRootFilesystem-capable),
  k8s manifests (`ingestion/scheduling/k8s/`), GHCR image workflow.

## 1.2.0 (2026-07-03)

### Security
- **User-based tenant separation**: site visibility follows the TYPO3 webmount
  model (`SiteSelector::allowedSiteIds()`); an empty permission set no longer
  falls back to "all sites".
- **Ajax route inherits module permission** (`inheritAccessFromModule`).
- **CSV export hardened against formula injection**; technical error messages
  are shown to admins only.

### New
- **Server-side Top-N + lazy loading** for all high-cardinality bar lists:
  only the top 8 (referrer URLs: 10) ship in the initial payload, the rest and
  drill-down children load via `ajax_sightmetrics_topn`.
- **Server-side segmented + lazy page tree** (`CubeRepository::urlTree()`,
  portable SUBSTR/INSTR): two levels in the payload, deeper branches via
  `ajax_sightmetrics_tree`. Site-access checks for both routes live in
  `AjaxSiteGuard`.
- **Query caching** via the TYPO3 cache `sight_metrics` (`cacheLifetime`).
- **CLI `sightmetrics:health`**: data freshness per site, Nagios-compatible
  exit codes, optional JSON output.
- **JS smoke test** (node:test + jsdom) including Top-N/drill-down lazy
  loading.

### Changed
- **Charting library**: Apache ECharts replaced by Chart.js (MIT); the visitor
  map now uses Leaflet (BSD-2-Clause) with `L.geoJSON` choropleth styling.
  Reason: MIT/BSD-2 can be bundled into a GPLv2 project without a license
  review.
- **World map geodata** replaced with a verified source (Natural Earth via
  world-atlas 2.0.2, public domain; provenance in `NOTICE.md`).
- **Vendor assets sourced via npm with pinned versions**
  (`npm run vendor:update`); REUSE-compliant license structure.

## 1.1.0
- See git history.
