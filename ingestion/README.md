# Paket A – Ingestion / Auswertung (DuckDB)  ·  der betriebliche Teil

Dies ist der **Schreib-Teil** von SightMetrics: Er liest Webserver-Logs, rechnet sie
mit **[DuckDB](https://duckdb.org/)** zu Tages-Aggregaten herunter und schreibt diese
in die MariaDB **Cube-DB** (`analytics`, Writer-User `cube_rw`). Paket A ist der
**einzige Schreiber** der Cube-DB – die TYPO3-Extension (Paket B) liest nur.
→ Gesamtüberblick: [Repo-README](../README.md).

---

## Was hier passiert (Datenfluss)

```
access.log  ─►  parse (Regex)  ─►  sessionisieren  ─►  aggregieren  ─►  Cube-DB (MariaDB)
                transform.sql      (IP+UA, 30 Min)     (pro Tag/Dim)     cube / daily / meta
```

DuckDB erledigt das gesamte „Heavy Lifting" in C (Parsen, GeoIP-Join,
Sessionisierung, Aggregation) im Speicher und schreibt nur das fertige Ergebnis
per `ATTACH` in die MariaDB. Pro Site landet das Ergebnis in drei Tabellen:

- `cube(site_id, datum, dim, dimkey, pv, v)` – pro Tag/Dimension/Ausprägung Pageviews + Visits
- `daily(site_id, datum, visits, pageviews, uniques, bounces, bytes)` – Tageskennzahlen
- `meta(site_id, …)` – Gesamt-Metadaten je Site (Zeitraum, Summen)

Der Import ist **inkrementell** (Byte-Offset je Logdatei) und **idempotent pro Site**:
Der Cube-Schreibteil ersetzt immer nur den verarbeiteten Datumsbereich, mehrfaches
Laufen verdoppelt nichts.

---

## Skripte & Dateien

| Datei | Zweck |
|---|---|
| `run_all.sh` | **Orchestrator**: importiert alle Sites aus `sites.conf` (flock-geschützt, `PARALLEL`/`auto`), alarmiert bei Fehler über `notify.sh`. Standardlauf des Containers. |
| `load_cube.sh` | **Einzel-Site-Import**: DuckDB → `ATTACH` MariaDB, inkrementell (Byte-Offset), Per-Site-Lock, misst Wall/CPU. Aufruf: `load_cube.sh <Logdatei> "<Site-Name>" <site_id>`. |
| `transform.sql` | **Auswerte-Logik** (sink-neutral): Parse → Sessionisierung → `cube_rows`/`daily_rows`. |
| `cube_to_mysql.sql` | Compute-Treiber des Log-Pfads (liest `transform.sql`). |
| `sink_mysql.sql` | **Gemeinsamer MariaDB-Sink** (Schema, idempotentes Range-DELETE+INSERT, Meta). Wird von Log- **und** Matomo-Pfad genutzt. |
| `matomo_import.sh` / `matomo_to_cube.sql` | **Matomo-Altdaten-Import** über die Reporting-API → siehe [`docs/matomo-import.md`](../docs/matomo-import.md). |
| `purge_cube.sh` | Retention-Purge (löscht Cube-Daten älter als `RETENTION_MONTHS`). |
| `backup_cube.sh` | Backup/Rollback-Punkt der Cube-DB (mysqldump + Rotation). |
| `notify.sh` | Alarmierung (E-Mail und/oder Webhook), konfigurierbar. |
| `rotate_cube_secret.sh` | Rotation des DB-Secrets. |
| `generate_logs.py` | Testlog-Generator. |
| `bin/duckdb` (v1.5.4) · `geo/` | DuckDB-Engine (statisches Binary) + GeoIP-Daten. |
| `sites.conf.example` | Vorlage für `sites.conf` (`site_id` TAB Logfile TAB Name). |
| `scheduling/` | systemd/Cron-Vorlagen für den produktiven Betrieb. |

---

## Voraussetzungen

- **Erreichbare Cube-DB** (MariaDB) mit Writer-User `cube_rw`; DSN über `CUBE_DSN`
  oder `CUBE_DSN_FILE` (Docker-Secret-Pattern). Im Demo stellt der `demo/`-Stack das bereit.
- Die mitgelieferte `bin/duckdb` (kein System-DuckDB nötig).
- Logs im **Combined/Common Log Format** (Apache/nginx); andere Formate via
  `SM_LOG_FORMAT` / eigener Regex – siehe Runbook.

---

## Schnellstart

```bash
# Einzelne Site importieren
./load_cube.sh ../logs/example_1k.log "Bürgeramt Mitte" 1

# Alle Sites aus sites.conf (sequenziell oder parallel)
CUBE_DSN="host=… user=cube_rw password=… database=analytics" ./run_all.sh --parallel auto
```

Als **Container** (nächtlicher One-Shot) über den Demo-Stack:

```bash
cd ../demo && docker compose --profile import run --rm ingestion
```

---

## Betrieb (Produktion)

Nächtlicher Wegwerf-Container, persistentes `STATE_DIR`-Volume (Offsets/Locks/Metriken),
DSN als Laufzeit-Secret, Scheduling, Monitoring/Alarm, Retention, Log-Rotation, Recovery:

- **[`scheduling/README_scheduling.md`](scheduling/README_scheduling.md)** – Scheduling-Vorlagen
- **[Ingestion-Runbook](../docs/ingestion-runbook.md)** – vollständige Betriebsdoku
  (Cube-DB anlegen, Secrets, Log-Formate, Parallelisierung, Datenschutz/BSI, Rollback,
  wichtige ENV-Variablen).
