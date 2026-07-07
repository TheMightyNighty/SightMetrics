# Scheduling & Betrieb – SightMetrics Ingestion

Betriebsmodell: **nächtlicher Wegwerf-Container.** Ein externer Scheduler
(Kubernetes-CronJob, Docker-/Compose-Scheduler oder Host-Cron) startet den
Container kurz, er importiert alle Sites (`run_all.sh`) und beendet sich wieder.
Es läuft **kein systemd** im Container – Planung, Neustart und Alarm auf Exit-Code
übernimmt der Scheduler.

## Pflicht: State persistent halten

`run_all.sh`/`load_cube.sh` merken sich pro Site den Byte-Offset im `STATE_DIR`.
Ist dieser **nicht** auf einem persistenten Volume, importiert jeder Lauf das
komplette Log neu. Also immer ein Volume mounten:

```
STATE_DIR=/state   ->   Volume/PVC auf /state
```

## DSN als Laufzeit-Secret

Niemals in das Image backen. Zur Laufzeit injizieren:

```bash
# Datei-Variante (empfohlen): CUBE_DSN_FILE zeigt auf ein gemountetes Secret
CUBE_DSN_FILE=/run/secrets/cube_dsn
# oder direkt
CUBE_DSN="host=db port=3306 user=cube_rw password=… database=analytics"
```

## Nächtlicher Import (Beispiele)

```bash
# Docker (one-shot), State- und Log-Volume + Secret + Alarm-Kanal
docker run --rm \
  -v sightmetrics_state:/state \
  -v /var/log/access:/logs:ro \
  -e STATE_DIR=/state -e PARALLEL=auto \
  -e CUBE_DSN_FILE=/run/secrets/cube_dsn \
  -e ALERT_WEBHOOK="https://hooks.slack.com/…" \
  sightmetrics-ingestion run_all.sh
```

## Kubernetes (vollständige Manifeste)

Copy-paste-fähige, „restricted"-PSS-konforme Manifeste liegen in
[`k8s/`](k8s/):

| Datei | Inhalt |
|---|---|
| `cronjob.yaml` | CronJob inkl. `securityContext`, `resources`, allen Volumes (State-PVC, Log-Volume, sites.conf-ConfigMap, DSN-Secret, Geo-Volume, /tmp-emptyDir) |
| `pvc-state.yaml` | Pflicht-PVC für den Offset-State |
| `secret-cube-dsn.example.yaml` | DSN-Secret (Vorlage) |
| `configmap-sites.example.yaml` | sites.conf als ConfigMap (Vorlage) |

Wichtige Betriebs-Punkte:

- **Non-root & read-only**: das Image läuft als UID 10001 mit
  `readOnlyRootFilesystem: true`; beschreibbar sind nur `/state` (PVC) und
  `/tmp` (emptyDir). Die DuckDB-MySQL-Extension ist ins Image gebacken
  (kein Laufzeit-Download).
- **`concurrencyPolicy: Forbid`** ergänzt das `flock` der Skripte auf
  Scheduler-Ebene. **Achtung NFS:** `flock` ist auf NFS-basierten PVCs
  unzuverlässig – für `/state` Block-Storage (RWO) verwenden.
- **Image per Digest pinnen**: `ghcr.io/<org>/sightmetrics-ingestion@sha256:…`
  – den Digest liefert der CI-Workflow `.github/workflows/image.yml`
  (baut/pusht bei `v*`-Tags nach GHCR).
- **GeoIP-Datensatz** ist nicht im Image (lizenzpflichtig, Runbook §3a):
  als Volume mounten und `SM_GEO_PATH` setzen.
- **Logs**: entweder als read-only Volume mounten – oder ganz ohne Log-Volume
  über Loki importieren (`fetch_loki_logs.sh`).

**Tagesgrenze:** Der Import hält Zeilen des noch laufenden Tages (UTC) zurück
und importiert einen Tag erst, wenn er abgeschlossen ist (Runbook §8). Beim
nächtlichen Lauf erscheint also jeweils der **komplette Vortag** – mehrere
Läufe pro Tag sind dadurch ebenfalls sicher (kein Überschreiben von Teil-Tagen).

**Exit-Code:** `run_all.sh` endet mit ≠0, wenn mind. eine Site fehlschlägt →
der Scheduler (CronJob/`backoffLimit`, Cron-MAILTO) meldet das. Zusätzlich ruft
`run_all.sh` bei Fehlern **inline `notify.sh`** auf (E-Mail/Webhook), sofern
`ALERT_EMAIL`/`ALERT_WEBHOOK` gesetzt sind (sonst No-op). Siehe Runbook §12.

## Freshness-Monitoring (lief der Import überhaupt?)

Aus der **dauerhaft laufenden** TYPO3-Instanz prüfen – nicht aus dem Wegwerf-Container:

```bash
vendor/bin/typo3 sightmetrics:health --warn-hours=26 --crit-hours=50 --json
# Exit 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
```

Per TYPO3-Scheduler oder externem Monitoring (z. B. Uptime-Check) takten.

## Retention/Purge & Backup (gelegentlich)

Kein eigener Daueranbieter nötig – als separater Scheduler-Job (z. B. monatlich):

```bash
# Rollback-Punkt sichern, dann alte Daten löschen
BACKUP_DIR=/state/backups CUBE_DSN_FILE=/run/secrets/cube_dsn ./backup_cube.sh
RETENTION_MONTHS=12 CUBE_DSN_FILE=/run/secrets/cube_dsn ./purge_cube.sh
```

> Hinweis: Liegt der Cube in **eurer** MariaDB, die ohnehin gesichert wird, ist
> `backup_cube.sh` nur als gezielter Rollback-Punkt vor dem Purge nötig – das
> reguläre DB-Backup deckt den Cube bereits ab.

## Secrets-Rotation (bei Bedarf, manuell/orchestriert)

```bash
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env \
  ROTATE_ADMIN_USER=root ROTATE_ADMIN_PASSWORD_FILE=/run/secrets/mariadb_root \
  ./rotate_cube_secret.sh
```

Siehe Runbook §6 (Secrets-Rotation) und §10 (Concurrency/Parallelität).
