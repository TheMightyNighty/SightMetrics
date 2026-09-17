> 🇬🇧 [English version](ingestion-runbook.md)

# SightMetrics – Ingestion Runbook (Paket A)

Betriebsdokumentation für den **DuckDB-basierten Log-Import** (`ingestion/`).
Dieser Teil ist der einzige Schreibzugriff auf die Cube-DB. Die
TYPO3-Extension (Paket B) liest nur.

---

## Inhaltsverzeichnis

1. [Dateistruktur](#1-dateistruktur)
2. [Einrichtung der Cube-DB](#2-einrichtung-der-cube-db)
3. [Anforderungen an die Logs](#3-anforderungen-an-die-logs)
3a. [GeoIP-Datensatz (TODO für Betreiber)](#3a-geoip-datensatz-todo-für-betreiber)
4. [Schnellstart](#4-schnellstart)
5. [Konfiguration von sites.conf](#5-konfiguration-von-sitesconf)
6. [CUBE_DSN – Secrets](#6-cube_dsn--secrets)
7. [Konfiguration des Log-Formats](#7-konfiguration-des-log-formats)
8. [Inkrementeller Import & Offset-Tracking](#8-inkrementeller-import--offset-tracking)
9. [Scheduling (Wegwerf-Container)](#9-scheduling-wegwerf-container)
10. [Parallelisierung & Nebenläufigkeit](#10-parallelisierung--nebenläufigkeit)
11. [Aufbewahrung & Bereinigung](#11-aufbewahrung--bereinigung)
12. [Monitoring & Alerting](#12-monitoring--alerting)
13. [Log-Rotation](#13-log-rotation)
14. [Multi-Site](#14-multi-site-eine-instanz-mehrere-sites)
15. [Fehlerbehebung & Recovery](#15-fehlerbehebung--recovery)
16. [Datenschutz & BSI-Hinweise](#16-datenschutz--bsi-hinweise)
17. [Rollback](#17-rollback)
17a. [Update von Version zu Version](#17a-update-von-version-zu-version)
18. [Wichtige Umgebungsvariablen](#18-wichtige-umgebungsvariablen)

---

## 1. Dateistruktur

```
ingestion/
├── load_cube.sh                Single-Site-Import (Datei): Log → DuckDB → MariaDB
├── fetch_loki_logs.sh          Single-Site-Import (Grafana Loki, Alternative zu einer Datei)
├── run_all.sh                  Multi-Site-Orchestrator (flock-geschützt, xargs -P)
├── purge_cube.sh                Retention-Bereinigung: löscht Cube-Daten älter als RETENTION_MONTHS
├── backup_cube.sh              Backup der Cube-DB (mysqldump + Rotation, Rollback-Punkt)
├── notify.sh                   Alerting (E-Mail und/oder Webhook), konfigurierbar
├── rotate_cube_secret.sh       Secret-Rotation: erneuert DB-Passwort + DSN-Datei atomar
├── matomo_import.sh            Matomo-Altdaten-Import über die Reporting-API (siehe docs/matomo-import.md)
├── lib_geo.sh                  Geo-Quellen-Auswahl (wird von load_cube.sh/fetch_loki_logs.sh eingebunden)
├── lib_logformat.sh            Log-Format-Auswahl (wird von load_cube.sh/fetch_loki_logs.sh eingebunden)
├── lib_healthcheck.sh          Healthcheck-Heartbeat (wird von run_all.sh/fetch_loki_logs.sh eingebunden)
├── cube_to_mysql.sql           Compute-Treiber, Log-Pfad (liest transform.sql)
├── matomo_to_cube.sql          Compute-Treiber, Matomo-Pfad (Äquivalent zu transform.sql)
├── transform.sql               Parsen → Sessionize → Aggregieren (sink-neutral)
├── sink_mysql.sql              Gemeinsame MariaDB-Senke (Log- und Matomo-Pfad)
├── sites.conf.example          Vorlage für sites.conf (site_id TAB logfile TAB name)
├── generate_logs.py            Test-Log-Generator (sessionbasiert, öffentliche IPs)
│
├── bin/
│   └── duckdb                  DuckDB-CLI-Binary (v1.5.4, x86_64 Linux)
│
├── geo_sources/
│   ├── native.sql               Geo-Join: eigenes Schema (start,end,cc)
│   ├── ip2location.sql          Geo-Join: IP2Location LITE DB1
│   ├── dbip.sql                 Geo-Join: DB-IP Country-Lite
│   └── maxmind.sql              Geo-Join: MaxMind GeoLite2 Country
│
├── log_formats/
│   ├── regex.sql                Log-Parsing: Klartext-Zeilen (combined/combined_vhost/common/custom)
│   └── json_ecs.sql             Log-Parsing: strukturiertes JSON (ECS-Schema)
│
├── geo/                         NICHT im Repo (.gitignore) – TODO: siehe §3a
│   └── country-ipv4-num.csv   GeoIP-Datensatz (IPv4 → Ländercode, numerisch)
│
├── scheduling/
│   └── README_scheduling.md    Betrieb des Wegwerf-Containers (cron/CronJob, kein systemd)
│
└── tests/
    ├── fixture.log             Minimales Test-Log (bekannte Werte, deterministisch)
    ├── geo_mini.csv            Minimaler GeoIP-Datensatz für Tests (eine einzelne IP)
    ├── pipeline_test.sql       Validierung von Metriken + Dimensionen + envsubst + Purge
    └── run.sh                  Pipeline-Testrunner (Suite 1, kein Docker nötig)
```

### Produktions-Layout (Ziel-Verzeichnisse)

```
/opt/sightmetrics/ingestion/       Repo-Deployment / Installationsverzeichnis
  load_cube.sh                     Single-Site-Import (Datei)
  fetch_loki_logs.sh               Single-Site-Import (Grafana Loki, optional)
  run_all.sh                       Orchestrator (Multi-Site, flock)
  purge_cube.sh                    Retention-Bereinigung
  lib_geo.sh / lib_logformat.sh /
  lib_healthcheck.sh               Gemeinsame Bausteine (benötigt von load_cube.sh/fetch_loki_logs.sh)
  transform.sql / sink_mysql.sql   DuckDB-Kernlogik + MariaDB-Senke
  cube_to_mysql.sql                DuckDB-MariaDB-Brücke
  geo_sources/ · log_formats/      Geo-Join- und Log-Parsing-Varianten (benötigt)
  sites.conf                       Site-Liste (aus sites.conf.example erstellen)
  bin/duckdb                       DuckDB-Binary
  geo/country-ipv4-num.csv         GeoIP-Datensatz

/etc/sightmetrics/
  cube_dsn.env                     CUBE_DSN=... (Rechte: root:sightmetrics 0640)

/var/lib/sightmetrics/state/
  <hash>.offset                    Byte-Offset + Inode pro Site/Log
  run_all.lock                     flock-Lockdatei
  site_N.last                      Letzter Import-Status pro Site (für Monitoring)
  metrics.log                      Kumulatives Import-Metriken-Log

/var/log/sightmetrics/import/
  run_YYYYMMDD_HHMMSS.log          Gesamtlog pro Lauf
  site_N_YYYYMMDD_HHMMSS.log       Log pro Site
```

---

## 2. Einrichtung der Cube-DB

### MariaDB-Datenbank + Benutzer anlegen

```bash
# Als root auf dem MariaDB-Server (oder via Docker):
mysql -u root -p <<'SQL'
CREATE DATABASE IF NOT EXISTS analytics
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Schreib-Benutzer (nur Ingestion/DuckDB)
CREATE USER IF NOT EXISTS 'cube_rw'@'%' IDENTIFIED BY '<SECURE_PASSWORD>';
GRANT ALL PRIVILEGES ON analytics.* TO 'cube_rw'@'%';

-- Nur-Lese-Benutzer (nur TYPO3-Extension)
CREATE USER IF NOT EXISTS 'report_ro'@'%' IDENTIFIED BY '<SECURE_PASSWORD>';
GRANT SELECT ON analytics.* TO 'report_ro'@'%';

FLUSH PRIVILEGES;
SQL
```

Die Tabellen (`cube`, `daily`, `meta`) werden beim **ersten Import**
automatisch angelegt — ein separates `CREATE TABLE` ist nicht nötig.

**Upgrade von Schema v1** (Importe vor Extension 2.0): einmalig
`mysql -u cube_rw -p analytics < ingestion/migrations/v1_to_v2.sql`
ausführen (idempotent), oder alle Logs neu importieren — Extension 2.x
verweigert v1-Daten mit einer klaren Fehlermeldung. Details:
[`docs/SCHEMA.md`](SCHEMA.de.md). Für Updates im Allgemeinen (welche
Migration wann nötig ist), siehe
[§17a](#17a-update-von-version-zu-version).

### Demo-Stack

In der Demo richtet `demo/initdb/01-analytics.sh` das automatisch bei
`docker compose up` ein. Passwörter kommen aus `demo/.env` (kopiert aus
`demo/.env.example` und angepasst).

---

## 3. Anforderungen an die Logs

Das Ingestion-Skript erwartet nginx/Apache-Access-Logs im
Standard-Combined-Format oder einem kompatiblen JSON-Format. Erforderliche
Felder:

| Feld | Inhalt | Warum |
|---|---|---|
| Zeitstempel | ISO-8601 / UTC mit Zeitzone | Sessionzuordnung, Tagesbuckets |
| Client-IP | die echte Client-IP (nicht eine Proxy-IP) | GeoIP, Unique-Visitor-Hash |
| HTTP-Methode | GET/POST/… | Filterung, Auswertung |
| URL-Pfad + Query | `/page?param=value` | Seitenbaum, interne Suche |
| HTTP-Status | 200/301/404/… | Filterung (4xx/5xx) |
| Bytes | Antwortgröße | Bandbreiten-Auswertung |
| Referrer | Herkunft | Referrer-Typen, Suchbegriffe |
| User-Agent | Browser-String | Browser-/OS-/Geräteerkennung |

**Wichtig:**
- **Echte Client-IP**: hinter einem Reverse-Proxy/CDN müssen
  `X-Forwarded-For` / `CF-Connecting-IP` ins Log geschrieben werden,
  sonst sind GeoIP und Besuchererkennung falsch.
- **Uhren per NTP synchronisiert** auf allen Webservern.
- **Chronologische Reihenfolge**: Zeilen müssen in aufsteigender
  Zeitreihenfolge vorliegen (der Standard bei Access-Logs) — der
  Tagesgrenzen-Schnitt des inkrementellen Imports (§8) schneidet den
  Batch an der ersten Zeile des noch laufenden Tages ab.
- **Kein Sampling**: jede Zeile wird gezählt.
- **Einheitliches Format** über alle Sites und Server hinweg (nginx und
  Apache identisch).
- **IPv6** wird gezählt (Besuche/Seitenaufrufe/Unique-Hash). Die
  GeoIP-Zuordnung für IPv6 ist optional: `SM_GEO6_PATH` auf eine
  Textbereichsdatei zeigen lassen (`start_ip,end_ip,cc`; die DB-IP-CSV
  enthält IPv4+IPv6 in einer Datei und kann direkt verwendet werden). Ohne
  eine v6-Datei → Land `??`. Technisch: die DuckDB-`inet`-Extension (im
  Container-Image gebündelt; wird lokal/in CI beim ersten Lauf
  installiert).
- **Bot-Filter**: Zeilen mit Crawler-/CLI-/Monitoring-User-Agents
  (Googlebot, curl, Uptime-Checks, Scanner, …) werden **ausgeschlossen**
  — wie bei Matomo werden nur menschliche Besucher gezählt. Zwei Stufen:
  - **Empfohlen (Matomo-vergleichbar):** einmalig `./tools/fetch_bot_list.sh`
    ausführen — erstellt eine validierte Liste `bots/bot_regex.list`
    (~800 Muster) aus
    [matomo/device-detector](https://github.com/matomo-org/device-detector)
    (`bots.yml`, LGPL-3.0-or-later, deshalb nicht im Repo/Image). Ist die
    Datei am Standardpfad (oder unter `SM_BOT_RE_PATH`) vorhanden, wird
    sie automatisch verwendet; die Liste **ersetzt die Heuristik
    vollständig**. Periodisch regenerieren (z. B. vierteljährlich), als
    Volume in den Container mounten.
  - **Fallback:** ohne Liste wird eine eingebaute UA-Heuristik verwendet.

  `SM_BOT_FILTER=0` deaktiviert den Filter vollständig. Leere User-Agents
  zählen absichtlich nicht als Bot (das `common`-Format hat gar keinen
  UA). Ausnahme: die Dimension `status` schließt zusätzlich 4xx/5xx-Zeilen
  ein (Fehlerdiagnose); Bots werden dort trotzdem ausgeschlossen.
- PII in Query-Strings (Tokens, E-Mails) vor dem Import maskieren/filtern.

- **Browser-/OS-Erkennung**: Standard ist eine schnelle UA-Heuristik. Für
  Matomo-identische Namen/Versionen einmalig `./tools/fetch_ua_lists.sh`
  ausführen — erstellt validierte Listen unter `ua/` aus
  matomo/device-detector (`browsers.yml`/`oss.yml`, LGPL-3.0-or-later,
  deshalb nicht im Repo/Image). Sind sie dort (oder unter
  `SM_UA_BROWSERS_PATH`/`SM_UA_OSS_PATH`) vorhanden, werden sie
  automatisch verwendet; UAs ohne Listentreffer fallen auf die Heuristik
  zurück. Kosten: das Regex-Matching skaliert mit (verschiedene UAs im
  Batch) × (~930 Muster) — für den nächtlichen Einmallauf unkritisch,
  aber bei sehr UA-vielfältigen großen Sites die Laufzeit im Auge
  behalten. Gerätetyp/-modell bleibt heuristisch (Geräteerkennung ist in
  device-detector deutlich komplexer).
  **Bekannte Einschränkung:** `tools/fetch_ua_lists.sh` verwirft
  Upstream-Regex-Muster, die Konstrukte nutzen, die DuckDBs
  RE2-Engine nicht kompilieren kann (z. B. Lookbehind-Assertions), ohne
  Ersatz für die verworfenen Muster. Eine Folge: `ua/oss.tsv` fehlt das
  generische Android-Catch-all-Muster, sodass ein moderner
  Android-User-Agent, der auf keines der verbleibenden, spezifischeren
  Android-Muster passt, fälschlich als `GNU/Linux` klassifiziert wird.

**Analytics-Feinabstimmung (env, optional):**

| Variable | Standard | Effekt |
|---|---|---|
| `SM_BOT_FILTER` | `1` | `0` = auch Bot-/Crawler-Zeilen zählen |
| `SM_TZ` | `UTC` | **Site-Zeitzone (Schema v2):** Tagesbuckets (`datum`), Besuchszeiten (`hour`) und der Tagesgrenzen-Schnitt werden in dieser Zone berechnet (z. B. `Europe/Berlin`); wird in `meta.tz` geschrieben. |
| `SM_DOWNLOAD_RE` | pdf/zip/Office/… | Regex (gegen die kleingeschriebene URL) für Download-Erkennung |
| `SM_UA_BROWSERS_PATH` / `SM_UA_OSS_PATH` | `ua/browsers.tsv` / `ua/oss.tsv` | device-detector-Listen für Browser/OS (tools/fetch_ua_lists.sh); ohne diese Dateien wird die Heuristik verwendet |
| `SM_GEO6_PATH` | – | IPv6-Geo-Bereiche (`start_ip,end_ip,cc`, z. B. die DB-IP-CSV); ohne Datei bleibt IPv6 beim Land `??` |
| `SM_COMPLETE_DAYS` | `1` | `0` = deaktiviert den Tagesgrenzen-Schnitt (nur sinnvoll für Backfills/Tests, siehe §8) |

---

## 3a. GeoIP-Datensatz (TODO für Betreiber)

**Die GeoIP-CSV ist nicht Teil des Repos** (`ingestion/geo/` steht in
`.gitignore`) und muss von jedem Betreiber selbst beschafft und abgelegt
werden — die Lizenzierung unterscheidet sich je Quelle, deshalb wird keine
Datei mitgeliefert. Ohne diese Datei bricht der Import mit einer klaren
Fehlermeldung ab (`load_cube.sh` prüft vor dem Lauf, ob sie vorhanden ist).

Drei frei verfügbare Quellen werden unterstützt, wählbar über
`SM_GEO_SOURCE`:

| `SM_GEO_SOURCE` | Anbieter | Lizenz | Download | Konto nötig |
|---|---|---|---|---|
| `native` *(Standard)* | eigenes/vorkonvertiertes Format | – (selbst verwaltet) | – | – |
| `ip2location` | IP2Location LITE DB1 | CC-BY-SA-4.0 (Namensnennung) | https://lite.ip2location.com/database/ip-country | ja (kostenlos) |
| `dbip` | DB-IP Country-Lite | CC-BY-4.0 (Namensnennung) | https://db-ip.com/db/download/ip-to-country-lite | nein |
| `maxmind` | MaxMind GeoLite2 Country | EULA (Namensnennung, Weitergabe der Rohdaten eingeschränkt) | https://www.maxmind.com/en/geolite2/eula | ja (Lizenzschlüssel) |

**Ablageort:**

```
ingestion/geo/<heruntergeladene Datei(en)>
```

Pfade sind konfigurierbar (Standardwerte passen zu `native`):

| Variable | Standard | Bedeutung |
|---|---|---|
| `SM_GEO_SOURCE` | `native` | `native` \| `ip2location` \| `dbip` \| `maxmind` |
| `SM_GEO_PATH` | `geo/country-ipv4-num.csv` | Pfad zur Haupt-CSV der gewählten Quelle |
| `SM_GEO_LOC_PATH` | `geo/GeoLite2-Country-Locations-en.csv` | nur `maxmind`: Locations-Datei (Geoname-ID → Ländercode) |

Das erwartete Rohformat je Quelle ist in
`ingestion/geo_sources/<source>.sql` dokumentiert (dort auch die
SQL-Konvertierung ins interne `start,end,cc`-Schema). `native` ist
SightMetrics' eigenes Format (kein Header, `start,end,cc` als
Integer/Integer/ISO-2-Code) — z. B. für einen selbst zusammengestellten
Datensatz aus RIR-Daten (APNIC/ARIN/RIPE).

```bash
# Beispiel: Nutzung von IP2Location LITE
SM_GEO_SOURCE=ip2location SM_GEO_PATH=/opt/sightmetrics/ingestion/geo/IP2LOCATION-LITE-DB1.CSV \
  ./load_cube.sh /logs/access.log "Authority A" 1
```

---

## 4. Schnellstart

```bash
# 1. Voraussetzungen
#    - DuckDB-Binary vorhanden: ingestion/bin/duckdb
#    - CUBE_DSN gesetzt (oder CUBE_DSN_FILE)
#    - MariaDB mit der DB 'analytics' + Benutzer cube_rw erreichbar

# 2. Single-Site-Import (interaktiv, zum Testen)
cd ingestion
CUBE_DSN="host=127.0.0.1 port=3306 user=cube_rw password=<PW> database=analytics" \
  ./load_cube.sh /logs/access.log "My Authority" 1

# 3. Multi-Site-Import (Produktion, aus sites.conf)
CUBE_DSN="..." ./run_all.sh

# 4. Ergebnis prüfen
mysql -u report_ro -p analytics -e "SELECT * FROM meta;"
```

---

## 5. Konfiguration von sites.conf

```bash
cp ingestion/sites.conf.example /opt/sightmetrics/ingestion/sites.conf
```

Format: `site_id<TAB>logfile<TAB>site_name` — eine Site pro Zeile.
Leerzeilen und `#`-Kommentare werden ignoriert.

```
# /opt/sightmetrics/ingestion/sites.conf
1	/logs/authority-a/access.log	Authority A
2	/logs/school-office-b/access.log	School Office B
3	/logs/utilities/access.log	Utilities C
```

**`site_id`** ist der Primärschlüssel im Cube — einmal vergeben, nicht
mehr ändern. Wird eine Site entfernt, bleiben ihre historischen Daten in
der Cube-DB erhalten (keine automatische Löschung).

---

## 6. CUBE_DSN – Secrets

Passwörter niemals in `sites.conf` oder Skripten speichern.

### Option 1: Umgebungsvariable

```bash
export CUBE_DSN="host=db port=3306 user=cube_rw password=<PW> database=analytics"
./run_all.sh
```

### Option 2: Secret-Datei (empfohlen für Container/Cron)

```bash
# Datei anlegen
sudo mkdir -p /etc/sightmetrics
echo 'CUBE_DSN=host=db port=3306 user=cube_rw password=<PW> database=analytics' \
  | sudo tee /etc/sightmetrics/cube_dsn.env
sudo chmod 640 /etc/sightmetrics/cube_dsn.env
sudo chown root:sightmetrics /etc/sightmetrics/cube_dsn.env
```

`load_cube.sh` und `run_all.sh` lesen automatisch aus `CUBE_DSN_FILE`
(Standard: `/run/secrets/cube_dsn`), falls `CUBE_DSN` nicht gesetzt ist.

### Secret-Rotation

`rotate_cube_secret.sh` erneuert das DB-Passwort (`ALTER USER`) **und**
schreibt die DSN-Secret-Datei atomar neu. Da jedes Skript die DSN bei
**jedem** Lauf frisch aus der Datei liest, erfolgt die Rotation faktisch
unterbrechungsfrei — kein Neustart eines Dienstes nötig. Ein Backup der
alten DSN wird aufbewahrt (`<file>.bak-<ts>`, Anzahl über
`ROTATE_KEEP_BACKUPS`).

```bash
# Ingestion-Benutzer (cube_rw) rotieren, Passwort automatisch generieren:
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env \
  ROTATE_ADMIN_USER=root ROTATE_ADMIN_PASSWORD_FILE=/etc/sightmetrics/mariadb_root.pw \
  ./rotate_cube_secret.sh

# Dry-Run (zeigt die maskierte neue DSN, ändert nichts):
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env ROTATE_DRY_RUN=1 ./rotate_cube_secret.sh
```

| Variable | Standard | Bedeutung |
|---|---|---|
| `CUBE_DSN_FILE` | – (erforderlich) | Secret-Datei, die neu geschrieben wird |
| `ROTATE_NEW_PASSWORD` | (zufällig) | neues Passwort; sonst generiert via `openssl rand` |
| `ROTATE_USER` / `ROTATE_USER_HOST` | aus der DSN / `%` | zu rotierender DB-Benutzer |
| `ROTATE_ADMIN_USER` | `root` | Admin mit `ALTER`-Recht |
| `ROTATE_ADMIN_PASSWORD` / `…_FILE` | – | Admin-Passwort (Datei bevorzugt) |
| `ROTATE_KEEP_BACKUPS` | `5` | Anzahl aufzubewahrender alter DSN-Backups |
| `ROTATE_DRY_RUN` / `ROTATE_SKIP_DB` | – | nur anzeigen / DB nicht ändern (nur Datei) |

Nach dem Setzen des neuen Passworts prüft das Skript den Login
(`SELECT 1`). Bei Bedarf als separaten, selten laufenden Scheduled Job
ausführen (z. B. vierteljährlich).

**Reporting-Benutzer (`report_ro`):** wird separat rotiert; anschließend
die TYPO3-Verbindung in `config/system/additional.php` anpassen (siehe
Extension-Handbuch §4). Ein Nur-Lese-Benutzer ohne Schreibzugriff eignet
sich auch als Backup-Credentials (`BACKUP_DSN`).

---

## 7. Konfiguration des Log-Formats

Das Ingestion-Skript unterstützt mehrere Webserver-Log-Formate über die
Umgebungsvariable `SM_LOG_FORMAT`. Standard ist `combined`
(Apache/nginx-Combined-Log-Format).

### Vordefinierte Formate

| `SM_LOG_FORMAT` | Format | Beschreibung |
|---|---|---|
| `combined` *(Standard)* | `IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"` | Apache/nginx-Combined-Log-Format |
| `combined_vhost` | `HOST:PORT IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"` | nginx mit `$host:$server_port`-Präfix |
| `common` | `IP - - [ts] "METHOD URL PROTO" STATUS SIZE` | Common-Log-Format (kein Referrer/UA) |
| `custom` | beliebig | eigenes Regex + Zeitstempelformat |
| `json_ecs` | strukturiertes JSON (eine Zeile pro Request) | ECS-ähnliches Schema, kein Regex — siehe unten |

### Verwendung

```bash
# combined_vhost (nginx mit vhost-Präfix)
SM_LOG_FORMAT=combined_vhost ./load_cube.sh /logs/access.log "Authority A" 1

# oder für alle Sites:
SM_LOG_FORMAT=combined_vhost ./run_all.sh
```

### Eigenes Format

Für nicht standardkonforme Log-Formate können Regex und Zeitstempelformat
frei definiert werden:

```bash
# Beispiel: ISO-8601-Zeitstempel statt CLF-Format
export SM_LOG_FORMAT=custom
export SM_LOG_REGEX_CUSTOM='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
export SM_TS_FORMAT_CUSTOM='%Y-%m-%dT%H:%M:%S%z'
./load_cube.sh /logs/access.log "Site" 1
```

**Wichtig:** das Regex muss genau **8 Capture-Gruppen** in dieser
Reihenfolge liefern: `(ip)(tsraw)(method)(url)(status)(size)(referrer)(ua)`.
Fehlen Felder (z. B. beim common-Format), leere Gruppen `()` verwenden.

Der Wert von `tsformat` ist ein `strptime`-Format (DuckDB-Syntax).
Gängige Formate:

| Zeitstempel-Beispiel | `SM_TS_FORMAT_CUSTOM` |
|---|---|
| `10/Jan/2026:10:00:00 +0000` (CLF, Standard) | `%d/%b/%Y:%H:%M:%S %z` |
| `2026-01-10T10:00:00+00:00` (ISO 8601) | `%Y-%m-%dT%H:%M:%S%z` |
| `2026-01-10 10:00:00` (keine TZ, als UTC behandelt) | `%Y-%m-%d %H:%M:%S` |

### JSON-Format (`json_ecs`)

Für strukturierte JSON-Logs (eine Zeile pro Request, z. B. nginx
`log_format ... escape=json`) statt Regex-Parsing. Die Feldextraktion
liegt in `log_formats/json_ecs.sql` (über `json_extract_string`, kein
Regex, keine automatische Typisierung via `read_ndjson`) und erwartet
dieses Schema (Auszug):

```json
{"@timestamp":"2026-07-01T10:00:00+00:00",
 "client":{"ip":"203.0.113.5"},
 "http":{"request":{"method":"GET"},
         "response":{"status_code":"200","bytes":"512"}},
 "app":{"url_path":"/current-notices","req":{"referer":"-"}},
 "user_agent":{"original":"Mozilla/5.0 ..."}}
```

**Kollisionen bei Schlüsselnamen vermeiden:** hat die nginx-Konfiguration
zusätzlich zum Protokoll-Level `"http"` (Kleinschreibung: version/
request/response/tls) eine App-Level-Feldgruppe (URL/Referrer/Cookies
etc.), darf diese nicht `"HTTP"` heißen (nur Groß-/Kleinschreibung
unterschiedlich) — DuckDBs JSON-Reader löst Spaltennamen ohne
Berücksichtigung der Groß-/Kleinschreibung auf und benennt intern sonst um
(`HTTP_1`, undokumentiertes Verhalten). `log_formats/json_ecs.sql`
erwartet `"app"` als Top-Level-Schlüssel für diese Felder.

```bash
CUBE_DSN="..." SM_LOG_FORMAT=json_ecs ./load_cube.sh /logs/access.json "Site" 1
# oder via Loki (siehe README): SM_LOG_FORMAT=json_ecs ./fetch_loki_logs.sh ...
```

Ein abweichendes JSON-Schema: `log_formats/json_ecs.sql` direkt anpassen
(die `json_extract_string(line, '$.path...')`-Aufrufe für die 8
Zielfelder ip/tsraw/method/url/status/size/referrer/ua).

### Umgebungsvariable setzen

Als Umgebungsvariable im Scheduler/Container übergeben:
```bash
-e SM_LOG_FORMAT=combined_vhost      # docker run / k8s env
```

---

## 8. Inkrementeller Import & Offset-Tracking

`load_cube.sh` importiert nur **neue Bytes** seit dem letzten bekannten
Offset:

- **State-Datei** pro Site/Log in `$STATE_DIR/<hash>.offset`: enthält
  Byte-Offset und Inode-Nummer.
- **Log-Rotation**: wird per Inode-Vergleich erkannt. Nach einer Rotation
  startet der Import bei Byte 0 der neuen Datei.
- **Idempotenz**: beim Import wird zunächst der Datumsbereich der neuen
  Daten aus der Cube-DB gelöscht (`DELETE WHERE datum BETWEEN ...`), dann
  werden die neuen Zeilen eingefügt. Wiederholter Import derselben Bytes
  ist unbedenklich.
- **Tagesgrenzen-Schnitt** (`day_cut.sql`): Zeilen aus dem **noch
  laufenden Tag (UTC)** werden zurückgehalten — der Offset bleibt vor der
  ersten Zeile dieses Tages stehen, und der folgende Lauf importiert den
  Tag dann vollständig. Ohne diesen Schnitt würde das Bereichs-`DELETE`
  beim folgenden Lauf die bereits importierten frühen Stunden dieses
  Tages verwerfen (Datenverlust an der Tagesgrenze). Konsequenz: **die
  Daten eines Tages erscheinen im Dashboard erst, wenn der Tag
  abgeschlossen ist** (ein nächtlicher Lauf um 02:00 Uhr zeigt den
  vollständigen Vortag). Mehrere Läufe pro Tag sind dadurch unbedenklich.
  `SM_COMPLETE_DAYS=0` deaktiviert den Schnitt (nur sinnvoll für
  Backfills abgeschlossener Zeiträume oder für Tests);
  `SM_CUTOFF_DATE=YYYY-MM-DD` überschreibt das Cutoff-Datum.
- **Der Offset wird erst nach erfolgreichem Import gesetzt** — bei einem
  Fehlschlag importiert der nächste Lauf denselben Bereich erneut.
- **Leerer-Batch-Schutz**: enthält der neue Bereich 0 gültige Zeilen, läuft
  kein `INSERT` und der Offset bleibt unverändert.
- **Einschränkung**: Sessions, die Mitternacht (UTC) überschreiten, werden
  an der Tagesgrenze aufgeteilt (tagesbasiertes Aggregationsmodell).

---

## 9. Scheduling (Wegwerf-Container)

Betriebsmodell: ein externer Scheduler (Kubernetes CronJob,
Docker/Compose-Scheduler oder Host-Cron) startet den Ingestion-Container
nachts kurz; er importiert alle Sites (`run_all.sh`) und beendet sich.
**Kein systemd im Container.** Details + Beispiele (Docker `run`, k8s
CronJob, benötigtes State-Volume, DSN-Secret, Alerting) in
[`scheduling/README_scheduling.md`](../ingestion/scheduling/README_scheduling.md).

```cron
# Host-Cron-Alternative (eine Zeile, startet den Container)
15 2 * * * docker run --rm -v sightmetrics_state:/state -v /var/log/access:/logs:ro \
  -e STATE_DIR=/state -e PARALLEL=auto -e CUBE_DSN_FILE=/run/secrets/cube_dsn \
  sightmetrics-ingestion run_all.sh >> /var/log/sightmetrics/cron.log 2>&1
```

**Erforderlich:** `STATE_DIR` auf einem **persistenten Volume** ablegen —
sonst macht jeder Lauf einen vollständigen Re-Import.
**Alerting:** der Scheduler wertet den Exit-Code aus; `run_all.sh` ruft
bei einem Fehlschlag zusätzlich inline `notify.sh` auf (siehe §12).
Purge/Backup/Rotation laufen als separate, seltenere Scheduled Jobs
(§11, §6).

---

## 10. Parallelisierung & Nebenläufigkeit

`run_all.sh` unterstützt parallele Single-Site-Importe über die
Umgebungsvariable `PARALLEL`:

```bash
PARALLEL=4 ./run_all.sh    # 4 gleichzeitige Site-Importe
```

`PARALLEL=auto` erkennt die Kernanzahl automatisch (`nproc`).

**Faustregel**: `PARALLEL` = Anzahl CPU-Kerne, höchstens so viel, dass
`MaxRSS × PARALLEL < verfügbarer RAM` bleibt. MaxRSS pro Import aus dem
Benchmark-Log ablesen (`state/metrics.log`). Für einen nächtlichen Lauf
mit wenigen Sites reicht der Standard; eine Feinabstimmung der Thread-
Anzahl von DuckDB ist nicht nötig.

**Nebenläufigkeitsschutz** (zwei Ebenen):
- `run_all.sh` erwirbt beim Start einen **flock-Lock**
  (`state/run_all.lock`); ein überlappender Lauf beendet sich sofort mit
  Exit-Code 0.
- `load_cube.sh` erwirbt zusätzlich einen **Per-Site-Lock**
  (`state/site_<id>.lock`) — der Import derselben Site kann sich nie
  überlappen (schützt Offset-/Meta-Konsistenz).

### Hochverfügbarkeit (HA)

Für das vorgesehene Betriebsmodell (eine Instanz, ein nächtlicher Lauf)
nicht erforderlich. Die **Cube-DB liegt in der eigenen MariaDB** und
teilt sich deren HA-/Backup-Regime. Die Ingestion ist nur ein DB-Client;
wird ein nächtlicher Lauf verpasst, holt der nächste Lauf inkrementell
auf (oder es erfolgt ein einmaliger Vollimport, idempotent per
DELETE+INSERT pro Datumsbereich).

---

## 11. Aufbewahrung & Bereinigung

`purge_cube.sh` löscht alle Zeilen aus `cube`, `daily` und `meta`, deren
Datum älter als `RETENTION_MONTHS` Monate ist.

```bash
# Dry-Run: zeigt, wie viele Zeilen gelöscht würden
CUBE_DSN="..." RETENTION_MONTHS=12 PURGE_DRY_RUN=1 ./purge_cube.sh

# Tatsächliche Löschung
CUBE_DSN="..." RETENTION_MONTHS=12 ./purge_cube.sh
```

`RETENTION_MONTHS` als Umgebungsvariable im Purge-Job setzen (Standard:
12 Monate). Der Purge-Lauf ist idempotent und kann jederzeit wiederholt
werden. Empfehlung: Purge als eigenen, seltenen Scheduled Job ausführen
(z. B. monatlich), nicht als Teil des nächtlichen Imports.

**Rollback**: siehe [§17 Rollback](#17-rollback).

### TYPO3-Seite: Bereinigung der Tabelle `cache_sight_metrics`

Neben der Cube-DB gibt es noch einen zweiten wachsenden Datensatz — auf
der **TYPO3-DB** (nicht der Cube-DB): die Extension cacht ihre
Lese-Queries (`cacheLifetime`, Standard 21600 s) in der Tabelle
`cache_sight_metrics`.
TYPO3s Database-Cache-Backend löscht abgelaufene Einträge **nicht**
selbstständig; ohne Bereinigung wächst die Tabelle im Betrieb unbegrenzt
(die Cache-Keys sind hochkardinal: jede Kombination aus Zeitraum,
Dimension und Drill-down-Erweiterung erzeugt einen eigenen Eintrag).

```bash
# Option 1: TYPO3-Scheduler-Task "Caching framework garbage collection"
#           (falls EXT:scheduler im Einsatz ist), Cache "sight_metrics" wählen, z. B. täglich.

# Option 2: täglicher Cron direkt auf der TYPO3-DB (nicht der Cube-DB!)
mysql -h <typo3-db-host> -u <user> -p <typo3-db> \
  -e "DELETE FROM cache_sight_metrics WHERE expires < UNIX_TIMESTAMP();"
```

Details und Hintergrund: Extension-Handbuch, Abschnitt "Bekannte
Einschränkungen: Skalierung & Caching".

### Backup als Rollback-Punkt (vor dem Purge)

`backup_cube.sh` erstellt einen `mysqldump` der Cube-Tabellen mit
Rotation. Empfehlung: **unmittelbar vor** `purge_cube.sh` im Purge-Job
ausführen (erst sichern, dann löschen):

```bash
BACKUP_DIR=/state/backups ./backup_cube.sh && RETENTION_MONTHS=12 ./purge_cube.sh
```

> Liegt der Cube in der **eigenen**, bereits gesicherten MariaDB, ist dies
> nur der gezielte Rollback-Punkt unmittelbar vor der Löschung — das
> reguläre DB-Backup deckt den Rest ab.

```bash
# Manuelles Backup (ein Nur-Lese-Benutzer wie report_ro reicht zum Dumpen)
CUBE_DSN="..." BACKUP_DIR=/var/backups/sightmetrics ./backup_cube.sh

# Dry-Run (zeigt Ziel/Konfiguration, schreibt nichts)
CUBE_DSN="..." BACKUP_DRY_RUN=1 ./backup_cube.sh
```

**Konfiguration (alles über env, z. B. in `/etc/sightmetrics/backup.env`):**

| Variable | Standard | Bedeutung |
|---|---|---|
| `BACKUP_ENABLED` | `1` | Backup an/aus (`0` = sauberes No-op) |
| `BACKUP_DIR` | `../backups` | Zielverzeichnis |
| `BACKUP_RETENTION` | `14` | Anzahl aufzubewahrender Dumps (`0` = nie löschen) |
| `BACKUP_TABLES` | `meta daily cube` | zu sichernde Tabellen (leer = ganze DB) |
| `BACKUP_COMPRESS` | `gzip` | `gzip` \| `zstd` \| `none` |
| `BACKUP_PREFIX` | `cube` | Dateiname-Präfix |
| `BACKUP_DSN` / `BACKUP_DSN_FILE` | (fällt zurück auf `CUBE_DSN`) | eigene Backup-Credentials |
| `MYSQLDUMP` / `BACKUP_EXTRA_ARGS` | `mysqldump` / – | Binary / zusätzliche Argumente |

Wiederherstellung: siehe [§17 Rollback](#17-rollback) (Dump entpacken
und laden).

---

## 12. Monitoring & Alerting

### Prometheus (node_exporter Textfile-Collector)

Jeder erfolgreiche Import schreibt atomar `.prom`-Dateien in `STATE_DIR`
(`sightmetrics_site_<id>.prom` pro Site, `sightmetrics_run.prom` pro
`run_all.sh`-Lauf): Zeitstempel des letzten Erfolgs, Dauer/CPU,
verarbeitete Bytes, Offset und OK/FAIL-Zähler. Erfassung über:

```bash
node_exporter --collector.textfile.directory=/path/to/state
```

Typischer Alert: `time() - sightmetrics_import_last_success_timestamp_seconds
> 100000` (kein erfolgreicher Import seit >27h). In Kubernetes liegt
STATE_DIR auf der PVC — entweder einen node_exporter-Sidecar mit
demselben Mount verwenden oder die Dateien per Cron ins
Textfile-Verzeichnis des Hosts kopieren.

Im Wegwerf-Container-Modell kommt das Monitoring aus zwei Quellen:

**1. Import-Fehlschläge (sofort):** der Scheduler wertet den
**Exit-Code** von `run_all.sh` aus (≠0 = mindestens eine Site
fehlgeschlagen → CronJob-`backoffLimit` / Cron-`MAILTO`). `run_all.sh`
ruft bei einem Fehlschlag außerdem **inline** `notify.sh` auf
(E-Mail/Webhook), falls ein Kanal konfiguriert ist:

| Variable | Standard | Bedeutung |
|---|---|---|
| `ALERT_EMAIL` | – | Empfänger (kommagetrennt); leer = keine E-Mail |
| `ALERT_MAIL_FROM` | `sightmetrics@<host>` | Absender |
| `ALERT_WEBHOOK` | – | Webhook-URL; leer = kein Webhook |
| `ALERT_WEBHOOK_FORMAT` | `slack` | `slack` \| `teams` \| `json` |
| `ALERT_MIN_LEVEL` | `WARN` | Mindestlevel, das gesendet wird (`OK`/`WARN`/`CRIT`) |
| `ALERT_PREFIX` | `[SightMetrics]` | Präfix für Betreff/Text |

```bash
# Alert-Kanal testen (ohne echten Vorfall):
ALERT_EMAIL=ops@example.org ./notify.sh CRIT "Test alert"
ALERT_WEBHOOK=https://hooks.slack.com/... ./notify.sh WARN "Test alert"
```

**1b. Heartbeat / ein ausgefallener Lauf:** `notify.sh` alarmiert nur bei
einem *aktiven* Fehlschlag innerhalb eines Laufs — es bemerkt nichts,
wenn der Scheduler den Lauf gar nicht erst startet (defektes
Cron/CronJob, Container stürzt vor dem Start ab, …). Dafür ein optionaler
**Healthcheck-Ping** (z. B. [healthchecks.io](https://healthchecks.io/)
oder selbst gehostet) sowohl in `run_all.sh` **als auch** in
`fetch_loki_logs.sh`: ein Start-, Erfolgs- und Fehlschlag-Ping (mit
Log-Auszug als Body). Bleibt der Ping aus, alarmiert healthchecks.io von
selbst.

```bash
export HEALTHCHECK_URL="https://hc-ping.com/<uuid>"   # oder HEALTHCHECK_URL_FILE
```

Leer/nicht gesetzt = deaktiviert (No-op), Ping-Fehler brechen den Import
nicht ab (nur eine Warnung auf stderr). Siehe `ingestion/lib_healthcheck.sh`.

**2. Aktualität (lief der Import überhaupt?):** Prüfung von der
**dauerhaft laufenden** TYPO3-Instanz aus — `sightmetrics:health` prüft
den Lesepfad der GUI (Cube erreichbar + Aktualität von `meta.bis` pro
Site):

```bash
vendor/bin/typo3 sightmetrics:health --warn-hours=26 --crit-hours=50        # Text
vendor/bin/typo3 sightmetrics:health --json                                  # für Agenten
# Exit-Codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
```

Über den TYPO3-Scheduler oder externes Monitoring (Uptime-Check)
planen.

**Ebenfalls im Blick behalten:** die MariaDB-Verbindung (eigenes
DB-Monitoring), Wachstum der Cube-DB (Tabellengröße), das letzte Backup
(`state/backup.last`), `state/metrics.log` (Laufzeiten/Bytes pro Lauf).

---

## 13. Log-Rotation

Im Wegwerf-Container-Modell schreiben die Skripte auf
**stdout/stderr** — Aufbewahrung und Rotation der Logs übernimmt der
Orchestrator (Docker-/k8s-Logging, journald bei Host-Cron). Persistente
Run-Logs unter `LOG_DIR` (falls gesetzt) können bei Bedarf über die
normale Host-Log-Rotation des Log-Volumes abgedeckt werden. Die
Erkennung **rotierter Webserver-Logs** (der Quelle) erfolgt automatisch
per Inode-Vergleich im Offset-Tracking (§8).

---

## 14. Multi-Site (eine Instanz, mehrere Sites)

Anwendungsfall: **eine** TYPO3-Instanz mit mehreren Sites in **einem**
Namespace, Cube in der **eigenen** MariaDB. Alle Sites liegen in einer
`analytics`-DB, unterschieden über `site_id`.

`sites.conf` listet alle Sites; `run_all.sh` importiert sie (sequenziell
oder mit `PARALLEL`). Jede Site hat ihre eigene
`state/<hash>.offset`-Datei. In TYPO3 bildet `sightmetrics_site_id` in
der jeweiligen Site-Konfiguration die TYPO3-Site auf die Cube-`site_id`
ab (siehe Extension-Handbuch §5); die GUI zeigt den Site-Selektor
entsprechend an.

> Mandanten-/DB-Isolation über separate Datenbanken wird für dieses
> Single-Instanz-Setup **nicht benötigt** und wurde bewusst nicht gebaut.

---

## 15. Fehlerbehebung & Recovery

### Import schlägt fehl (Exit ≠ 0)

```bash
# 1. Letzten Lauf prüfen (Container-Logs des Schedulers)
docker logs <container>            # oder kubectl logs job/<name>
# oder das persistente Run-Log (falls LOG_DIR gesetzt ist):
tail -200 "$LOG_DIR"/run_<DATE>.log

# 2. Manuell neu importieren
CUBE_DSN="..." ./load_cube.sh /logs/site1/access.log "Authority A" 1

# 3. War MariaDB nicht erreichbar: den Import einfach wiederholen.
#    Idempotenz (DELETE + INSERT) sorgt für Konsistenz.
```

### Offset-State beschädigt / falsch

```bash
# State-Datei einer Site löschen → der nächste Import startet bei Byte 0
rm /var/lib/sightmetrics/state/<hash>.offset

# Danach: die Daten dieser Site für den betroffenen Zeitraum aus der Cube-DB löschen
mysql -u cube_rw -p analytics \
  -e "DELETE FROM cube  WHERE site_id = 1 AND datum >= '2026-01-01';
      DELETE FROM daily WHERE site_id = 1 AND datum >= '2026-01-01';
      DELETE FROM meta  WHERE site_id = 1 AND datum >= '2026-01-01';"

# Import neu starten
CUBE_DSN="..." ./load_cube.sh /logs/site1/access.log "Authority A" 1
```

### Cube-DB voll / zu groß

```bash
# Tabellengrößen prüfen
mysql -u report_ro -p analytics -e "
  SELECT table_name,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 1) AS 'MB'
  FROM information_schema.TABLES
  WHERE table_schema = 'analytics'
  ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;"

# Aufbewahrung verkürzen (z. B. auf 6 Monate) und Purge auslösen
CUBE_DSN="..." RETENTION_MONTHS=6 ./purge_cube.sh
```

### Doppelter Import (derselbe Zeitraum)

Unbedenklich: `cube_to_mysql.sql` löscht den betroffenen Datumsbereich
vor dem `INSERT` (`DELETE WHERE datum BETWEEN ...`). Das Ergebnis ist
identisch zu einem einzelnen Import.

---

## 16. Datenschutz & BSI-Hinweise

Beide Log-Importer — `load_cube.sh` (Access-Log) und
`fetch_loki_logs.sh` (Loki) — führen `anonymize.sql` unmittelbar nach dem
Parser und vor jedem weiteren Schritt aus. IP-Kürzung und Entfernung des
Query-Strings erfolgen daher *vor* dem Geo-Lookup, dem Besucherschlüssel
und dem Cube; keine spätere Stufe sieht jemals eine vollständige
IP-Adresse oder den Query-String der aufgerufenen URL. Das ist nicht
optional und hat keinen Ausschalter. Der **Referrer** ist die bewusste
Ausnahme — siehe unten.

### IP-Adressen

- IP-Adressen werden **zur Importzeit gekürzt**, in `anonymize.sql`:
  - IPv4 → letztes Oktett genullt (`203.0.113.77` → `203.0.113.0`)
  - IPv6 → `/48`-Präfix (`2001:db8:1234:5678::1` → `2001:db8:1234::`)
  - IPv4-gemappte IPv6-Adressen (`::ffff:a.b.c.d`, von Dual-Stack-Sockets
    geloggt) behalten ihr Präfix und werden wie IPv4 maskiert. Sie werden
    nur über die IPv6-Geo-Datei aufgelöst, ohne `SM_GEO6_PATH` bleiben sie
    also `??`.
  - Eine IPv4-Adresse mit `:port`-Suffix (Proxy-/Load-Balancer-Formate) wird
    maskiert und verliert den Port. Alles, was keine erkennbare IP-Adresse
    ist — ein Hostname, eine `X-Forwarded-For`-Kette — **fällt auf `-`
    zurück** (fail closed) und wird nie ungekürzt durchgereicht (und hat
    dann kein Land).
- Rohe IP-Adressen werden **nicht in der Cube-DB gespeichert**. Sie
  existieren nur in der temporären Tabelle `raw_lines` (der Logtext
  selbst) für die Lebensdauer des DuckDB-Prozesses und werden nie in die
  Senke geschrieben.
- Für GeoIP und Unique-Visitor-Zählung wird ein **täglich gesalzener
  Hash** über die *gekürzte* IP berechnet: `MD5(ip + ua + daily_salt)` —
  resistent gegen Rückrechnung und innerhalb eines Tages konsistent.
- `daily_salt` wird täglich neu zufällig erzeugt (DuckDB, zur
  Importzeit).
- Zu erwartende Effekte: `uniques` kann geringfügig sinken, weil Besucher,
  die sich ein /24 (bzw. /48) *und* denselben User-Agent teilen, nun zu
  einem Besucherschlüssel zusammenfallen. Die Geo-Auflösung bleibt auf
  Länderebene, ist aber nicht mehr exakt für Provider mit Bereichen feiner
  als /24 (bzw. Bereichen, die innerhalb eines /48 beginnen): die gekürzte
  Adresse kann in den vorhergehenden Bereich fallen, was `??` oder selten
  ein Nachbarland ergibt.
- Pageviews können sich für Seiten mit Cache-Busting-Query-Strings leicht
  verschieben: `/style.css?v=3` passierte bisher den Asset-Filter und zählte
  als Pageview, `/style.css` wird jetzt korrekt herausgefiltert. Ein
  erneuter Import historischer Tage schreibt deren Werte entsprechend um.

### PII in URLs und Referrern

- **URL-Query-Strings werden zur Importzeit entfernt**: alles ab dem
  ersten `?` oder `#` wird verworfen, da Query-Parameter routinemäßig
  personenbezogene Daten tragen (Tokens, E-Mail-Adressen, Sucheingaben,
  Formularwerte). `/suche?q=maier` wird als `/suche` gespeichert.
- `SM_URL_KEEP_PARAMS` (kommagetrennt) behält benannte Parameter trotz
  des Filters. Das existiert für TYPO3-Installationen **ohne
  Slug-URLs**, bei denen die Seitenidentität im Query-String liegt — ohne
  dies würde jede Seite in eine einzige `/index.php`-Zeile
  zusammenfallen:
  ```bash
  SM_URL_KEEP_PARAMS="id,L,type" ./load_cube.sh access.log "Site" 1
  ```
  Nur Parameter benennen, die nachweislich keine personenbezogenen Daten
  tragen. Alles nicht Benannte wird entfernt. Standard ist leer — nichts
  wird behalten.
- Der **Referrer wird bewusst nicht bereinigt**: die Dimension `keyword`
  wird aus dessen `?q=`-Parameter abgeleitet, und die Dimension
  `referrer_url` ist nur mit der vollständigen URL nützlich. Er ist damit
  die einzige Stelle, an der ein Query-String *doch* im Cube landet — auch
  bei einem Referrer der eigenen Site wie `https://example.org/reset?token=…`,
  dessen Parameter `anonymize.sql` aus `url` entfernt. Falls das eigene
  Bedrohungsmodell es verlangt, vor dem Import maskieren (die Dimension
  `keyword` entfällt damit):
  ```bash
  sed -E 's#("https?://[^" ?]*)\?[^" ]*#\1#g' access.log | ./load_cube.sh - "Site" 1
  ```
- Der Matomo-Altdaten-Import (`matomo_import.sh`) wird von
  `anonymize.sql` **nicht** abgedeckt — er verarbeitet bereits
  vorab-aggregierte Reporting-API-Daten. Anonymisierung dafür in Matomo
  selbst konfigurieren, vor dem Export.

### Übertragung von Logs

- Logs dürfen nur verschlüsselt übertragen werden (TLS/SSH/SFTP).
- Least Privilege: der Import-Benutzer auf dem Webserver sollte nur
  Lesezugriff haben, nie Schreibzugriff.
- Aufbewahrungsfristen für Roh-Logs: mit dem Datenschutzbeauftragten
  klären; die Cube-DB wird über `RETENTION_MONTHS` konfiguriert.

### BSI-Grundschutz-Relevanz

- `cube_rw` und `report_ro` strikt getrennt halten (kein Schreibzugriff
  für die Extension).
- DB-Verbindungen verschlüsseln (MariaDB: `ssl=true` in der DSN, bei
  einem externen Host).
- Secrets niemals in Skripten oder Versionskontrolle ablegen; immer aus
  einer Umgebungsvariable oder Secret-Datei lesen.
- Audit-Logs auf Import-Host und MariaDB aktivieren.

---

## 17. Rollback

Um einen fehlerhaften Import rückgängig zu machen:

```bash
# Option A: einen bestimmten Zeitraum löschen (empfohlen)
mysql -u cube_rw -p analytics -e "
  DELETE FROM cube  WHERE site_id = <ID> AND datum BETWEEN '<FROM>' AND '<TO>';
  DELETE FROM daily WHERE site_id = <ID> AND datum BETWEEN '<FROM>' AND '<TO>';
  DELETE FROM meta  WHERE site_id = <ID> AND datum >= '<FROM>';"
# meta wird beim nächsten Import aus der vollständigen daily-Tabelle neu berechnet.

# Danach: State-Offset zurücksetzen und neu importieren
rm /var/lib/sightmetrics/state/<hash>.offset
CUBE_DSN="..." ./load_cube.sh /logs/site<ID>/access.log "Site name" <ID>

# Option B: ein vollständiges Backup wiederherstellen (falls vorhanden)
mysql -u root -p analytics < backup_analytics_YYYYMMDD.sql
```

**Empfehlung**: tägliche MariaDB-Backups (`mysqldump analytics`) vor dem
Import-Fenster erstellen. `cube_to_mysql.sql` ist idempotent; ein
wiederholter Import überschreibt fehlerhafte Daten korrekt.

---

## 17a. Update von Version zu Version

Zwei unabhängig versionierte Pakete (A = Ingestion, B =
TYPO3-Extension), verbunden nur über den DB-Vertrag
(`docs/SCHEMA.md`). Diese Trennung macht Updates von Natur aus robust:
**additive** Änderungen (neue Spalten/Tabellen, z. B. die Query-Indizes
oder das Top-N-Precompute) erfordern keine bestimmte Reihenfolge — jedes
Paket kann für sich aktualisiert werden, das andere läuft unverändert
gegen die alten Daten weiter. Nur **breaking** Änderungen (eine Spalte
umbenannt/entfernt, Semantik geändert — erkennbar an einer neuen
`sm_schema_version`, siehe `docs/SCHEMA.md` "Regeln für künftige
Änderungen") erfordern eine bestimmte Reihenfolge, siehe unten.

### Update der Ingestion (Paket A)

1. Den neuen Stand von `ingestion/` ausrollen (git pull, Image-Update
   usw.).
2. Für additive Änderungen ist nichts weiter nötig: `sink_mysql.sql`
   legt beim nächsten Import neue Tabellen/Spalten/Indizes idempotent an
   (`CREATE TABLE/INDEX IF NOT EXISTS`).
3. Optional, nur für sehr große bestehende Cubes: die entsprechende
   `ingestion/migrations/*.sql` separat in einem Wartungsfenster
   ausführen, statt das erste Online-DDL während des nächtlichen
   Import-Fensters laufen zu lassen (siehe Tabelle unten).

### Update der Extension (Paket B)

```bash
composer update sightmetrics/sight-metrics
vendor/bin/typo3 cache:flush
```

Die Extension prüft die Schema-Version bei jedem Modul-Aufruf und in
`sightmetrics:health` (`CubeRepository::SCHEMA_VERSION` vs.
`meta.schema_version`). Ist die Ingestion noch nicht auf der passenden
Version, bricht das Modul mit einer klaren Fehlermeldung ab (kein
Absturz, keine falschen Zahlen) und verweist auf die erforderliche
Migration — es ist also unbedenklich, die Extension vor der Ingestion zu
aktualisieren, auch über einen Major-Versionssprung hinweg. Additive
Ingestion-Features (z. B. die `topn`-Tabelle) werden übernommen, sobald
sie existieren; bis dahin nutzt die Extension automatisch ihren
bisherigen (langsameren, aber korrekten) Query-Pfad.

### Migrationen im Überblick

| Datei | Erforderlich? | Wann nötig |
|---|---|---|
| `ingestion/migrations/v1_to_v2.sql` | **Ja**, bei bestehenden v1-Daten | Breaking Change (Schema v2): CHR(31)-Keys → Spalte `parent`. Ohne diese Migration verweigert Extension 2.x den Dienst mit einer Fehlermeldung. Alternative: alle Logs neu importieren. |
| `ingestion/migrations/v2_add_indexes.sql` | Nein (die Senke legt die Indizes automatisch an) | Nur um die erste Indexerstellung (Online-DDL) bei sehr großen Cubes gezielt außerhalb des nächtlichen Import-Fensters auszuführen. |
| `ingestion/migrations/v2_add_topn.sql` | Nein (die Senke legt die Tabelle automatisch an) | Nur um Tabelle/Index vorab anzulegen, bevor der nächste Import läuft — rein kosmetisch, kein Korrektheitsrisiko bei Auslassen (siehe `docs/topn-precompute-spec.md`). |

**Faustregel:** außer `v1_to_v2.sql` sind die Migrationsskripte hier
optional und idempotent — im Zweifel einfach den nächsten regulären
Import abwarten. Ein Rollback (§17) funktioniert unverändert auch für
alle additiven Tabellen, da sie über dieselbe `site_id` geschlüsselt
sind.

### Was mit den Daten tatsächlich passiert

**Additive Migrationen** (`v2_add_indexes.sql`, `v2_add_topn.sql` und
alles, was die Senke laufend automatisch anlegt): reines `CREATE
TABLE/INDEX IF NOT EXISTS`. **Keine bestehende Zeile wird gelesen,
geändert oder gelöscht** — die neue Struktur ist rein additiv. Kein
Downtime-Risiko, kein Backup nötig, beliebig oft wiederholbar. Der
einzige Nebeneffekt: die erste Indexerstellung auf einem sehr großen
bestehenden `cube` ist ein Online-DDL, das kurzzeitig I/O-Last erzeugt
(daher die Option, es separat in einem Wartungsfenster statt während des
nächtlichen Import-Fensters auszuführen).

**`v1_to_v2.sql` (die bisher einzige breaking Migration)** ändert
bestehende Zeilen, **löscht aber keine**. Im Einzelnen, Zeile für Zeile
aus dem Skript:

- `cube.parent` (neue Spalte) sowie `meta.tz`/`meta.schema_version`
  werden über `ALTER TABLE ADD COLUMN IF NOT EXISTS` hinzugefügt —
  additiv, keine Daten betroffen.
- Bei den Drill-down-Dimensionen (`referrer_name`, `referrer_url`,
  `browser_version`, `os_version`, `device_model`) wird der bisherige
  `dimkey`-Wert `"<parent>\x1F<child>"` (CHR(31)-getrennt) in zwei
  Spalten aufgeteilt: `parent = "<parent>"`, `dimkey = "<child>"`.
  Beispiel: aus `dimkey = "Chrome\x1F125.0"` wird `parent = "Chrome"`,
  `dimkey = "125.0"`. Die Zeile selbst bleibt bestehen, nur der Inhalt
  zweier Spalten ändert sich.
- `referrer_type`-Werte werden von den alten deutschen Anzeige-Labels
  (`"Direkt"`, `"Suchmaschine"`, `"Soziale Medien"`, `"Website"`) auf
  die neutralen Keys (`direct`, `search`, `social`, `website`)
  umgemappt — dieselbe Zeile, neuer Wert. Passende
  `referrer_name`-Parent-Werte werden identisch aktualisiert.
- `meta.tz` wird für alle bestehenden Zeilen auf `'UTC'` gesetzt
  (historisch korrekt: v1 hat immer in UTC gebuckelt, unabhängig davon,
  was `SM_TZ` heute sagt). Neue Tage nach der Migration folgen der
  aktuell konfigurierten Zeitzone; alte Tage bleiben so, wie sie
  tatsächlich importiert wurden — nichts wird rückwirkend neu berechnet.
- `meta.schema_version` wird auf `2` gesetzt.

Idempotent: die `UPDATE`-Bedingungen (`INSTR(dimkey, CHAR(31)) > 0`
usw.) treffen nur auf Zeilen zu, die noch nicht von v1 migriert wurden —
ein zweiter Lauf ändert nichts weiter. **In keinem Fall Datenverlust**,
trotzdem: vor der Migration ein MariaDB-Backup erstellen (§17), da es
sich um `UPDATE`s gegen die Live-Tabelle handelt, es keinen
Dry-Run-Modus gibt und ein Fehlschlag während des Laufs (z. B. eine
abgebrochene Verbindung) einen inkonsistenten Zwischenzustand
hinterlassen könnte — genau dafür ist das Backup da.

---

## 18. Wichtige Umgebungsvariablen

| Variable | Standard | Beschreibung |
|---|---|---|
| `CUBE_DSN` | – | MariaDB-DSN (erforderlich, falls `CUBE_DSN_FILE` nicht gesetzt ist) |
| `CUBE_DSN_FILE` | `/run/secrets/cube_dsn` | Alternative: DSN aus einer Datei (k8s Secrets) |
| `SM_LOG_FORMAT` | `combined` | Log-Format: `combined`, `combined_vhost`, `common`, `custom`, `json_ecs` |
| `SM_LOG_REGEX_CUSTOM` | – | Regex für `SM_LOG_FORMAT=custom` (8 Capture-Gruppen) |
| `SM_TS_FORMAT_CUSTOM` | – | strptime-Format für `SM_LOG_FORMAT=custom` |
| `SM_GEO_SOURCE` | `native` | GeoIP-Quelle: `native`, `ip2location`, `dbip`, `maxmind` (siehe §3a) |
| `SM_GEO_PATH` | `geo/country-ipv4-num.csv` | Pfad zur Geo-CSV (selbst beschaffen, siehe §3a) |
| `SM_GEO_LOC_PATH` | `geo/GeoLite2-Country-Locations-en.csv` | nur `SM_GEO_SOURCE=maxmind`: Locations-Datei |
| `SM_TABLE_CUBE` | `cube` | Name der Cube-Tabelle (für abweichende Tabellennamen) |
| `SM_TABLE_DAILY` | `daily` | Name der Daily-Tabelle |
| `SM_TABLE_META` | `meta` | Name der Meta-Tabelle |
| `SM_TABLE_TOPN` | `topn` | Name der Top-N-Precompute-Tabelle (§17a, `docs/topn-precompute-spec.md`) |
| `RETENTION_MONTHS` | `12` | Aufbewahrungsdauer für Purge (positive Ganzzahl) |
| `PURGE_DRY_RUN` | *(nicht gesetzt)* | gesetzt: nur zählen, nicht löschen |
| `PARALLEL` | `1` | parallele Import-Jobs (`xargs -P` in `run_all.sh`) |
| `STATE_DIR` | `../state/` | Offset-State + Lock + Metriken |
| `LOG_DIR` | `../logs/import-logs/` | Import-Logs |
| `SITES_CONF` | `./sites.conf` | Pfad zur Site-Liste |
| `ALERT_EMAIL` / `ALERT_WEBHOOK` | – | Alert-Kanäle für `notify.sh` (inline in `run_all.sh`) |
| `HEALTHCHECK_URL` / `_FILE` | – | Heartbeat-Ping (healthchecks.io o. ä.); leer = deaktiviert (§12) |
| `LOKI_URL` / `LOKI_QUERY` | – | `fetch_loki_logs.sh`: Loki-Basis-URL + LogQL-Selektor (dort erforderlich) |
| `LOKI_NAMESPACE` | – | `fetch_loki_logs.sh`: Komfortfilter (Label-Matcher) |
| `LOKI_ORG_ID` | – | `fetch_loki_logs.sh`: `X-Scope-OrgID` (Loki Multi-Tenant) |
| `LOKI_LIMIT` / `LOKI_LOOKBACK_HOURS` / `LOKI_SAFETY_SECONDS` | `5000` / `24` / `30` | `fetch_loki_logs.sh`: Pagination/Erstlauf/Sicherheitsmarge |
