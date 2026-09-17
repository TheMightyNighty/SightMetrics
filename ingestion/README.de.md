> 🇬🇧 [English version](README.md)

# Paket A – Ingestion/Auswertung (DuckDB) · der operative Teil

Dies ist die **Schreibseite** von SightMetrics: Sie liest Webserver-Logs,
reduziert sie mit **[DuckDB](https://duckdb.org/)** auf Tagesaggregate und
schreibt das Ergebnis in die MariaDB-**Cube-DB** (`analytics`,
Schreib-Benutzer `cube_rw`). Paket A ist der **alleinige Schreiber** der
Cube-DB — die TYPO3-Extension (Paket B) liest nur.
→ Gesamtüberblick: [Repository-README](../README.de.md).

---

## Was hier passiert (Datenfluss)

```
access.log  ─►  parse (regex)  ─►  anonymize  ─►  sessionize  ─►  aggregate  ─►  cube DB (MariaDB)
                log_formats/       IP + URL       (IP+UA, 30 min)   (per Tag/Dim)   cube / daily / meta
                                   anonymize.sql  ── transform.sql ──
```

DuckDB erledigt die gesamte Schwerarbeit in C (Parsing, GeoIP-Join,
Sessionisierung, Aggregation) im Speicher und schreibt nur das fertige
Ergebnis per `ATTACH` in MariaDB. Pro Site landet das Ergebnis in drei
Tabellen:

- `cube(site_id, datum, dim, dimkey, pv, v)` – Seitenaufrufe + Besuche pro Tag/Dimension/Wert
- `daily(site_id, datum, visits, pageviews, uniques, bounces, bytes)` – Tageskennzahlen
- `meta(site_id, …)` – übergreifende Metadaten je Site (Zeitraum, Summen)

Der Import ist **inkrementell** (Byte-Offset pro Logdatei) und **idempotent
pro Site**: Der Cube-Schreibschritt ersetzt stets nur den verarbeiteten
Datumsbereich — mehrfaches Ausführen dupliziert niemals Daten.

---

## Skripte & Dateien

| Datei | Zweck |
|---|---|
| `run_all.sh` | **Orchestrator**: importiert alle Sites aus `sites.conf` (flock-geschützt, `PARALLEL`/`auto`), alarmiert bei Fehlern über `notify.sh`. Der Standardlauf des Containers. |
| `load_cube.sh` | **Single-Site-Import (Datei)**: DuckDB → `ATTACH` MariaDB, inkrementell (Byte-Offset), Lock pro Site, misst Wall-/CPU-Zeit. Aufruf: `load_cube.sh <logdatei> "<site-name>" <site_id>`. |
| `fetch_loki_logs.sh` | **Single-Site-Import (Grafana Loki, Alternative zu einer Datei)**: zieht Zeilen per LogQL **Tag für Tag** (lokaler Kalendertag 00:00→24:00 in eine Temp-Datei), schreibt jeden Tag einzeln nach MariaDB; inkrementell über einen Tagesstatus statt eines Byte-Offsets, der vorherige Tag wird bei erneutem Lauf überschrieben. |
| `anonymize.sql` | **Datenschutzschritt** (beide Log-Importer, immer aktiv): kürzt IPv4 auf `a.b.c.0` und IPv6 auf sein `/48`-Präfix, verwirft URL-Query-Strings. Läuft direkt nach dem Parser, sodass keine spätere Stufe eine vollständige IP oder einen Query-Parameter sieht. `SM_URL_KEEP_PARAMS` behält benannte Parameter (TYPO3 ohne Slug-URLs). Siehe Runbook §16. |
| `transform.sql` | **Analyselogik** (Sink-neutral): parse → sessionize → `cube_rows`/`daily_rows`. |
| `cube_to_mysql.sql` | Compute-Treiber des Log-Pfads (liest `transform.sql`). |
| `sink_mysql.sql` | **Gemeinsame MariaDB-Senke** (Schema, idempotentes Range-DELETE+INSERT, meta). Wird sowohl vom Log- als auch vom Matomo-Pfad genutzt. |
| `matomo_import.sh` / `matomo_to_cube.sql` | **Matomo-Altdaten-Import** über die Reporting-API → siehe [`docs/matomo-import.md`](../docs/matomo-import.md). |
| `purge_cube.sh` | Retention-Bereinigung (löscht Cube-Daten älter als `RETENTION_MONTHS`). |
| `backup_cube.sh` | Backup-/Rollback-Punkt der Cube-DB (mysqldump + Rotation). |
| `notify.sh` | Alarmierung (E-Mail und/oder Webhook), konfigurierbar. |
| `rotate_cube_secret.sh` | Rotation des DB-Secrets. |
| `generate_logs.py` | Test-Log-Generator. |
| `lib_geo.sh` / `lib_logformat.sh` / `lib_healthcheck.sh` | Gemeinsame Bausteine (eingebunden von `load_cube.sh` und `fetch_loki_logs.sh`): Geo-Quellenauswahl, Log-Format-Auswahl, Healthcheck-Heartbeat. |
| `geo_sources/` | Geo-Join je Quelle: `native`, `ip2location`, `dbip`, `maxmind` (siehe Runbook §3a). |
| `log_formats/` | Log-Parsing je Format: `regex` (Klartext, Standard) oder `json_ecs` (strukturiertes JSON, siehe Runbook §7). |
| `bin/duckdb` (v1.5.4) · `geo/` | DuckDB-Engine (statisches Binary) + GeoIP-Daten. |
| `sites.conf.example` | Vorlage für `sites.conf` (`site_id` TAB Logdatei TAB Name). |
| `scheduling/` | systemd/cron-Vorlagen für den Produktivbetrieb. |

---

## Voraussetzungen

- **Erreichbare Cube-DB** (MariaDB) mit Schreib-Benutzer `cube_rw`; DSN über
  `CUBE_DSN` oder `CUBE_DSN_FILE` (Docker-Secret-Muster). In der Demo stellt
  der `demo/`-Stack dies bereit.
- Das mitgelieferte `bin/duckdb` (kein System-DuckDB nötig).
- Logs im **Combined-/Common-Log-Format** (Apache/nginx); andere Formate über
  `SM_LOG_FORMAT` / eine eigene Regex — siehe das Runbook.

---

## Schnellstart

```bash
# Eine einzelne Site importieren
./load_cube.sh ../logs/example_1k.log "Sample Authority" 1

# Alle Sites aus sites.conf (sequenziell oder parallel)
CUBE_DSN="host=… user=cube_rw password=… database=analytics" ./run_all.sh --parallel auto
```

Als **Container** (nächtlich, einmaliger Lauf) über den Demo-Stack:

```bash
cd ../demo && docker compose --profile import run --rm ingestion
```

---

## Alternative Log-Quelle: Grafana Loki

Sind Logs bereits zentral über **Loki** gesammelt (z. B. Promtail +
Grafana/Prometheus-Stack), kann `fetch_loki_logs.sh` statt einer Logdatei
verwendet werden — verarbeitet **Tag für Tag**: für jeden lokalen
Kalendertag (`--timezone`, Standard `Europe/Berlin`) wird das Fenster
00:00:00→23:59:59 per LogQL in eine Temp-Datei gezogen (`SM_TMPDIR`,
Standard `/tmp`), von DuckDB aggregiert (Speicherlimit
`DUCKDB_MEMORY_LIMIT`, Standard 2 GB, spillt auf Platte) und nach MariaDB
geschrieben — erst danach folgt der nächste Tag. Das hält selbst 1–2 GB Logs
pro Tag handhabbar und erzeugt genau eine `daily`-Zeile pro Tag.
Voraussetzung: Die Loki-Zeilen enthalten die vollständige Rohzeile
(Apache/nginx combined oder JSON/ECS, siehe `SM_LOG_FORMAT`).

```bash
CUBE_DSN="host=… user=cube_rw password=… database=analytics" \
  ./fetch_loki_logs.sh --url http://loki:3100 \
                       --query '{job="nginx"}' --namespace authority-a \
                       --site-id 1 --site-name "Authority A"
```

Ausgelegt für **einen Lauf pro Tag** (z. B. wenige Minuten nach Mitternacht):
importiert den Vortag; verpasste Tage werden über den **Tagesstatus**
nachgeholt (`<hash>.loki_day` statt eines Byte-Offsets), der aktuell
laufende (unvollständige) Tag wird übersprungen. Loki filtert nach
*Ingestion*-Zeit, die hinter dem Zeitstempel innerhalb der Zeile
zurückbleibt — jeder Tag wird daher mit einem Sicherheitsabstand
(`--margin-seconds`, Standard 60) abgefragt, und `day_filter.sql` bündelt
strikt nach dem **eigenen Zeitstempel der Zeile**: Nachzügler, die noch
23:59:59 des Vortags tragen, werden verworfen, statt eine zusätzliche
Streu-`daily`-Zeile zu erzeugen. Der Vortag wird bei jedem Lauf
**neu importiert und ersetzt** (Range-DELETE+INSERT in der Senke) — das
Skript kann also gefahrlos mehrfach oder tagsüber laufen. Erster Lauf:
`--lookback-days N` (volle Tage zurück, endend gestern). `--namespace` ist
eine Komfortoption, die als zusätzlicher Label-Matcher in `--query`
eingemischt wird. Alle Optionen: `fetch_loki_logs.sh --help`.

## Heartbeat-Überwachung (healthchecks.io)

`run_all.sh` und `fetch_loki_logs.sh` pingen optional einen
**Healthcheck-Endpunkt** (healthchecks.io oder selbst gehostet) bei
Start/Erfolg/Fehler — ergänzend zu `notify.sh` (das nur bei *aktiven*
Fehlern innerhalb eines Laufs alarmiert) um die Erkennung eines
**fehlenden** Laufs (Scheduler tot, Container startet nicht, …):

```bash
export HEALTHCHECK_URL="https://hc-ping.com/<uuid>"   # oder HEALTHCHECK_URL_FILE
```

Leer/nicht gesetzt = deaktiviert (No-op). Siehe `lib_healthcheck.sh`.

---

## Betrieb (Produktion)

Nächtlicher Wegwerf-Container, persistentes `STATE_DIR`-Volume
(Offsets/Locks/Metriken), DSN als Laufzeit-Secret, Scheduling,
Monitoring/Alarmierung, Retention, Log-Rotation, Recovery:

- **[`scheduling/README_scheduling.md`](scheduling/README_scheduling.md)** – Scheduling-Vorlagen
- **[Ingestion-Runbook](../docs/ingestion-runbook.md)** – vollständige
  Betriebsdokumentation (Einrichtung der Cube-DB, Secrets, Log-Formate,
  Parallelisierung, Datenschutz/BSI, Rollback, wichtige Umgebungsvariablen).
