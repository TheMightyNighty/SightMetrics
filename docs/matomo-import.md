# Matomo Legacy-Data Import

One-off import of historical analytics data from an existing **Matomo**
installation into the SightMetrics cube — per customer site, typically once
during onboarding ("customers want to see their old data").

The import uses **Matomo's Reporting API** (JSON), not the raw logs. This
means it still works even if Matomo's raw tracking data has long since been
deleted by a retention rule — the aggregated report archives remain, and
that's exactly what the API returns.

---

## Supported Matomo version

Tested and supported is exclusively **the current Matomo release** (as of
this writing: **5.12.0**). Compatibility with older Matomo/Piwik versions is
deliberately **not** attempted or tested — the customer's Matomo instance
should be brought up to date within Matomo itself (Matomo's own,
well-documented update path) before the legacy-data import, rather than us
maintaining version fallbacks here.

**Why this matters especially for `browser`/`os`/`device`:** these three
dimensions use the API methods `DevicesDetection.getBrowsers`,
`DevicesDetection.getOsFamilies`, `DevicesDetection.getType`. The
`DevicesDetection` plugin replaced the older `UserSettings.getBrowser`/`getOS`
endpoints in older Matomo/Piwik versions — on a non-updated legacy
installation these calls could fail. That wouldn't abort the import (see
"Error handling" below: individual failing reports degrade to `{}` with a
`WARN`), but the three dimensions would end up **silently empty** for the
customer if nobody checks the log — one more reason to update first instead
of running it and hoping for the best.

---

## Verification

`ingestion/tests/matomo/docker-compose.yml` sets up a disposable Matomo
instance for verifying the importer against a real Matomo release; see
`ingestion/tests/matomo_fixture/README.md` for the exact steps
(installation, seeding, capturing a fixture), to be re-run whenever the
supported Matomo version is bumped. The frozen, real-output fixture from
such a run is checked in under `ingestion/tests/matomo_fixture/` and
covered by two automated tests: `ingestion/tests/matomo_pipeline_test.sql`
(parsing/mapping, DuckDB-only) and
`CubeContractTest::testMatomoContractFixtureRoundTrip` (full round trip
through the real cube DB and `CubeRepository`).

Cross-checking the same input against both the log path and the Matomo path
shows `daily.visits`/`daily.pageviews`/`daily.bounces` matching exactly;
`daily.uniques` differs by a small margin (the two systems deduplicate
unique visitors slightly differently); `referrer_type` can differ by a
handful of visits for ambiguous referrer domains (the two systems maintain
independent referrer-classification tables).

---

## Relationship to the daily log import

Both paths run **in parallel** and write into the same cube:

| | Compute script | Driver | Source |
|---|---|---|---|
| **Daily operation** | `cube_to_mysql.sql` + `transform.sql` | `load_cube.sh` / `run_all.sh` | Web server logs |
| **Legacy data (one-off)** | `matomo_to_cube.sql` | `matomo_import.sh` | Matomo Reporting API |

Both produce the same TEMP tables `daily_rows`/`cube_rows` and use the same
MariaDB sink **`sink_mysql.sql`**. The sink always only replaces the
**date range of the current batch** (range-`DELETE` per `site_id`). As long
as the time ranges don't overlap, the two paths don't interfere:

```
   Past                                Today / ongoing
   |-------- Matomo import ---------|---- daily log import ---->
   2019 ................ yesterday      since go-live
```

In practice: run the Matomo import up to the day **before** the log import
starts. If days overlap, the most recently written run wins for those days —
the two sources are not additive for the same day, they replace each other.

---

## Prerequisites

1. **Matomo access:** URL of the installation, the `idSite` of the source
   site, and an **auth token** with **view rights** on that site.

   > Note: Matomo authenticates the API exclusively via `token_auth`,
   > **not** via username/password (the password-to-token endpoint was
   > removed for security reasons). Create a token in Matomo under
   > **Administration → Personal → Security → Auth tokens**. A plain view
   > token is enough.

2. **Cube DB:** the same `CUBE_DSN` as for the log import (DuckDB MySQL DSN).

3. The DuckDB binary at `ingestion/bin/duckdb` (as for the log import).

---

## Usage

```bash
cd ingestion

export MATOMO_TOKEN="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # or MATOMO_TOKEN_FILE
export CUBE_DSN="host=... port=3306 user=cube_rw password=... database=analytics"

./matomo_import.sh \
  --url https://matomo.example.org \
  --matomo-idsite 7 \
  --site-id 3 \
  --site-name "Sample Authority" \
  --from 2020-01-01 \
  --to   2024-12-31
```

| Parameter | Meaning |
|---|---|
| `--url` | Base URL of the Matomo installation |
| `--matomo-idsite` | `idSite` **in Matomo** (source) |
| `--site-id` | `site_id` **in SightMetrics** (target in the cube) |
| `--site-name` | Display name (goes into the `meta` table) |
| `--from` / `--to` | Time range `YYYY-MM-DD` (inclusive) |
| `--json-dir DIR` | keep the downloaded JSON files (otherwise temporary + auto-cleanup) |
| `--dry-run` | only load JSON, **don't** write to the DB (no `CUBE_DSN` needed) |

### Secrets as a file (Docker secrets pattern)

```bash
MATOMO_TOKEN_FILE=/run/secrets/matomo_token \
CUBE_DSN_FILE=/run/secrets/cube_dsn \
./matomo_import.sh --url ... --matomo-idsite 7 --site-id 3 --site-name "…" \
                   --from 2020-01-01 --to 2024-12-31
```

### Dry run (check the mapping, keep the JSON)

```bash
./matomo_import.sh --url https://matomo.example.org --matomo-idsite 7 \
  --site-id 3 --site-name "Test" --from 2024-12-01 --to 2024-12-31 \
  --json-dir /tmp/matomo_check --dry-run
```

Stores the raw responses under `/tmp/matomo_check/chunk_N/<dim>.json`.

---

## What gets imported

`VisitsSummary.get` → `daily` (visits, pageviews, uniques, bounces).
One report per dimension → `cube` (`pv` ← pageviews, `v` ← visits):

| Cube `dim` | Matomo API method |
|---|---|
| `url` | `Actions.getPageUrls` (`flat=1`) |
| `entry` / `exit` | `Actions.getEntryPageUrls` / `getExitPageUrls` |
| `download` | `Actions.getDownloads` |
| `country` | `UserCountry.getCountry` (via the ISO-2 `code` field, not the `label` display name) |
| `browser` | `DevicesDetection.getBrowsers` |
| `os` | `DevicesDetection.getOsFamilies` |
| `device` | `DevicesDetection.getType` |
| `referrer_type` | `Referrers.getReferrerType` |
| `keyword` | `Referrers.getKeywords` |
| `hour` | `VisitTime.getVisitInformationPerLocalTime` |

### Known gaps (v1)

* **`status`, `method`, `bytes`/bandwidth:** Matomo doesn't track these →
  stay empty for historical days (`bytes`=0). These are pure log-derived
  metrics.
* **Composite sub-dimensions** `browser_version`, `os_version`,
  `device_model`, `referrer_name`, `referrer_url`: the cube stores their
  `dimkey` as `parent\x1fchild`; Matomo's flat reports don't reliably provide
  the parent prefix. These drill-down views stay empty for imported
  historical periods; the parent dimensions (browser, os, device,
  referrer_type) are present.
* **Label language:** `referrer_type` carries Matomo's own labels (e.g.
  "Search Engines"); these are mapped to the contract's neutral keys
  (`direct`/`search`/`social`/`website`) in `matomo_to_cube.sql`, so this is
  not actually a display-language gap — just noting the source labels differ
  from the log path's, in case that mapping ever needs extending for a
  Matomo referrer type not yet covered.

---

## Scaling (sites with millions of hits/day)

The import pulls **aggregates**, not raw rows — a day with 2M hits results in
only as many cube rows as there are distinct dimension values. That keeps the
approach manageable even over 4–5 years.

* **Monthly chunking:** one API call per report per month (`period=day` +
  range returns the days individually bucketed in one call). 5 years ≈ 60
  chunks × 12 reports.
* **`filter_limit`:** high-cardinality dimensions (`url`, `entry`, `exit`,
  `keyword`) are capped to **top-N per day** (`FILTER_LIMIT_HIGH`, default
  `1000`); low-cardinality dims (country/browser/os/device/referrer_type/hour)
  are pulled in full (`filter_limit=-1`). Adjust via:

  ```bash
  FILTER_LIMIT_HIGH=500 ./matomo_import.sh ...
  ```

* **Archiving:** if a call hits a historical period Matomo hasn't archived
  yet, Matomo archives it on the fly — noticeable on the Matomo server for
  large sites. Historical periods are usually archived already; if not, run
  `./console core:archive` on the customer's Matomo beforehand.

---

## Repeatability

The import is **idempotent**: re-running it for the same time range replaces
the affected days (range-`DELETE` in the sink, then `INSERT`) — numbers are
**not duplicated**. An aborted run can be safely repeated.

The Matomo path deletes the **full chunk range** (`range_from`/`range_to` =
`--from`/`--to` per month), not just the days that actually returned data.
That way, days that are (now) empty in Matomo get cleanly cleared instead of
being left with stale values.

> Sources are **replacing, not additive:** if a Matomo run overwrites days
> the log import already wrote, the Matomo numbers win for those days (no
> summing). That's why Matomo should only run up to the day before the log
> import starts.

---

## Error handling

* Individual failing reports (HTTP errors or `"result":"error"`) degrade to
  `{}` and are logged with `WARN` — the import continues, the affected
  dimension stays empty for that chunk. `--json-dir` lets you inspect the raw
  responses afterwards.
* `--dry-run` to check access/token/mapping without DB write access.
  **Recommended before every real customer import**, in particular to catch
  the `DevicesDetection` pitfall (see "Supported Matomo version" above)
  early: check `--json-dir` to see whether `browser.json`/`os.json`/`device.json`
  contain real data or just `{}` before importing the full range.
