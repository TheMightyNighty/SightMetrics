# Paket A – Auswertung/Import (DuckDB)  ·  betrieblicher Teil

Liest Webserver-Logs, sessionisiert und aggregiert sie mit **DuckDB** und schreibt den
**Cube** in die MariaDB (Cube-DB `analytics`, Writer-User `cube_rw`). Einziger Schreiber.

- `run_all.sh` — **Orchestrator**: importiert alle Sites aus `sites.conf` (flock-geschützt,
  `PARALLEL`/`auto`); alarmiert bei Fehler inline über `notify.sh`. Standard-Lauf des Containers.
- `load_cube.sh` — Einzel-Site-Import: DuckDB, `ATTACH` MariaDB, inkrementell (Byte-Offset),
  Per-Site-Lock, misst Wall/CPU. `<LOGDATEI> <SITE-NAME> <SITE-ID>`.
- `cube_to_mysql.sql` / `transform.sql` — Auswerte-Logik: Parse → Sessionisierung → Cube → MariaDB.
- `purge_cube.sh` — Retention-Purge · `backup_cube.sh` — Backup/Rollback-Punkt (konfigurierbar).
- `notify.sh` — Alarmierung (E-Mail/Webhook) · `rotate_cube_secret.sh` — Secrets-Rotation.
- `generate_logs.py` — Testlog-Generator · `bin/duckdb` (v1.5.4) + `geo/` — Engine + GeoIP.
- `sites.conf.example` — Vorlage (`site_id` TAB logfile TAB name).

**Voraussetzung:** erreichbare Cube-DB (User `cube_rw`), DSN via `CUBE_DSN`/`CUBE_DSN_FILE`.
Im Demo stellt der `demo/`-Stack das bereit.

**Betrieb** (nächtlicher Wegwerf-Container, persistentes `STATE_DIR`, Scheduling/Alarm):
siehe [`scheduling/README_scheduling.md`](scheduling/README_scheduling.md) und das
[Ingestion-Runbook](../docs/ingestion-runbook.md).
