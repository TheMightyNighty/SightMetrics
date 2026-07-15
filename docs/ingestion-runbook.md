# SightMetrics – Ingestion Runbook (Package A)

Operations documentation for the **DuckDB-based log import** (`ingestion/`).
This part is the sole writer of the cube DB. The TYPO3 extension (package B)
only reads.

---

## Table of contents

1. [File structure](#1-file-structure)
2. [Setting up the cube DB](#2-setting-up-the-cube-db)
3. [Log requirements](#3-log-requirements)
3a. [GeoIP dataset (TODO for operators)](#3a-geoip-dataset-todo-for-operators)
4. [Quick start](#4-quick-start)
5. [Configuring sites.conf](#5-configuring-sitesconf)
6. [CUBE_DSN – secrets](#6-cube_dsn--secrets)
7. [Configuring the log format](#7-configuring-the-log-format)
8. [Incremental import & offset tracking](#8-incremental-import--offset-tracking)
9. [Scheduling (disposable container)](#9-scheduling-disposable-container)
10. [Parallelization & concurrency](#10-parallelization--concurrency)
11. [Retention & purging](#11-retention--purging)
12. [Monitoring & alerting](#12-monitoring--alerting)
13. [Log rotation](#13-log-rotation)
14. [Multi-site](#14-multi-site-one-instance-multiple-sites)
15. [Error runbook & recovery](#15-error-runbook--recovery)
16. [Privacy & BSI notes](#16-privacy--bsi-notes)
17. [Rollback](#17-rollback)
17a. [Updating from version to version](#17a-updating-from-version-to-version)
18. [Important env variables](#18-important-env-variables)

---

## 1. File structure

```
ingestion/
├── load_cube.sh                Single-site import (file): log → DuckDB → MariaDB
├── fetch_loki_logs.sh          Single-site import (Grafana Loki, alternative to a file)
├── run_all.sh                  Multi-site orchestrator (flock-protected, xargs -P)
├── purge_cube.sh                Retention purge: deletes cube data older than RETENTION_MONTHS
├── backup_cube.sh              Backup of the cube DB (mysqldump + rotation, rollback point)
├── notify.sh                   Alerting (email and/or webhook), configurable
├── rotate_cube_secret.sh       Secret rotation: renews the DB password + DSN file atomically
├── matomo_import.sh            Matomo legacy-data import via the Reporting API (see docs/matomo-import.md)
├── lib_geo.sh                  Geo-source selection (sourced by load_cube.sh/fetch_loki_logs.sh)
├── lib_logformat.sh            Log-format selection (sourced by load_cube.sh/fetch_loki_logs.sh)
├── lib_healthcheck.sh          Healthcheck heartbeat (sourced by run_all.sh/fetch_loki_logs.sh)
├── cube_to_mysql.sql           Compute driver, log path (reads transform.sql)
├── matomo_to_cube.sql          Compute driver, Matomo path (transform.sql equivalent)
├── transform.sql               Parse → sessionize → aggregate (sink-neutral)
├── sink_mysql.sql              Shared MariaDB sink (log and Matomo path)
├── sites.conf.example          Template for sites.conf (site_id TAB logfile TAB name)
├── generate_logs.py            Test-log generator (session-based, public IPs)
│
├── bin/
│   └── duckdb                  DuckDB CLI binary (v1.5.4, x86_64 Linux)
│
├── geo_sources/
│   ├── native.sql               Geo join: own schema (start,end,cc)
│   ├── ip2location.sql          Geo join: IP2Location LITE DB1
│   ├── dbip.sql                 Geo join: DB-IP Country-Lite
│   └── maxmind.sql              Geo join: MaxMind GeoLite2 Country
│
├── log_formats/
│   ├── regex.sql                Log parsing: plain-text lines (combined/combined_vhost/common/custom)
│   └── json_ecs.sql             Log parsing: structured JSON (ECS schema)
│
├── geo/                         NOT in the repo (.gitignore) – TODO: see §3a
│   └── country-ipv4-num.csv   GeoIP dataset (IPv4 → country code, numeric)
│
├── scheduling/
│   └── README_scheduling.md    Operating the disposable container (cron/CronJob, no systemd)
│
└── tests/
    ├── fixture.log             Minimal test log (known values, deterministic)
    ├── geo_mini.csv            Minimal GeoIP dataset for tests (a single IP)
    ├── pipeline_test.sql       Metrics + dims + envsubst + purge validation
    └── run.sh                  Pipeline test runner (suite 1, no Docker needed)
```

### Production layout (target directories)

```
/opt/sightmetrics/ingestion/       Repo deployment / install directory
  load_cube.sh                     Single-site import (file)
  fetch_loki_logs.sh               Single-site import (Grafana Loki, optional)
  run_all.sh                       Orchestrator (multi-site, flock)
  purge_cube.sh                    Retention purge
  lib_geo.sh / lib_logformat.sh /
  lib_healthcheck.sh               Shared building blocks (required by load_cube.sh/fetch_loki_logs.sh)
  transform.sql / sink_mysql.sql   DuckDB core logic + MariaDB sink
  cube_to_mysql.sql                DuckDB-MariaDB bridge
  geo_sources/ · log_formats/      Geo-join and log-parsing variants (required)
  sites.conf                       Site list (create from sites.conf.example)
  bin/duckdb                       DuckDB binary
  geo/country-ipv4-num.csv         GeoIP dataset

/etc/sightmetrics/
  cube_dsn.env                     CUBE_DSN=... (permissions: root:sightmetrics 0640)

/var/lib/sightmetrics/state/
  <hash>.offset                    Byte offset + inode per site/log
  run_all.lock                     flock lockfile
  site_N.last                      Last import status per site (for monitoring)
  metrics.log                      Cumulative import-metrics log

/var/log/sightmetrics/import/
  run_YYYYMMDD_HHMMSS.log          Overall log per run
  site_N_YYYYMMDD_HHMMSS.log       Per-site log
```

---

## 2. Setting up the cube DB

### Create the MariaDB database + users

```bash
# As root on the MariaDB server (or via Docker):
mysql -u root -p <<'SQL'
CREATE DATABASE IF NOT EXISTS analytics
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Writer user (ingestion/DuckDB only)
CREATE USER IF NOT EXISTS 'cube_rw'@'%' IDENTIFIED BY '<SECURE_PASSWORD>';
GRANT ALL PRIVILEGES ON analytics.* TO 'cube_rw'@'%';

-- Read-only user (TYPO3 extension only)
CREATE USER IF NOT EXISTS 'report_ro'@'%' IDENTIFIED BY '<SECURE_PASSWORD>';
GRANT SELECT ON analytics.* TO 'report_ro'@'%';

FLUSH PRIVILEGES;
SQL
```

The tables (`cube`, `daily`, `meta`) are created automatically on the
**first import** — no separate `CREATE TABLE` needed.

**Upgrading from schema v1** (imports before extension 2.0): run
`mysql -u cube_rw -p analytics < ingestion/migrations/v1_to_v2.sql` once
(idempotent), or re-import all logs — extension 2.x refuses v1 data with a
clear message. Details: [`docs/SCHEMA.md`](SCHEMA.md). For updates in
general (which migration is needed when), see
[§17a](#17a-updating-from-version-to-version).

### Demo stack

In the demo, `demo/initdb/01-analytics.sh` sets this up automatically on
`docker compose up`. Passwords come from `demo/.env` (copy from
`demo/.env.example` and adjust).

---

## 3. Log requirements

The ingestion script expects nginx/Apache access logs in the standard
combined format or a compatible JSON format. Required fields:

| Field | Content | Why |
|---|---|---|
| Timestamp | ISO-8601 / UTC with timezone | session assignment, day buckets |
| Client IP | the real client IP (not a proxy IP) | GeoIP, unique-visitor hash |
| HTTP method | GET/POST/… | filtering, analytics |
| URL path + query | `/page?param=value` | page tree, internal search |
| HTTP status | 200/301/404/… | filtering (4xx/5xx) |
| Bytes | response size | bandwidth analytics |
| Referrer | origin | referrer types, search terms |
| User agent | browser string | browser/OS/device detection |

**Important:**
- **Real client IP**: behind a reverse proxy/CDN, `X-Forwarded-For` /
  `CF-Connecting-IP` must be written into the log, otherwise GeoIP and
  visitor recognition are wrong.
- **Clocks synchronized via NTP** on all web servers.
- **Chronological order**: lines must be in ascending time order (the
  default for access logs) — the incremental import's day-boundary cut
  (§8) cuts the batch off at the first line of the still-running day.
- **No sampling**: every line is counted.
- **Consistent format** across all sites and servers (nginx and Apache
  identical).
- **IPv6** is counted (visits/pageviews/unique hash). GeoIP mapping for
  IPv6 is optional: point `SM_GEO6_PATH` at a text range file
  (`start_ip,end_ip,cc`; the DB-IP CSV contains IPv4+IPv6 in one file and
  can be used directly). Without a v6 file → country `??`. Technically:
  the DuckDB `inet` extension (bundled in the container image; installed
  on first run locally/in CI).
- **Bot filter**: lines with crawler/CLI/monitoring user agents (Googlebot,
  curl, uptime checks, scanners, …) are **excluded** — like Matomo, only
  human visitors are counted. Two tiers:
  - **Recommended (Matomo-comparable):** run `./tools/fetch_bot_list.sh`
    once — builds a validated list `bots/bot_regex.list` (~800 patterns)
    from [matomo/device-detector](https://github.com/matomo-org/device-detector)
    (`bots.yml`, LGPL-3.0-or-later, therefore not in the repo/image). If
    the file is present at the default path (or under `SM_BOT_RE_PATH`),
    it's used automatically; the list **completely replaces** the
    heuristic. Regenerate periodically (e.g. quarterly), mount as a volume
    in the container.
  - **Fallback:** without the list, a built-in UA heuristic is used.

  `SM_BOT_FILTER=0` disables the filter entirely. Empty user agents
  deliberately don't count as bots (the `common` format has no UA at all).
  Exception: the `status` dimension additionally includes 4xx/5xx lines
  (error diagnosis); bots are still excluded there too.
- Mask/filter out PII in query strings (tokens, emails) before import.

- **Browser/OS detection**: the default is a fast UA heuristic. For
  Matomo-identical names/versions, run `./tools/fetch_ua_lists.sh` once —
  builds validated lists under `ua/` from matomo/device-detector
  (`browsers.yml`/`oss.yml`, LGPL-3.0-or-later, therefore not in the
  repo/image). If present there (or under `SM_UA_BROWSERS_PATH`/
  `SM_UA_OSS_PATH`), they're used automatically; UAs without a list match
  fall back to the heuristic. Cost: the regex matching scales with
  (distinct UAs in the batch) × (~930 patterns) — not a concern for the
  nightly one-shot, but worth watching runtime on very UA-diverse large
  sites. Device type/model remains heuristic (device detection is
  substantially more complex in device-detector).
  **Known limitation:** `tools/fetch_ua_lists.sh` drops upstream regex
  patterns using constructs DuckDB's RE2 engine can't compile (e.g.
  lookbehind assertions), without a fallback substitute for the dropped
  patterns. One consequence: `ua/oss.tsv` is missing the generic Android
  catch-all pattern, so a modern Android user agent that doesn't match one
  of the remaining, more specific Android patterns is misclassified as
  `GNU/Linux`.

**Analytics tuning (env, optional):**

| Variable | Default | Effect |
|---|---|---|
| `SM_BOT_FILTER` | `1` | `0` = count bot/crawler lines too |
| `SM_TZ` | `UTC` | **Site timezone (schema v2):** day buckets (`datum`), visit times (`hour`), and the day-boundary cut are computed in this zone (e.g. `Europe/Berlin`); written to `meta.tz`. |
| `SM_DOWNLOAD_RE` | pdf/zip/Office/… | regex (against the lowercased URL) for download detection |
| `SM_UA_BROWSERS_PATH` / `SM_UA_OSS_PATH` | `ua/browsers.tsv` / `ua/oss.tsv` | device-detector lists for browser/OS (tools/fetch_ua_lists.sh); the heuristic is used without these files |
| `SM_GEO6_PATH` | – | IPv6 geo ranges (`start_ip,end_ip,cc`, e.g. the DB-IP CSV); without a file, IPv6 stays at country `??` |
| `SM_COMPLETE_DAYS` | `1` | `0` = disable the day-boundary cut (only useful for backfills/tests, see §8) |

---

## 3a. GeoIP dataset (TODO for operators)

**The GeoIP CSV is not part of the repo** (`ingestion/geo/` is in
`.gitignore`) and must be sourced and placed by each operator themselves —
the licensing differs per source, so no file is bundled. Without this file,
the import aborts with a clear error message (`load_cube.sh` checks for its
presence before running).

Three freely available sources are supported, selectable via
`SM_GEO_SOURCE`:

| `SM_GEO_SOURCE` | Provider | License | Download | Account needed |
|---|---|---|---|---|
| `native` *(default)* | own/pre-converted format | – (self-managed) | – | – |
| `ip2location` | IP2Location LITE DB1 | CC-BY-SA-4.0 (attribution) | https://lite.ip2location.com/database/ip-country | yes (free) |
| `dbip` | DB-IP Country-Lite | CC-BY-4.0 (attribution) | https://db-ip.com/db/download/ip-to-country-lite | no |
| `maxmind` | MaxMind GeoLite2 Country | EULA (attribution, redistribution of raw data restricted) | https://www.maxmind.com/en/geolite2/eula | yes (license key) |

**Location:**

```
ingestion/geo/<downloaded file(s)>
```

Paths are configurable (defaults match `native`):

| Variable | Default | Meaning |
|---|---|---|
| `SM_GEO_SOURCE` | `native` | `native` \| `ip2location` \| `dbip` \| `maxmind` |
| `SM_GEO_PATH` | `geo/country-ipv4-num.csv` | path to the selected source's main CSV |
| `SM_GEO_LOC_PATH` | `geo/GeoLite2-Country-Locations-en.csv` | `maxmind` only: locations file (geoname ID → country code) |

The expected raw format per source is documented in
`ingestion/geo_sources/<source>.sql` (which also contains the SQL
conversion into the internal `start,end,cc` schema). `native` is
SightMetrics's own format (no header, `start,end,cc` as
integer/integer/ISO-2 code) — e.g. for a self-assembled dataset built from
RIR data (APNIC/ARIN/RIPE).

```bash
# Example: using IP2Location LITE
SM_GEO_SOURCE=ip2location SM_GEO_PATH=/opt/sightmetrics/ingestion/geo/IP2LOCATION-LITE-DB1.CSV \
  ./load_cube.sh /logs/access.log "Authority A" 1
```

---

## 4. Quick start

```bash
# 1. Requirements
#    - DuckDB binary present: ingestion/bin/duckdb
#    - CUBE_DSN set (or CUBE_DSN_FILE)
#    - MariaDB with the 'analytics' DB + cube_rw user reachable

# 2. Single-site import (interactive, for testing)
cd ingestion
CUBE_DSN="host=127.0.0.1 port=3306 user=cube_rw password=<PW> database=analytics" \
  ./load_cube.sh /logs/access.log "My Authority" 1

# 3. Multi-site import (production, from sites.conf)
CUBE_DSN="..." ./run_all.sh

# 4. Check the result
mysql -u report_ro -p analytics -e "SELECT * FROM meta;"
```

---

## 5. Configuring sites.conf

```bash
cp ingestion/sites.conf.example /opt/sightmetrics/ingestion/sites.conf
```

Format: `site_id<TAB>logfile<TAB>site_name` — one site per line. Blank
lines and `#` comments are ignored.

```
# /opt/sightmetrics/ingestion/sites.conf
1	/logs/authority-a/access.log	Authority A
2	/logs/school-office-b/access.log	School Office B
3	/logs/utilities/access.log	Utilities C
```

**`site_id`** is the primary key in the cube — once assigned, don't change
it. If a site is removed, its historical data remains in the cube DB (no
automatic deletion).

---

## 6. CUBE_DSN – secrets

Never store passwords in `sites.conf` or scripts.

### Option 1: environment variable

```bash
export CUBE_DSN="host=db port=3306 user=cube_rw password=<PW> database=analytics"
./run_all.sh
```

### Option 2: secret file (recommended for containers/cron)

```bash
# Create the file
sudo mkdir -p /etc/sightmetrics
echo 'CUBE_DSN=host=db port=3306 user=cube_rw password=<PW> database=analytics' \
  | sudo tee /etc/sightmetrics/cube_dsn.env
sudo chmod 640 /etc/sightmetrics/cube_dsn.env
sudo chown root:sightmetrics /etc/sightmetrics/cube_dsn.env
```

`load_cube.sh` and `run_all.sh` automatically read from `CUBE_DSN_FILE`
(default: `/run/secrets/cube_dsn`) if `CUBE_DSN` isn't set.

### Secret rotation

`rotate_cube_secret.sh` renews the DB password (`ALTER USER`) **and**
rewrites the DSN secret file atomically. Because every script reads the DSN
fresh from the file on **every** run, rotation is effectively
uninterrupted — no service restart needed. A backup of the old DSN is kept
(`<file>.bak-<ts>`, count via `ROTATE_KEEP_BACKUPS`).

```bash
# Rotate the ingestion user (cube_rw), auto-generate the password:
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env \
  ROTATE_ADMIN_USER=root ROTATE_ADMIN_PASSWORD_FILE=/etc/sightmetrics/mariadb_root.pw \
  ./rotate_cube_secret.sh

# Dry run (shows the masked new DSN, changes nothing):
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env ROTATE_DRY_RUN=1 ./rotate_cube_secret.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `CUBE_DSN_FILE` | – (required) | secret file to be rewritten |
| `ROTATE_NEW_PASSWORD` | (random) | new password; otherwise generated via `openssl rand` |
| `ROTATE_USER` / `ROTATE_USER_HOST` | from the DSN / `%` | DB user to rotate |
| `ROTATE_ADMIN_USER` | `root` | admin with `ALTER` privilege |
| `ROTATE_ADMIN_PASSWORD` / `…_FILE` | – | admin password (file preferred) |
| `ROTATE_KEEP_BACKUPS` | `5` | number of old DSN backups to keep |
| `ROTATE_DRY_RUN` / `ROTATE_SKIP_DB` | – | show only / don't change the DB (file only) |

After setting the new password, the script verifies the login (`SELECT
1`). Run as a separate, infrequent scheduled job if needed (e.g.
quarterly).

**Reporting user (`report_ro`):** rotated separately; afterwards adjust the
TYPO3 connection in `config/system/additional.php` (see extension handbook
§4). A read-only user without write access is also suitable as backup
credentials (`BACKUP_DSN`).

---

## 7. Configuring the log format

The ingestion script supports several web server log formats via the env
variable `SM_LOG_FORMAT`. Default is `combined` (Apache/nginx combined log
format).

### Predefined formats

| `SM_LOG_FORMAT` | Format | Description |
|---|---|---|
| `combined` *(default)* | `IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"` | Apache/nginx combined log format |
| `combined_vhost` | `HOST:PORT IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"` | nginx with a `$host:$server_port` prefix |
| `common` | `IP - - [ts] "METHOD URL PROTO" STATUS SIZE` | common log format (no referrer/UA) |
| `custom` | arbitrary | custom regex + timestamp format |
| `json_ecs` | structured JSON (one line per request) | ECS-like schema, no regex — see below |

### Usage

```bash
# combined_vhost (nginx with a vhost prefix)
SM_LOG_FORMAT=combined_vhost ./load_cube.sh /logs/access.log "Authority A" 1

# or for all sites:
SM_LOG_FORMAT=combined_vhost ./run_all.sh
```

### Custom format

For non-standard log formats, the regex and timestamp format can be freely
defined:

```bash
# Example: ISO 8601 timestamp instead of the CLF format
export SM_LOG_FORMAT=custom
export SM_LOG_REGEX_CUSTOM='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
export SM_TS_FORMAT_CUSTOM='%Y-%m-%dT%H:%M:%S%z'
./load_cube.sh /logs/access.log "Site" 1
```

**Important:** the regex must produce exactly **8 capture groups** in this
order: `(ip)(tsraw)(method)(url)(status)(size)(referrer)(ua)`. If fields
are missing (e.g. for the common format), use empty groups `()`.

The `tsformat` value is a `strptime` format (DuckDB syntax). Common
formats:

| Timestamp example | `SM_TS_FORMAT_CUSTOM` |
|---|---|
| `10/Jan/2026:10:00:00 +0000` (CLF, default) | `%d/%b/%Y:%H:%M:%S %z` |
| `2026-01-10T10:00:00+00:00` (ISO 8601) | `%Y-%m-%dT%H:%M:%S%z` |
| `2026-01-10 10:00:00` (no TZ, treated as UTC) | `%Y-%m-%d %H:%M:%S` |

### JSON format (`json_ecs`)

For structured JSON logs (one line per request, e.g. nginx `log_format ...
escape=json`) instead of regex parsing. Field extraction lives in
`log_formats/json_ecs.sql` (via `json_extract_string`, no regex, no
`read_ndjson` auto-typing) and expects this schema (excerpt):

```json
{"@timestamp":"2026-07-01T10:00:00+00:00",
 "client":{"ip":"203.0.113.5"},
 "http":{"request":{"method":"GET"},
         "response":{"status_code":"200","bytes":"512"}},
 "app":{"url_path":"/current-notices","req":{"referer":"-"}},
 "user_agent":{"original":"Mozilla/5.0 ..."}}
```

**Avoiding key collisions:** if the nginx config has an app-level field
group (URL/referrer/cookies etc.) in addition to the protocol-level
`"http"` (lowercase: version/request/response/tls), that key must not be
named `"HTTP"` (differing only in case) — DuckDB's JSON reader resolves
column names case-insensitively and otherwise renames internally
(`HTTP_1`, undocumented behavior). `log_formats/json_ecs.sql` expects
`"app"` as the top-level key for these fields.

```bash
CUBE_DSN="..." SM_LOG_FORMAT=json_ecs ./load_cube.sh /logs/access.json "Site" 1
# or via Loki (see the README): SM_LOG_FORMAT=json_ecs ./fetch_loki_logs.sh ...
```

A different JSON schema: adjust `log_formats/json_ecs.sql` directly (the
`json_extract_string(line, '$.path...')` calls for the 8 target fields
ip/tsraw/method/url/status/size/referrer/ua).

### Setting the env variable

Pass it as an environment variable in the scheduler/container:
```bash
-e SM_LOG_FORMAT=combined_vhost      # docker run / k8s env
```

---

## 8. Incremental import & offset tracking

`load_cube.sh` only imports **new bytes** since the last known offset:

- **State file** per site/log in `$STATE_DIR/<hash>.offset`: contains the
  byte offset and inode number.
- **Log rotation**: detected via inode comparison. After rotation, the
  import starts at byte 0 of the new file.
- **Idempotency**: on import, the date range of the new data is first
  deleted from the cube DB (`DELETE WHERE datum BETWEEN ...`), then the new
  rows are inserted. Repeated import of the same bytes is safe.
- **Day-boundary cut** (`day_cut.sql`): lines from the **still-running day
  (UTC)** are held back — the offset stays before the first line of that
  day, and the following run then imports the day in full. Without this
  cut, the range `DELETE` on the following run would discard the already
  imported early hours of that day (data loss at the day boundary).
  Consequence: **a day's data only appears in the dashboard once that day
  is complete** (a nightly run at 02:00 shows the complete previous day).
  Multiple runs per day are safe as a result. `SM_COMPLETE_DAYS=0` disables
  the cut (only useful for backfilling completed periods or for tests);
  `SM_CUTOFF_DATE=YYYY-MM-DD` overrides the cutoff date.
- **The offset is only set after a successful import** — on failure, the
  next run re-imports the same range.
- **Empty-batch guard**: if the new range contains 0 valid lines, no
  `INSERT` runs and the offset is left unchanged.
- **Limitation**: sessions spanning midnight (UTC) are split at the day
  boundary (day-based aggregation model).

---

## 9. Scheduling (disposable container)

Operating model: an external scheduler (Kubernetes CronJob, Docker/Compose
scheduler, or host cron) briefly starts the ingestion container at night;
it imports all sites (`run_all.sh`) and exits. **No systemd inside the
container.** Details + examples (Docker `run`, k8s CronJob, required state
volume, DSN secret, alerting) in
[`scheduling/README_scheduling.md`](../ingestion/scheduling/README_scheduling.md).

```cron
# Host-cron alternative (one line, starts the container)
15 2 * * * docker run --rm -v sightmetrics_state:/state -v /var/log/access:/logs:ro \
  -e STATE_DIR=/state -e PARALLEL=auto -e CUBE_DSN_FILE=/run/secrets/cube_dsn \
  sightmetrics-ingestion run_all.sh >> /var/log/sightmetrics/cron.log 2>&1
```

**Required:** put `STATE_DIR` on a **persistent volume** — otherwise every
run does a full re-import.
**Alerting:** the scheduler evaluates the exit code; `run_all.sh`
additionally calls `notify.sh` inline on failure (see §12). Purge/backup/
rotation run as separate, less frequent scheduled jobs (§11, §6).

---

## 10. Parallelization & concurrency

`run_all.sh` supports parallel single-site imports via the env variable
`PARALLEL`:

```bash
PARALLEL=4 ./run_all.sh    # 4 concurrent site imports
```

`PARALLEL=auto` detects the core count automatically (`nproc`).

**Rule of thumb**: `PARALLEL` = number of CPU cores, at most as many as
keep `MaxRSS × PARALLEL < available RAM`. Read per-import MaxRSS from the
benchmark log (`state/metrics.log`). For a nightly run with fewer sites,
the default is fine; fine-tuning DuckDB's thread count isn't needed.

**Concurrency protection** (two levels):
- `run_all.sh` acquires a **flock lock** (`state/run_all.lock`) on start;
  an overlapping run exits immediately with exit 0.
- `load_cube.sh` additionally acquires a **per-site lock**
  (`state/site_<id>.lock`) — the same site's import can never overlap
  (protects offset/meta consistency).

### High availability (HA)

Not required for the intended operating model (one instance, one nightly
run). The **cube DB lives in your MariaDB** and shares its HA/backup
regime. The ingestion is just a DB client; if a nightly run is missed, the
next run catches up incrementally (or does a one-off full import,
idempotent via DELETE+INSERT per date range).

---

## 11. Retention & purging

`purge_cube.sh` deletes all rows from `cube`, `daily`, and `meta` whose
date is older than `RETENTION_MONTHS` months.

```bash
# Dry run: shows how many rows would be deleted
CUBE_DSN="..." RETENTION_MONTHS=12 PURGE_DRY_RUN=1 ./purge_cube.sh

# Actual deletion
CUBE_DSN="..." RETENTION_MONTHS=12 ./purge_cube.sh
```

Set `RETENTION_MONTHS` as an env variable in the purge job (default: 12
months). The purge run is idempotent and can be repeated at any time.
Recommendation: run purge as its own, infrequent scheduled job (e.g.
monthly), not as part of the nightly import.

**Rollback**: see [§17 Rollback](#17-rollback).

### TYPO3 side: cleaning up the `cache_sight_metrics` table

Besides the cube DB, there's a second growing dataset — on the **TYPO3
DB** (not the cube DB): the extension caches its read queries short-lived
(60s TTL) in the `cache_sight_metrics` table. TYPO3's database cache
backend does **not** delete expired entries on its own; without cleanup,
the table grows unbounded in operation (the cache keys are
high-cardinality: every combination of time range, dimension, and
drill-down expansion creates its own entry).

```bash
# Option 1: TYPO3 scheduler task "Caching framework garbage collection"
#           (if EXT:scheduler is in use), select the "sight_metrics" cache, e.g. daily.

# Option 2: daily cron directly on the TYPO3 DB (not the cube DB!)
mysql -h <typo3-db-host> -u <user> -p <typo3-db> \
  -e "DELETE FROM cache_sight_metrics WHERE expires < UNIX_TIMESTAMP();"
```

Details and background: extension handbook, section "Known limitations:
scaling & caching".

### Backup as a rollback point (before purging)

`backup_cube.sh` creates a `mysqldump` of the cube tables with rotation.
Recommendation: run it **immediately before** `purge_cube.sh` in the purge
job (back up first, then delete):

```bash
BACKUP_DIR=/state/backups ./backup_cube.sh && RETENTION_MONTHS=12 ./purge_cube.sh
```

> If the cube lives in **your** already-backed-up MariaDB, this is only the
> targeted rollback point immediately before deletion — the regular DB
> backup covers the rest.

```bash
# Manual backup (a read-only user like report_ro is enough for dumping)
CUBE_DSN="..." BACKUP_DIR=/var/backups/sightmetrics ./backup_cube.sh

# Dry run (shows target/config, writes nothing)
CUBE_DSN="..." BACKUP_DRY_RUN=1 ./backup_cube.sh
```

**Configuration (all via env, e.g. in `/etc/sightmetrics/backup.env`):**

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_ENABLED` | `1` | backup on/off (`0` = clean no-op) |
| `BACKUP_DIR` | `../backups` | target directory |
| `BACKUP_RETENTION` | `14` | number of dumps to keep (`0` = never delete) |
| `BACKUP_TABLES` | `meta daily cube` | tables to back up (empty = whole DB) |
| `BACKUP_COMPRESS` | `gzip` | `gzip` \| `zstd` \| `none` |
| `BACKUP_PREFIX` | `cube` | filename prefix |
| `BACKUP_DSN` / `BACKUP_DSN_FILE` | (falls back to `CUBE_DSN`) | dedicated backup credentials |
| `MYSQLDUMP` / `BACKUP_EXTRA_ARGS` | `mysqldump` / – | binary / extra arguments |

Restoring: see [§17 Rollback](#17-rollback) (unpack and load the dump).

---

## 12. Monitoring & alerting

### Prometheus (node_exporter textfile collector)

Every successful import atomically writes `.prom` files into `STATE_DIR`
(`sightmetrics_site_<id>.prom` per site, `sightmetrics_run.prom` per
`run_all.sh` run): timestamp of the last success, duration/CPU, bytes
processed, offset, and OK/FAIL counters. Collect via:

```bash
node_exporter --collector.textfile.directory=/path/to/state
```

Typical alert: `time() - sightmetrics_import_last_success_timestamp_seconds
> 100000` (no successful import in >27h). In Kubernetes, STATE_DIR lives on
the PVC — either use a node_exporter sidecar with the same mount, or copy
the files to the host's textfile directory via cron.

In the disposable-container model, monitoring comes from two sources:

**1. Import failures (immediate):** the scheduler evaluates the **exit
code** of `run_all.sh` (≠0 = at least one site failed → CronJob
`backoffLimit` / cron `MAILTO`). `run_all.sh` also calls `notify.sh`
**inline** on failure (email/webhook), if a channel is configured:

| Variable | Default | Meaning |
|---|---|---|
| `ALERT_EMAIL` | – | recipients (comma-separated); empty = no email |
| `ALERT_MAIL_FROM` | `sightmetrics@<host>` | sender |
| `ALERT_WEBHOOK` | – | webhook URL; empty = no webhook |
| `ALERT_WEBHOOK_FORMAT` | `slack` | `slack` \| `teams` \| `json` |
| `ALERT_MIN_LEVEL` | `WARN` | minimum level that gets sent (`OK`/`WARN`/`CRIT`) |
| `ALERT_PREFIX` | `[SightMetrics]` | subject/text prefix |

```bash
# Test an alert channel (without a real incident):
ALERT_EMAIL=ops@example.org ./notify.sh CRIT "Test alert"
ALERT_WEBHOOK=https://hooks.slack.com/... ./notify.sh WARN "Test alert"
```

**1b. Heartbeat / a missing run:** `notify.sh` only alerts on an *active*
failure within a run — it notices nothing if the scheduler never starts
the run at all (broken cron/CronJob, container crashes before starting,
…). For that, an optional **healthcheck ping** (e.g.
[healthchecks.io](https://healthchecks.io/) or self-hosted) in both
`run_all.sh` **and** `fetch_loki_logs.sh`: a start, success, and failure
ping (with a log excerpt as the body). If the ping stops arriving,
healthchecks.io alerts on its own.

```bash
export HEALTHCHECK_URL="https://hc-ping.com/<uuid>"   # or HEALTHCHECK_URL_FILE
```

Empty/unset = disabled (no-op), ping failures don't abort the import (only
a warning on stderr). See `ingestion/lib_healthcheck.sh`.

**2. Freshness (did the import even run?):** check from the
**continuously running** TYPO3 instance — `sightmetrics:health` checks the
GUI's read path (cube reachable + freshness of `meta.bis` per site):

```bash
vendor/bin/typo3 sightmetrics:health --warn-hours=26 --crit-hours=50        # text
vendor/bin/typo3 sightmetrics:health --json                                  # for agents
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
```

Schedule via the TYPO3 scheduler or external monitoring (uptime check).

**Also keep an eye on:** the MariaDB connection (your own DB monitoring),
cube DB growth (table size), the last backup (`state/backup.last`),
`state/metrics.log` (runtimes/bytes per run).

---

## 13. Log rotation

In the disposable-container model, the scripts write to **stdout/stderr**
— log retention and rotation are handled by the orchestrator (Docker/k8s
logging, journald for host cron). Persistent run logs under `LOG_DIR` (if
set) can be covered by the log volume's normal host log rotation if
needed. Detection of **rotated web server logs** (the source) happens
automatically via inode comparison in offset tracking (§8).

---

## 14. Multi-site (one instance, multiple sites)

Use case: **one** TYPO3 instance with multiple sites in **one** namespace,
cube in **your** MariaDB. All sites live in one `analytics` DB,
distinguished by `site_id`.

`sites.conf` lists all sites; `run_all.sh` imports them (sequentially or
with `PARALLEL`). Each site has its own `state/<hash>.offset` file. In
TYPO3, `sightmetrics_site_id` in the respective site config maps the
TYPO3 site to the cube `site_id` (see extension handbook §5); the GUI
shows the site selector accordingly.

> Tenant/DB isolation via separate databases is **not needed** for this
> single-instance setup and was deliberately not built in.

---

## 15. Error runbook & recovery

### Import fails (exit ≠ 0)

```bash
# 1. Check the last run (the scheduler's container logs)
docker logs <container>            # or kubectl logs job/<name>
# or the persistent run log (if LOG_DIR is set):
tail -200 "$LOG_DIR"/run_<DATE>.log

# 2. Re-import manually
CUBE_DSN="..." ./load_cube.sh /logs/site1/access.log "Authority A" 1

# 3. If MariaDB was unreachable: simply repeat the import.
#    Idempotency (DELETE + INSERT) ensures consistency.
```

### Offset state corrupted / wrong

```bash
# Delete the state file for a site → the next import starts at byte 0
rm /var/lib/sightmetrics/state/<hash>.offset

# Then: delete this site's data for the affected period from the cube DB
mysql -u cube_rw -p analytics \
  -e "DELETE FROM cube  WHERE site_id = 1 AND datum >= '2026-01-01';
      DELETE FROM daily WHERE site_id = 1 AND datum >= '2026-01-01';
      DELETE FROM meta  WHERE site_id = 1 AND datum >= '2026-01-01';"

# Restart the import
CUBE_DSN="..." ./load_cube.sh /logs/site1/access.log "Authority A" 1
```

### Cube DB full / too large

```bash
# Check table sizes
mysql -u report_ro -p analytics -e "
  SELECT table_name,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 1) AS 'MB'
  FROM information_schema.TABLES
  WHERE table_schema = 'analytics'
  ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;"

# Shorten retention (e.g. to 6 months) and trigger a purge
CUBE_DSN="..." RETENTION_MONTHS=6 ./purge_cube.sh
```

### Duplicate import (same time range)

Safe: `cube_to_mysql.sql` deletes the affected date range before the
`INSERT` (`DELETE WHERE datum BETWEEN ...`). The result is identical to a
single import.

---

## 16. Privacy & BSI notes

### IP addresses

- Raw IP addresses are **not stored in the cube DB**.
- For GeoIP and unique-visitor counting, a **daily-salted hash** is
  computed: `MD5(ip + daily_salt)` — resistant to reversal and consistent
  within a single day.
- `daily_salt` is re-randomized every day (DuckDB, at import time).
- For stricter requirements: truncate the IP before import (zero out the
  last octet).

### PII in URLs and referrers

- URLs are stored unmodified. Filter out or mask query parameters
  containing PII (tokens, names, emails) before import:
  ```bash
  # Example: remove the 'token' and 'email' query parameters
  sed -E 's/[?&](token|email)=[^& "]*/\1=REMOVED/g' access.log | ./load_cube.sh - "Site" 1
  ```

### Transmitting logs

- Logs must only be transmitted encrypted (TLS/SSH/SFTP).
- Least privilege: the import user on the web server should only have read
  access, never write.
- Raw-log retention periods: clarify with your data protection officer;
  the cube DB is configured via `RETENTION_MONTHS`.

### BSI-Grundschutz relevance

- Keep `cube_rw` and `report_ro` strictly separate (no write access for
  the extension).
- Encrypt DB connections (MariaDB: `ssl=true` in the DSN, for an external
  host).
- Never put secrets in scripts or source control; always read from an env
  variable or secret file.
- Enable audit logs on the import host and MariaDB.

---

## 17. Rollback

To undo a faulty import:

```bash
# Option A: delete a specific time range (recommended)
mysql -u cube_rw -p analytics -e "
  DELETE FROM cube  WHERE site_id = <ID> AND datum BETWEEN '<FROM>' AND '<TO>';
  DELETE FROM daily WHERE site_id = <ID> AND datum BETWEEN '<FROM>' AND '<TO>';
  DELETE FROM meta  WHERE site_id = <ID> AND datum >= '<FROM>';"
# meta is recomputed from the full daily table on the next import.

# Then: reset the state offset and re-import
rm /var/lib/sightmetrics/state/<hash>.offset
CUBE_DSN="..." ./load_cube.sh /logs/site<ID>/access.log "Site name" <ID>

# Option B: restore a full backup (if available)
mysql -u root -p analytics < backup_analytics_YYYYMMDD.sql
```

**Recommendation**: create daily MariaDB backups (`mysqldump analytics`)
before the import window. `cube_to_mysql.sql` is idempotent; a repeated
import correctly overwrites faulty data.

---

## 17a. Updating from version to version

Two independently versioned packages (A = ingestion, B = TYPO3 extension)
connected only via the DB contract (`docs/SCHEMA.md`). This separation
makes updates robust by design: **additive** changes (new columns/tables,
e.g. the query indexes or the Top-N precompute) require no particular
order — each package can be updated on its own, the other keeps running
unchanged against the old data. Only **breaking** changes (a column
renamed/removed, semantics changed — identifiable by a new
`sm_schema_version`, see `docs/SCHEMA.md` "Rules for future changes")
require a specific order, see below.

### Updating the ingestion (package A)

1. Roll out the new state of `ingestion/` (git pull, image update, etc.).
2. Nothing further needed for additive changes: `sink_mysql.sql` creates
   new tables/columns/indexes idempotently on the next import (`CREATE
   TABLE/INDEX IF NOT EXISTS`).
3. Optional, only for very large existing cubes: run the corresponding
   `ingestion/migrations/*.sql` separately at a maintenance window, instead
   of letting the first online DDL run during the nightly import window
   (see the table below).

### Updating the extension (package B)

```bash
composer update sightmetrics/sight-metrics
vendor/bin/typo3 cache:flush
```

The extension checks the schema version exactly on every module load and
in `sightmetrics:health` (`CubeRepository::SCHEMA_VERSION` vs.
`meta.schema_version`). If the ingestion isn't on the matching version yet,
the module aborts with a clear error message (no crash, no wrong numbers)
and points to the required migration — so it's harmless to update the
extension before the ingestion, even across a major version jump.
Additive ingestion features (e.g. the `topn` table) are picked up as soon
as they exist; until then, the extension automatically uses its previous
(slower, but correct) query path.

### Migrations at a glance

| File | Required? | When needed |
|---|---|---|
| `ingestion/migrations/v1_to_v2.sql` | **Yes**, for existing v1 data | Breaking change (schema v2): CHR(31) keys → `parent` column. Without this migration, extension 2.x refuses to serve with an error. Alternative: re-import all logs. |
| `ingestion/migrations/v2_add_indexes.sql` | No (the sink creates the indexes automatically) | Only to run the first index creation (online DDL) on very large cubes at a controlled time outside the nightly import window. |
| `ingestion/migrations/v2_add_topn.sql` | No (the sink creates the table automatically) | Only to create the table/index ahead of time before the next import runs — purely cosmetic, no correctness risk if skipped (see `docs/topn-precompute-spec.md`). |

**Rule of thumb:** except for `v1_to_v2.sql`, the migration scripts here
are optional and idempotent — when in doubt, just wait for the next
regular import. A rollback (§17) works unchanged for all additive tables
too, since they're keyed by the same `site_id`.

### What actually happens to the data

**Additive migrations** (`v2_add_indexes.sql`, `v2_add_topn.sql`, and
whatever the sink creates automatically on an ongoing basis): plain
`CREATE TABLE/INDEX IF NOT EXISTS`. **No existing row is read, modified, or
deleted** — the new structure is purely additive. No downtime risk, no
backup needed, repeatable any number of times. The only side effect: the
first index creation on a very large existing `cube` is an online DDL that
briefly generates I/O load (hence the option to run it separately at a
maintenance window instead of during the nightly import window).

**`v1_to_v2.sql` (the only breaking migration so far)** does modify
existing rows, but **deletes none**. Specifically, line by line from the
script:

- `cube.parent` (new column) and `meta.tz`/`meta.schema_version` are added
  via `ALTER TABLE ADD COLUMN IF NOT EXISTS` — additive, no data affected.
- For drill-down dimensions (`referrer_name`, `referrer_url`,
  `browser_version`, `os_version`, `device_model`), the previous `dimkey`
  value `"<parent>\x1F<child>"` (CHR(31)-separated) is split into two
  columns: `parent = "<parent>"`, `dimkey = "<child>"`. Example: `dimkey =
  "Chrome\x1F125.0"` becomes `parent = "Chrome"`, `dimkey = "125.0"`. The
  row itself remains, only the content of two columns changes.
- `referrer_type` values are remapped from the old German display labels
  (`"Direkt"`, `"Suchmaschine"`, `"Soziale Medien"`, `"Website"`) to the
  neutral keys (`direct`, `search`, `social`, `website`) — same row, new
  value. Matching `referrer_name` parent values are updated identically.
- `meta.tz` is set to `'UTC'` for all existing rows (historically correct:
  v1 always bucketed in UTC, regardless of what `SM_TZ` says today). New
  days after the migration follow the currently configured timezone; old
  days remain as they were actually imported — nothing is recalculated
  retroactively.
- `meta.schema_version` is set to `2`.

Idempotent: the `UPDATE` conditions (`INSTR(dimkey, CHAR(31)) > 0` etc.)
only match rows not yet migrated from v1 — a second run changes nothing
further. **No data loss in any case**, but still: take a MariaDB backup
before the migration (§17), since these are `UPDATE`s against the live
table, there is no dry-run mode, and a failure during the run (e.g. a
dropped connection) could leave an inconsistent intermediate state — that's
exactly what the backup is for.

---

## 18. Important env variables

| Variable | Default | Description |
|---|---|---|
| `CUBE_DSN` | – | MariaDB DSN (required if `CUBE_DSN_FILE` isn't set) |
| `CUBE_DSN_FILE` | `/run/secrets/cube_dsn` | alternative: DSN from a file (k8s secrets) |
| `SM_LOG_FORMAT` | `combined` | log format: `combined`, `combined_vhost`, `common`, `custom`, `json_ecs` |
| `SM_LOG_REGEX_CUSTOM` | – | regex for `SM_LOG_FORMAT=custom` (8 capture groups) |
| `SM_TS_FORMAT_CUSTOM` | – | strptime format for `SM_LOG_FORMAT=custom` |
| `SM_GEO_SOURCE` | `native` | GeoIP source: `native`, `ip2location`, `dbip`, `maxmind` (see §3a) |
| `SM_GEO_PATH` | `geo/country-ipv4-num.csv` | path to the geo CSV (source it yourself, see §3a) |
| `SM_GEO_LOC_PATH` | `geo/GeoLite2-Country-Locations-en.csv` | `SM_GEO_SOURCE=maxmind` only: locations file |
| `SM_TABLE_CUBE` | `cube` | cube table name (for non-default table names) |
| `SM_TABLE_DAILY` | `daily` | daily table name |
| `SM_TABLE_META` | `meta` | meta table name |
| `SM_TABLE_TOPN` | `topn` | Top-N precompute table name (§17a, `docs/topn-precompute-spec.md`) |
| `RETENTION_MONTHS` | `12` | retention period for purge (positive integer) |
| `PURGE_DRY_RUN` | *(unset)* | set: only count, don't delete |
| `PARALLEL` | `1` | parallel import jobs (`xargs -P` in `run_all.sh`) |
| `STATE_DIR` | `../state/` | offset state + lock + metrics |
| `LOG_DIR` | `../logs/import-logs/` | import logs |
| `SITES_CONF` | `./sites.conf` | path to the site list |
| `ALERT_EMAIL` / `ALERT_WEBHOOK` | – | alert channels for `notify.sh` (inline in `run_all.sh`) |
| `HEALTHCHECK_URL` / `_FILE` | – | heartbeat ping (healthchecks.io or similar); empty = disabled (§12) |
| `LOKI_URL` / `LOKI_QUERY` | – | `fetch_loki_logs.sh`: Loki base URL + LogQL selector (required there) |
| `LOKI_NAMESPACE` | – | `fetch_loki_logs.sh`: convenience filter (label matcher) |
| `LOKI_ORG_ID` | – | `fetch_loki_logs.sh`: `X-Scope-OrgID` (Loki multi-tenant) |
| `LOKI_LIMIT` / `LOKI_LOOKBACK_HOURS` / `LOKI_SAFETY_SECONDS` | `5000` / `24` / `30` | `fetch_loki_logs.sh`: pagination/first-run/safety margin |
