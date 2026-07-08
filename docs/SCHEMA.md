# SightMetrics cube database schema (normative contract)

This document is the **contract between package A (ingestion, writer) and
package B (TYPO3 extension, reader)**. The two packages share no code — only
these tables. Any change that breaks readers MUST increment the schema version
and be recorded here.

- Writer: `ingestion/sink_mysql.sql` declares `sm_schema_version` and stamps it
  into `meta.schema_version` on every import.
- Reader: `CubeRepository::SCHEMA_VERSION` is the schema version the extension
  requires. Since v2 the reader needs an **exact match**: a newer version
  aborts asking to update the extension; an older/missing version aborts
  pointing to the migration (`ingestion/migrations/v1_to_v2.sql`) or a
  re-import. Both the backend module and `sightmetrics:health` enforce this.

## Current version: 2

Table names are configurable (`SM_TABLE_CUBE`/`SM_TABLE_DAILY`/`SM_TABLE_META`,
default `cube`/`daily`/`meta`).

### `cube` — daily aggregates per dimension value

| Column | Type | Meaning |
|---|---|---|
| `site_id` | INTEGER | Site the row belongs to (multi-site) |
| `datum` | DATE | Day in the site's timezone (`meta.tz`, default UTC) |
| `dim` | VARCHAR | Dimension: `url`, `status`, `method`, `hour`, `download`, `entry`, `exit`, `referrer_type`, `referrer_name`, `referrer_url`, `keyword`, `country`, `browser`, `browser_version`, `os`, `os_version`, `device`, `device_model` |
| `parent` | VARCHAR NULL | Parent value for drill-down dimensions (`browser_version` → browser name, `os_version` → os name, `device_model` → device type, `referrer_name` → referrer_type key, `referrer_url` → referrer name); NULL for root dimensions |
| `dimkey` | VARCHAR | Dimension value (plain; since v2 no `CHR(31)` encoding) |
| `pv` | BIGINT | Page views (for `status`: all non-bot hits incl. 4xx/5xx) |
| `v` | BIGINT | Visits (for `status`: distinct affected visitors) |

`referrer_type` values are language-neutral keys since v2: `direct`, `search`,
`social`, `website`. Display labels live in the reader (extension XLF).

### `daily` — one row per site and day

| Column | Type |
|---|---|
| `site_id` | INTEGER |
| `datum` | DATE |
| `visits`, `pageviews`, `uniques`, `bounces`, `bytes` | BIGINT |

### `meta` — one row per site (replaced on every import)

| Column | Type | Meaning |
|---|---|---|
| `site_id` | INTEGER | |
| `site` | VARCHAR | Display name |
| `von`, `bis` | VARCHAR | First/last day with data (`YYYY-MM-DD`) |
| `visits_total`, `pageviews_total`, `uniques_total`, `bounces_total`, `bytes_total` | BIGINT | Totals over `daily` (`uniques_total` additively approximated) |
| `erzeugt` | VARCHAR | Timestamp of last import (`YYYY-MM-DD HH:MM`) |
| `tz` | VARCHAR | Site timezone used for `datum`/`hour` bucketing (`SM_TZ`, e.g. `Europe/Berlin`; since v2) |
| `schema_version` | INTEGER | Contract version written by the ingestion (since v1; NULL = legacy) |

## Semantics guaranteed by the writer

- A day is only written once it is **complete** (day-boundary cut, runbook §8);
  days of the current batch are replaced atomically per site (`DELETE` range +
  `INSERT`).
- Bot/crawler hits are excluded (UA heuristic / device-detector list,
  `SM_BOT_FILTER`).
- `datum` and `hour` buckets follow the site timezone `SM_TZ` (written to
  `meta.tz`; default UTC). The day-boundary cut of the incremental import uses
  the same timezone, so a day is only written once it is complete in **local**
  time.
- Exact multi-day unique visitors are **impossible by design**: the visitor
  hash is salted per import day precisely so visitors cannot be linked across
  days (privacy by design, GDPR/BSI audience). `uniques_total` and any
  multi-day uniques therefore remain additive approximations, labelled as such
  in the UI. This is a deliberate, permanent trade-off, not a gap.
- Database users: writer `cube_rw` (full DML), reader `report_ro`
  (`SELECT` only).

## Contract test

`tests/contract/run.sh` enforces this document mechanically: it imports
`ingestion/tests/fixture.log` through the real ingestion into the demo MariaDB
(site 990, built-in heuristics forced for determinism) and then reads the
numbers back through the extension's `CubeRepository`
(`Tests/Functional/CubeContractTest.php`, read-only user `report_ro`).
Runs locally (`bash tests/contract/run.sh`, needs Docker) and in CI (e2e job).

## Version history

| Version | Date | Change |
|---|---|---|
| 2 | 2026-07-08 | Local-time day buckets (`SM_TZ` → `meta.tz`); `cube.parent` column replaces the `CHR(31)` dimkey encoding; `referrer_type` values become neutral keys (`direct`/`search`/`social`/`website`); reader requires an exact version match. Migration: `ingestion/migrations/v1_to_v2.sql` (or re-import) |
| 1 | 2026-07-07 | Initial versioned contract; adds `meta.schema_version` (older databases: column absent = legacy, read-compatible) |

## Rules for future changes

- **Additive** changes (new dimension values, new nullable columns): no version
  bump required; readers must ignore unknown columns/dimensions.
- **Breaking** changes (column rename/removal, type or semantics change):
  increment `sm_schema_version` in `ingestion/sink_mysql.sql`, raise
  `CubeRepository::SCHEMA_VERSION` in the same release, and document the
  migration here.
