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
| `load_cube.sh` | **Einzel-Site-Import (Datei)**: DuckDB → `ATTACH` MariaDB, inkrementell (Byte-Offset), Per-Site-Lock, misst Wall/CPU. Aufruf: `load_cube.sh <Logdatei> "<Site-Name>" <site_id>`. |
| `fetch_loki_logs.sh` | **Einzel-Site-Import (Grafana Loki, alternativ zur Datei)**: holt neue Zeilen per LogQL, verarbeitet sie direkt (keine Zwischendatei), inkrementell über Zeitstempel-State statt Byte-Offset. |
| `transform.sql` | **Auswerte-Logik** (sink-neutral): Parse → Sessionisierung → `cube_rows`/`daily_rows`. |
| `cube_to_mysql.sql` | Compute-Treiber des Log-Pfads (liest `transform.sql`). |
| `sink_mysql.sql` | **Gemeinsamer MariaDB-Sink** (Schema, idempotentes Range-DELETE+INSERT, Meta). Wird von Log- **und** Matomo-Pfad genutzt. |
| `matomo_import.sh` / `matomo_to_cube.sql` | **Matomo-Altdaten-Import** über die Reporting-API → siehe [`docs/matomo-import.md`](../docs/matomo-import.md). |
| `purge_cube.sh` | Retention-Purge (löscht Cube-Daten älter als `RETENTION_MONTHS`). |
| `backup_cube.sh` | Backup/Rollback-Punkt der Cube-DB (mysqldump + Rotation). |
| `notify.sh` | Alarmierung (E-Mail und/oder Webhook), konfigurierbar. |
| `rotate_cube_secret.sh` | Rotation des DB-Secrets. |
| `generate_logs.py` | Testlog-Generator. |
| `lib_geo.sh` / `lib_logformat.sh` / `lib_healthcheck.sh` | Gemeinsame Bausteine (source'd von `load_cube.sh` und `fetch_loki_logs.sh`): Geo-Quellen-Auswahl, Log-Format-Auswahl, Healthcheck-Heartbeat. |
| `geo_sources/` | Geo-Join je Quelle: `native`, `ip2location`, `dbip`, `maxmind` (siehe Runbook §3a). |
| `log_formats/` | Log-Parsing je Format: `regex` (Klartext, Standard) oder `json_ecs` (strukturiertes JSON, siehe Runbook §7). |
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

## Alternative Log-Quelle: Grafana Loki

Wer Logs bereits zentral über **Loki** sammelt (z. B. Promtail + Grafana/Prometheus-
Stack), kann statt einer Logdatei `fetch_loki_logs.sh` verwenden – ruft per LogQL nur
die seit dem letzten Lauf neuen Zeilen ab und verarbeitet sie **direkt**, ohne
Zwischendatei (Zeilen bleiben im Prozessspeicher und werden per Pipe an DuckDB
gestreamt). Voraussetzung: Die Loki-Zeilen enthalten die volle Rohzeile
(Apache/nginx Combined), z. B. weil Promtail `access.log` unverändert scraped.

```bash
CUBE_DSN="host=… user=cube_rw password=… database=analytics" \
  ./fetch_loki_logs.sh --url http://loki:3100 \
                       --query '{job="nginx"}' --namespace behoerde-a \
                       --site-id 1 --site-name "Behörde A"
```

Inkrementell über einen **Zeitstempel-State** (nicht Byte-Offset, da keine Datei
existiert) – `--namespace` ist eine Bequemlichkeitsoption, die als zusätzlicher
Label-Matcher in `--query` eingemischt wird. Details, Grenzen (Pagination,
Speicherbedarf bei großen Batches) und alle Optionen: `fetch_loki_logs.sh --help`.

## Heartbeat-Monitoring (healthchecks.io)

`run_all.sh` und `fetch_loki_logs.sh` pingen optional einen **Healthcheck-Endpunkt**
(healthchecks.io oder selbstgehostet) bei Start/Erfolg/Fehler – ergänzt `notify.sh`
(das nur bei *aktiven* Fehlern innerhalb eines Laufs alarmiert) um die Erkennung
eines **ausbleibenden** Laufs (Scheduler tot, Container startet nicht, …):

```bash
export HEALTHCHECK_URL="https://hc-ping.com/<uuid>"   # oder HEALTHCHECK_URL_FILE
```

Leer/nicht gesetzt = deaktiviert (No-op). Siehe `lib_healthcheck.sh`.

---

## Betrieb (Produktion)

Nächtlicher Wegwerf-Container, persistentes `STATE_DIR`-Volume (Offsets/Locks/Metriken),
DSN als Laufzeit-Secret, Scheduling, Monitoring/Alarm, Retention, Log-Rotation, Recovery:

- **[`scheduling/README_scheduling.md`](scheduling/README_scheduling.md)** – Scheduling-Vorlagen
- **[Ingestion-Runbook](../docs/ingestion-runbook.md)** – vollständige Betriebsdoku
  (Cube-DB anlegen, Secrets, Log-Formate, Parallelisierung, Datenschutz/BSI, Rollback,
  wichtige ENV-Variablen).
