# SightMetrics cube database schema (normative contract)

This document is the **contract between package A (ingestion, writer) and
package B (TYPO3 extension, reader)**. The two packages share no code — only
these tables. Any change that breaks readers MUST increment the schema version
and be recorded here.

- Writer: `ingestion/sink_mysql.sql` declares `sm_schema_version` and stamps it
  into `meta.schema_version` on every import.
- Reader: `CubeRepository::SCHEMA_VERSION` is the highest version the extension
  understands. A **newer** version found in `meta` aborts the module and the
  `sightmetrics:health` command with a clear message. An older or missing
  version (legacy databases) is treated as compatible.

## Current version: 1

Table names are configurable (`SM_TABLE_CUBE`/`SM_TABLE_DAILY`/`SM_TABLE_META`,
default `cube`/`daily`/`meta`).

### `cube` — daily aggregates per dimension value

| Column | Type | Meaning |
|---|---|---|
| `site_id` | INTEGER | Site the row belongs to (multi-site) |
| `datum` | DATE | Day (UTC) |
| `dim` | VARCHAR | Dimension: `url`, `status`, `method`, `hour`, `download`, `entry`, `exit`, `referrer_type`, `referrer_name`, `referrer_url`, `keyword`, `country`, `browser`, `browser_version`, `os`, `os_version`, `device`, `device_model` |
| `dimkey` | VARCHAR | Dimension value. Drill-down dimensions encode `parent CHR(31) child` |
| `pv` | BIGINT | Page views (for `status`: all non-bot hits incl. 4xx/5xx) |
| `v` | BIGINT | Visits (for `status`: distinct affected visitors) |

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
| `schema_version` | INTEGER | Contract version written by the ingestion (since v1; NULL = legacy) |

## Semantics guaranteed by the writer

- A day is only written once it is **complete** (day-boundary cut, runbook §8);
  days of the current batch are replaced atomically per site (`DELETE` range +
  `INSERT`).
- Bot/crawler hits are excluded (UA heuristic / device-detector list,
  `SM_BOT_FILTER`).
- `datum` buckets are UTC; only the `hour` dimension follows `SM_TZ`.
- Database users: writer `cube_rw` (full DML), reader `report_ro`
  (`SELECT` only).

## Version history

| Version | Date | Change |
|---|---|---|
| 1 | 2026-07-07 | Initial versioned contract; adds `meta.schema_version` (older databases: column absent = legacy, read-compatible) |

## Rules for future changes

- **Additive** changes (new dimension values, new nullable columns): no version
  bump required; readers must ignore unknown columns/dimensions.
- **Breaking** changes (column rename/removal, type or semantics change):
  increment `sm_schema_version` in `ingestion/sink_mysql.sql`, raise
  `CubeRepository::SCHEMA_VERSION` in the same release, and document the
  migration here.
