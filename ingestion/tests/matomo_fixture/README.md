# Matomo import fixture (real, frozen)

These JSON files are real Reporting API responses from Matomo 5.12.0, not
hand-written — captured from a disposable Matomo instance and frozen here so
`ingestion/tests/matomo_pipeline_test.sql` doesn't need a live Matomo
instance to run.

## Provenance / how to regenerate

1. Bring up `ingestion/tests/matomo/docker-compose.yml`
   (`docker compose up -d`). Matomo's web installer isn't scriptable via a
   single command; complete it via the browser at `http://localhost:8092/`
   (database connection is pre-filled from the compose file's env vars) or
   by driving `index.php?module=Installation` through its steps
   (`systemCheck` → `databaseSetup` → `tablesCreation` → `setupSuperUser` →
   `firstWebsiteSetup` → `finished`) with an HTTP client.
2. Create the site with a real `main_url` (e.g. via `SitesManager.addSite`
   / `SitesManager.updateSite`) — without one, `Actions.getPageUrls` and
   related reports return `"Page URL not defined"` for every row instead of
   actual paths.
3. Create an API token, e.g.:
   ```bash
   curl "http://localhost:8092/index.php?module=API&method=UsersManager.createAppSpecificTokenAuth&format=json" \
     --data-urlencode "userLogin=<admin>" \
     --data-urlencode "description=fixture" \
     --data-urlencode "passwordConfirmation=<admin password>"
   ```
4. Import `seed.log` (in this directory) via Matomo's own log importer
   (bundled in the Matomo image at
   `/usr/src/matomo/misc/log-analytics/import_logs.py`, or download the
   same version from the
   [device-detector repository's log-analytics tool](https://matomo.org/log-analytics/)):
   ```bash
   python3 import_logs.py \
     --url=http://localhost:8092/ --token-auth=<token> --idsite=<id> \
     --recorders=1 --enable-http-errors seed.log
   ```
5. Force archiving: `console core:archive --force-all-websites --url=...`
6. Dry-run the importer to capture fresh JSON:
   ```bash
   ./matomo_import.sh --url http://localhost:8092 --matomo-idsite <id> \
     --site-id 999 --site-name Fixture --from 2026-06-01 --to 2026-06-01 \
     --json-dir /tmp/out --dry-run
   ```
7. Copy `/tmp/out/chunk_1/*.json` over the files in this directory.

`seed.log` is deliberately tiny (5 requests, 3 visitors, one search referrer,
one download) so every number in the JSON can be hand-verified and the
`checks(...)` table in `matomo_pipeline_test.sql` stays readable.
