# Package A – Ingestion / analytics (DuckDB) · the operational part

This is the **write side** of SightMetrics: it reads web server logs,
reduces them to daily aggregates with **[DuckDB](https://duckdb.org/)**, and
writes the result into the MariaDB **cube DB** (`analytics`, writer user
`cube_rw`). Package A is the **sole writer** of the cube DB — the TYPO3
extension (package B) only reads.
→ Overall overview: [repo README](../README.md).

---

## What happens here (data flow)

```
access.log  ─►  parse (regex)  ─►  sessionize  ─►  aggregate  ─►  cube DB (MariaDB)
                transform.sql      (IP+UA, 30 min)   (per day/dim)   cube / daily / meta
```

DuckDB does all the heavy lifting in C (parsing, GeoIP join, sessionization,
aggregation) in memory and only writes the finished result via `ATTACH` into
MariaDB. Per site, the result lands in three tables:

- `cube(site_id, datum, dim, dimkey, pv, v)` – pageviews + visits per day/dimension/value
- `daily(site_id, datum, visits, pageviews, uniques, bounces, bytes)` – daily metrics
- `meta(site_id, …)` – overall metadata per site (time range, totals)

The import is **incremental** (byte offset per log file) and **idempotent
per site**: the cube write step always only replaces the processed date
range, running it multiple times never duplicates data.

---

## Scripts & files

| File | Purpose |
|---|---|
| `run_all.sh` | **Orchestrator**: imports all sites from `sites.conf` (flock-protected, `PARALLEL`/`auto`), alerts on failure via `notify.sh`. The container's default run. |
| `load_cube.sh` | **Single-site import (file)**: DuckDB → `ATTACH` MariaDB, incremental (byte offset), per-site lock, measures wall/CPU time. Usage: `load_cube.sh <logfile> "<site name>" <site_id>`. |
| `fetch_loki_logs.sh` | **Single-site import (Grafana Loki, alternative to a file)**: pulls lines via LogQL **day by day** (local calendar day 00:00→24:00 into a temp file), writes each day to MariaDB individually; incremental via a daily state instead of a byte offset, the previous day is overwritten on re-run. |
| `transform.sql` | **Analytics logic** (sink-neutral): parse → sessionize → `cube_rows`/`daily_rows`. |
| `cube_to_mysql.sql` | Compute driver of the log path (reads `transform.sql`). |
| `sink_mysql.sql` | **Shared MariaDB sink** (schema, idempotent range-DELETE+INSERT, meta). Used by both the log **and** the Matomo path. |
| `matomo_import.sh` / `matomo_to_cube.sql` | **Matomo legacy-data import** via the Reporting API → see [`docs/matomo-import.md`](../docs/matomo-import.md). |
| `purge_cube.sh` | Retention purge (deletes cube data older than `RETENTION_MONTHS`). |
| `backup_cube.sh` | Backup/rollback point of the cube DB (mysqldump + rotation). |
| `notify.sh` | Alerting (email and/or webhook), configurable. |
| `rotate_cube_secret.sh` | Rotation of the DB secret. |
| `generate_logs.py` | Test-log generator. |
| `lib_geo.sh` / `lib_logformat.sh` / `lib_healthcheck.sh` | Shared building blocks (sourced by `load_cube.sh` and `fetch_loki_logs.sh`): geo-source selection, log-format selection, healthcheck heartbeat. |
| `geo_sources/` | Geo join per source: `native`, `ip2location`, `dbip`, `maxmind` (see runbook §3a). |
| `log_formats/` | Log parsing per format: `regex` (plain text, default) or `json_ecs` (structured JSON, see runbook §7). |
| `bin/duckdb` (v1.5.4) · `geo/` | DuckDB engine (static binary) + GeoIP data. |
| `sites.conf.example` | Template for `sites.conf` (`site_id` TAB logfile TAB name). |
| `scheduling/` | systemd/cron templates for production operation. |

---

## Requirements

- **Reachable cube DB** (MariaDB) with writer user `cube_rw`; DSN via
  `CUBE_DSN` or `CUBE_DSN_FILE` (Docker secret pattern). In the demo, the
  `demo/` stack provides this.
- The bundled `bin/duckdb` (no system DuckDB needed).
- Logs in **combined/common log format** (Apache/nginx); other formats via
  `SM_LOG_FORMAT` / a custom regex — see the runbook.

---

## Quick start

```bash
# Import a single site
./load_cube.sh ../logs/example_1k.log "Sample Authority" 1

# All sites from sites.conf (sequential or parallel)
CUBE_DSN="host=… user=cube_rw password=… database=analytics" ./run_all.sh --parallel auto
```

As a **container** (nightly one-shot) via the demo stack:

```bash
cd ../demo && docker compose --profile import run --rm ingestion
```

---

## Alternative log source: Grafana Loki

If logs are already centrally collected via **Loki** (e.g. Promtail +
Grafana/Prometheus stack), `fetch_loki_logs.sh` can be used instead of a log
file — processes **day by day**: for each local calendar day (`--timezone`,
default `Europe/Berlin`), the 00:00:00→23:59:59 window is pulled via LogQL
into a temp file (`SM_TMPDIR`, default `/tmp`), aggregated by DuckDB (memory
limit `DUCKDB_MEMORY_LIMIT`, default 2GB, spills to disk), and written to
MariaDB, only then does the next day follow. This keeps even 1–2GB of logs
per day manageable, and produces exactly one `daily` row per day.
Prerequisite: the Loki lines contain the full raw line (Apache/nginx
combined or JSON/ECS, see `SM_LOG_FORMAT`).

```bash
CUBE_DSN="host=… user=cube_rw password=… database=analytics" \
  ./fetch_loki_logs.sh --url http://loki:3100 \
                       --query '{job="nginx"}' --namespace authority-a \
                       --site-id 1 --site-name "Authority A"
```

Designed for **one run per day** (e.g. shortly after midnight): imports the
previous day; missed days are caught up via the **daily state**
(`<hash>.loki_day` instead of a byte offset), the currently running
(incomplete) day is skipped. The previous day is **re-imported and
replaced** on every run (range-DELETE+INSERT in the sink) — so the script
can safely run multiple times, or during the day. First run:
`--lookback-days N` (full days back, ending yesterday). `--namespace` is a
convenience option mixed in as an additional label matcher in `--query`. All
options: `fetch_loki_logs.sh --help`.

## Heartbeat monitoring (healthchecks.io)

`run_all.sh` and `fetch_loki_logs.sh` optionally ping a **healthcheck
endpoint** (healthchecks.io or self-hosted) on start/success/failure —
complementing `notify.sh` (which only alerts on *active* failures within a
run) with detection of a **missing** run (scheduler dead, container doesn't
start, …):

```bash
export HEALTHCHECK_URL="https://hc-ping.com/<uuid>"   # or HEALTHCHECK_URL_FILE
```

Empty/unset = disabled (no-op). See `lib_healthcheck.sh`.

---

## Operations (production)

Nightly disposable container, persistent `STATE_DIR` volume
(offsets/locks/metrics), DSN as a runtime secret, scheduling,
monitoring/alerting, retention, log rotation, recovery:

- **[`scheduling/README_scheduling.md`](scheduling/README_scheduling.md)** – scheduling templates
- **[Ingestion runbook](../docs/ingestion-runbook.md)** – full operations
  documentation (setting up the cube DB, secrets, log formats,
  parallelization, privacy/BSI, rollback, important env variables).
