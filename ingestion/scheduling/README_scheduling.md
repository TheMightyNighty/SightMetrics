# Scheduling & operations – SightMetrics ingestion

Operating model: **nightly disposable container.** An external scheduler
(Kubernetes CronJob, Docker/Compose scheduler, or host cron) starts the
container briefly, it imports all sites (`run_all.sh`), and exits again. No
**systemd** runs inside the container — scheduling, restart, and alerting on
exit code are the scheduler's job.

## Required: keep state persistent

`run_all.sh`/`load_cube.sh` remember the byte offset per site in
`STATE_DIR`. If this is **not** on a persistent volume, every run re-imports
the entire log. Always mount a volume:

```
STATE_DIR=/state   ->   volume/PVC at /state
```

## DSN as a runtime secret

Never bake it into the image. Inject it at runtime:

```bash
# File variant (recommended): CUBE_DSN_FILE points to a mounted secret
CUBE_DSN_FILE=/run/secrets/cube_dsn
# or directly
CUBE_DSN="host=db port=3306 user=cube_rw password=… database=analytics"
```

## Nightly import (examples)

```bash
# Docker (one-shot), state and log volume + secret + alert channel
docker run --rm \
  -v sightmetrics_state:/state \
  -v /var/log/access:/logs:ro \
  -e STATE_DIR=/state -e PARALLEL=auto \
  -e CUBE_DSN_FILE=/run/secrets/cube_dsn \
  -e ALERT_WEBHOOK="https://hooks.slack.com/…" \
  sightmetrics-ingestion run_all.sh
```

## Kubernetes (complete manifests)

Copy-paste-ready, "restricted" PSS-compliant manifests are in
[`k8s/`](k8s/):

| File | Content |
|---|---|
| `cronjob.yaml` | CronJob including `securityContext`, `resources`, all volumes (state PVC, log volume, sites.conf ConfigMap, DSN secret, geo volume, /tmp emptyDir) |
| `pvc-state.yaml` | Required PVC for the offset state |
| `secret-cube-dsn.example.yaml` | DSN secret (template) |
| `configmap-sites.example.yaml` | sites.conf as a ConfigMap (template) |

Key operational points:

- **Non-root & read-only**: the image runs as UID 10001 with
  `readOnlyRootFilesystem: true`; only `/state` (PVC) and `/tmp` (emptyDir)
  are writable. The DuckDB MySQL extension is baked into the image (no
  runtime download).
- **`concurrencyPolicy: Forbid`** complements the scripts' `flock` at the
  scheduler level. **NFS caveat:** `flock` is unreliable on NFS-based PVCs —
  use block storage (RWO) for `/state`.
- **Pin the image by digest**: `ghcr.io/<org>/sightmetrics-ingestion@sha256:…`
  — the digest comes from the CI workflow `.github/workflows/image.yml`
  (builds/pushes to GHCR on `v*` tags).
- **GeoIP dataset** is not in the image (license-restricted, runbook §3a):
  mount it as a volume and set `SM_GEO_PATH`.
- **Logs**: either mount as a read-only volume — or import entirely without
  a log volume via Loki (`fetch_loki_logs.sh`).

**Day boundary:** the import holds back lines from the still-running day
(UTC) and only imports a day once it's complete (runbook §8). A nightly run
therefore always shows the **complete previous day** — multiple runs per day
are safe as a result (no overwriting of partial days).

**Exit code:** `run_all.sh` exits ≠0 if at least one site fails → the
scheduler (CronJob/`backoffLimit`, cron MAILTO) reports this. `run_all.sh`
also calls `notify.sh` **inline** on failure (email/webhook) if
`ALERT_EMAIL`/`ALERT_WEBHOOK` are set (no-op otherwise). See runbook §12.

## Freshness monitoring (did the import even run?)

Check from the **continuously running** TYPO3 instance — not from the
disposable container:

```bash
vendor/bin/typo3 sightmetrics:health --warn-hours=26 --crit-hours=50 --json
# Exit 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
```

Schedule via the TYPO3 scheduler or external monitoring (e.g. an uptime
check).

## Retention/purge & backup (occasional)

No dedicated always-on service needed — run as a separate scheduled job
(e.g. monthly):

```bash
# Save a rollback point, then delete old data
BACKUP_DIR=/state/backups CUBE_DSN_FILE=/run/secrets/cube_dsn ./backup_cube.sh
RETENTION_MONTHS=12 CUBE_DSN_FILE=/run/secrets/cube_dsn ./purge_cube.sh
```

> Note: if the cube lives in **your** MariaDB, which is backed up anyway,
> `backup_cube.sh` is only needed as a targeted rollback point before the
> purge — the regular DB backup already covers the cube.

## Secret rotation (as needed, manual/orchestrated)

```bash
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env \
  ROTATE_ADMIN_USER=root ROTATE_ADMIN_PASSWORD_FILE=/run/secrets/mariadb_root \
  ./rotate_cube_secret.sh
```

See runbook §6 (secret rotation) and §10 (concurrency/parallelization).
