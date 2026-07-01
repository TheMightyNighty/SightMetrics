# SightMetrics – Ingestion-Runbook (Paket A)

Betriebsdokumentation für den **DuckDB-basierten Log-Import** (`ingestion/`).
Dieser Teil ist der einzige Schreiber der Cube-DB. Die TYPO3-Extension (Paket B)
liest nur.

---

## Inhaltsverzeichnis

1. [Dateistruktur](#1-dateistruktur)
2. [Cube-DB anlegen](#2-cube-db-anlegen)
3. [Voraussetzungen an die Logs](#3-voraussetzungen-an-die-logs)
3a. [GeoIP-Datensatz (TODO für Betreiber)](#3a-geoip-datensatz-todo-für-betreiber)
4. [Schnellstart](#4-schnellstart)
5. [sites.conf konfigurieren](#5-sitesconf-konfigurieren)
6. [CUBE_DSN – Secrets](#6-cube_dsn--secrets)
7. [Log-Format konfigurieren](#7-log-format-konfigurieren)
8. [Inkrementeller Import & Offset-Tracking](#8-inkrementeller-import--offset-tracking)
9. [Scheduling (Wegwerf-Container)](#9-scheduling-wegwerf-container)
10. [Parallelisierung & Concurrency](#10-parallelisierung--concurrency)
11. [Retention & Purging](#11-retention--purging)
12. [Monitoring & Alerting](#12-monitoring--alerting)
13. [Log-Rotation](#13-log-rotation)
14. [Multi-Site](#14-multi-site-eine-instanz-mehrere-sites)
15. [Fehler-Runbook & Recovery](#15-fehler-runbook--recovery)
16. [Datenschutz & BSI-Hinweise](#16-datenschutz--bsi-hinweise)
17. [Rollback](#17-rollback)
18. [Wichtige ENV-Variablen](#18-wichtige-env-variablen)

---

## 1. Dateistruktur

```
ingestion/
├── load_cube.sh                Einzel-Site-Import: Log → DuckDB → MariaDB
├── run_all.sh                  Multi-Site-Orchestrator (flock-geschützt, xargs -P)
├── purge_cube.sh               Retention-Purge: löscht Cube-Daten älter als RETENTION_MONTHS
├── backup_cube.sh              Backup der Cube-DB (mysqldump + Rotation, Rollback-Punkt)
├── notify.sh                   Alarmierung (E-Mail und/oder Webhook), konfigurierbar
├── rotate_cube_secret.sh       Secrets-Rotation: DB-Passwort + DSN-Datei atomar erneuern
├── cube_to_mysql.sql           Kern-Logik: Parse → Sessionisierung → Cube → MariaDB-INSERT
├── transform.sql               DuckDB-interne Transformation (wird von cube_to_mysql.sql geladen)
├── sites.conf.example          Vorlage für sites.conf (site_id TAB logfile TAB name)
├── generate_logs.py            Testlog-Generator (session-basiert, öffentliche IPs)
│
├── bin/
│   └── duckdb                  DuckDB-CLI-Binary (v1.5.4, x86_64-Linux)
│
├── geo_sources/
│   ├── native.sql               Geo-Join: eigenes Schema (start,end,cc)
│   ├── ip2location.sql          Geo-Join: IP2Location LITE DB1
│   ├── dbip.sql                 Geo-Join: DB-IP Country-Lite
│   └── maxmind.sql              Geo-Join: MaxMind GeoLite2 Country
│
├── geo/                         NICHT im Repo (.gitignore) – TODO: siehe §3a
│   └── country-ipv4-num.csv   GeoIP-Datensatz (IPv4 → Land-Code, numerisch)
│
├── scheduling/
│   └── README_scheduling.md    Betrieb im Wegwerf-Container (Cron/CronJob, kein systemd)
│
└── tests/
    ├── fixture.log             Minimales Test-Log (bekannte Werte, deterministisch)
    ├── geo_mini.csv            Minimaler GeoIP-Datensatz für Tests (nur eine IP)
    ├── pipeline_test.sql       Kennzahlen + Dims + Envsubst + Purge-Validierung
    └── run.sh                  Pipeline-Test-Runner (Suite 1, kein Docker nötig)
```

### Produktions-Layout (Ziel-Verzeichnisse)

```
/opt/sightmetrics/ingestion/       Repo-Deployment / Installationsverzeichnis
  load_cube.sh                     Einzel-Site-Import
  run_all.sh                       Orchestrator (Multi-Site, flock)
  purge_cube.sh                    Retention-Purge
  transform.sql                    DuckDB-Kernlogik
  cube_to_mysql.sql                DuckDB-MariaDB-Brücke
  sites.conf                       Site-Liste (aus sites.conf.example erstellen)
  bin/duckdb                       DuckDB-Binary
  geo/country-ipv4-num.csv         GeoIP-Datensatz

/etc/sightmetrics/
  cube_dsn.env                     CUBE_DSN=... (Berechtigungen: root:sightmetrics 0640)

/var/lib/sightmetrics/state/
  <hash>.offset                    Byte-Offset + Inode pro Site/Log
  run_all.lock                     flock-Lockfile
  site_N.last                      Letzter Import-Status pro Site (für Monitoring)
  metrics.log                      Kumulatives Import-Metrik-Log

/var/log/sightmetrics/import/
  run_YYYYMMDD_HHMMSS.log          Gesamt-Log je Lauf
  site_N_YYYYMMDD_HHMMSS.log       Einzel-Site-Log
```

---

## 2. Cube-DB anlegen

### MariaDB-Datenbank + User anlegen

```bash
# Als root auf dem MariaDB-Server (oder via Docker):
mysql -u root -p <<'SQL'
CREATE DATABASE IF NOT EXISTS analytics
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Schreib-User (nur für Ingestion/DuckDB)
CREATE USER IF NOT EXISTS 'cube_rw'@'%' IDENTIFIED BY '<SICHERES_PASSWORT>';
GRANT ALL PRIVILEGES ON analytics.* TO 'cube_rw'@'%';

-- Read-only-User (nur für TYPO3-Extension)
CREATE USER IF NOT EXISTS 'report_ro'@'%' IDENTIFIED BY '<SICHERES_PASSWORT>';
GRANT SELECT ON analytics.* TO 'report_ro'@'%';

FLUSH PRIVILEGES;
SQL
```

Die Tabellen (`cube`, `daily`, `meta`) werden beim **ersten Import** automatisch
angelegt — kein separates `CREATE TABLE` nötig.

### Demo-Stack

Im Demo übernimmt `demo/initdb/01-analytics.sh` die Anlage automatisch beim
`docker compose up`. Passwörter kommen aus `demo/.env` (aus `demo/.env.example`
kopieren und anpassen).

---

## 3. Voraussetzungen an die Logs

Das Ingestion-Skript erwartet Nginx-Access-Logs im Standard-Combined-Format oder
einem kompatiblen JSON-Format. Pflichtfelder:

| Feld | Inhalt | Warum |
|---|---|---|
| Zeitstempel | ISO-8601 / UTC mit Zeitzone | Session-Zuordnung, Tages-Buckets |
| Client-IP | echte Client-IP (kein Proxy-IP) | GeoIP, Unique-Visitors-Hash |
| HTTP-Methode | GET/POST/… | Filter, Auswertung |
| URL-Pfad + Query | `/seite?param=wert` | Seitenbaum, interne Suche |
| HTTP-Status | 200/301/404/… | Filterung (4xx/5xx) |
| Bytes | Antwortgröße | Bandbreitenauswertung |
| Referrer | Herkunft | Referrer-Typen, Suchbegriffe |
| User-Agent | Browser-String | Browser/OS/Gerät-Erkennung |

**Wichtig:**
- **Echte Client-IP**: Bei Reverse-Proxy / CDN muss `X-Forwarded-For` /
  `CF-Connecting-IP` ins Log geschrieben werden, sonst ist GeoIP und
  Visitor-Recognition falsch.
- **Uhren via NTP synchron** auf allen Webservern.
- **Kein Sampling**: jede Zeile wird gezählt.
- **Einheitliches Format** über alle Sites und Server (nginx und apache identisch).
- PII in Query-Strings (Tokens, E-Mails) vor dem Import maskieren/herausfiltern.

---

## 3a. GeoIP-Datensatz (TODO für Betreiber)

**Die GeoIP-CSV ist nicht Teil des Repos** (`ingestion/geo/` ist in `.gitignore`) und
muss von jedem Betreiber selbst beschafft und abgelegt werden — die genaue
Lizenzlage lässt sich nicht pauschal für alle Betreiber klären, daher liefern wir
keine Datei mit. Ohne diese Datei bricht der Import mit einer klaren Fehlermeldung
ab (`load_cube.sh` prüft das Vorhandensein vor dem Lauf).

Unterstützt werden drei frei verfügbare Quellen, auswählbar über `SM_GEO_SOURCE`:

| `SM_GEO_SOURCE` | Anbieter | Lizenz | Download | Account nötig |
|---|---|---|---|---|
| `native` *(Standard)* | eigenes/vorkonvertiertes Format | – (selbst verantwortet) | – | – |
| `ip2location` | IP2Location LITE DB1 | CC-BY-SA-4.0 (Attribution) | https://lite.ip2location.com/database/ip-country | ja (kostenlos) |
| `dbip` | DB-IP Country-Lite | CC-BY-4.0 (Attribution) | https://db-ip.com/db/download/ip-to-country-lite | nein |
| `maxmind` | MaxMind GeoLite2 Country | EULA (Attribution, Weitergabe der Rohdaten eingeschränkt) | https://www.maxmind.com/en/geolite2/eula | ja (Lizenzschlüssel) |

**Ablage:**

```
ingestion/geo/<heruntergeladene Datei(en)>
```

Pfade sind konfigurierbar (Standard passt zu `native`):

| Variable | Standard | Bedeutung |
|---|---|---|
| `SM_GEO_SOURCE` | `native` | `native` \| `ip2location` \| `dbip` \| `maxmind` |
| `SM_GEO_PATH` | `geo/country-ipv4-num.csv` | Pfad zur Haupt-CSV der gewählten Quelle |
| `SM_GEO_LOC_PATH` | `geo/GeoLite2-Country-Locations-en.csv` | nur bei `maxmind`: Locations-Datei (Geoname-ID → Ländercode) |

Das erwartete Rohformat je Quelle ist in `ingestion/geo_sources/<quelle>.sql`
dokumentiert (dort auch die SQL-Umwandlung ins interne Schema `start,end,cc`).
`native` ist das SightMetrics-eigene Format (kein Header, `start,end,cc` als
Integer/Integer/ISO-2-Code) — z. B. wenn ihr euch selbst einen Datensatz aus
RIR-Daten (APNIC/ARIN/RIPE) zusammenstellt.

```bash
# Beispiel: IP2Location LITE nutzen
SM_GEO_SOURCE=ip2location SM_GEO_PATH=/opt/sightmetrics/ingestion/geo/IP2LOCATION-LITE-DB1.CSV \
  ./load_cube.sh /logs/access.log "Behörde A" 1
```

---

## 4. Schnellstart

```bash
# 1. Voraussetzungen
#    - DuckDB-Binary vorhanden: ingestion/bin/duckdb
#    - CUBE_DSN gesetzt (oder CUBE_DSN_FILE)
#    - MariaDB mit 'analytics'-DB + cube_rw-User erreichbar

# 2. Einzel-Site-Import (interaktiv, zum Testen)
cd ingestion
CUBE_DSN="host=127.0.0.1 port=3306 user=cube_rw password=<PW> database=analytics" \
  ./load_cube.sh /logs/access.log "Meine Behörde" 1

# 3. Multi-Site-Import (produktiv, aus sites.conf)
CUBE_DSN="..." ./run_all.sh

# 4. Ergebnis prüfen
mysql -u report_ro -p analytics -e "SELECT * FROM meta;"
```

---

## 5. sites.conf konfigurieren

```bash
cp ingestion/sites.conf.example /opt/sightmetrics/ingestion/sites.conf
```

Format: `site_id<TAB>logfile<TAB>site_name` — eine Site pro Zeile.
Leerzeilen und `#`-Kommentare werden ignoriert.

```
# /opt/sightmetrics/ingestion/sites.conf
1	/logs/behoerde-a/access.log	Behörde A
2	/logs/behoerde-b/access.log	Schulamt B
3	/logs/stadtwerke/access.log	Stadtwerke C
```

**`site_id`** ist der Primärschlüssel im Cube — einmal vergeben, nicht mehr ändern.
Wird eine Site entfernt, bleiben ihre historischen Daten in der Cube-DB erhalten
(kein automatisches Löschen).

---

## 6. CUBE_DSN – Secrets

Niemals Passwörter in `sites.conf` oder Skripten hinterlegen.

### Variante 1: Umgebungsvariable

```bash
export CUBE_DSN="host=db port=3306 user=cube_rw password=<PW> database=analytics"
./run_all.sh
```

### Variante 2: Secret-Datei (empfohlen für Container / Cron)

```bash
# Datei anlegen
sudo mkdir -p /etc/sightmetrics
echo 'CUBE_DSN=host=db port=3306 user=cube_rw password=<PW> database=analytics' \
  | sudo tee /etc/sightmetrics/cube_dsn.env
sudo chmod 640 /etc/sightmetrics/cube_dsn.env
sudo chown root:sightmetrics /etc/sightmetrics/cube_dsn.env
```

`load_cube.sh` und `run_all.sh` lesen automatisch aus `CUBE_DSN_FILE` (Standard:
`/run/secrets/cube_dsn`) wenn `CUBE_DSN` nicht gesetzt ist.

### Secrets-Rotation

`rotate_cube_secret.sh` erneuert das DB-Passwort (`ALTER USER`) **und** schreibt die
DSN-Secret-Datei atomar neu. Weil alle Skripte das DSN bei **jedem** Lauf frisch aus der
Datei lesen, ist die Rotation praktisch unterbrechungsfrei – kein Dienst-Neustart nötig.
Vom alten DSN bleibt ein Backup (`<datei>.bak-<ts>`, Anzahl via `ROTATE_KEEP_BACKUPS`).

```bash
# Ingestion-User (cube_rw) rotieren, Passwort automatisch generieren:
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env \
  ROTATE_ADMIN_USER=root ROTATE_ADMIN_PASSWORD_FILE=/etc/sightmetrics/mariadb_root.pw \
  ./rotate_cube_secret.sh

# Trockenlauf (zeigt maskiertes neues DSN, ändert nichts):
CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env ROTATE_DRY_RUN=1 ./rotate_cube_secret.sh
```

| Variable | Standard | Bedeutung |
|---|---|---|
| `CUBE_DSN_FILE` | – (Pflicht) | Secret-Datei, die neu geschrieben wird |
| `ROTATE_NEW_PASSWORD` | (zufällig) | neues Passwort; sonst via `openssl rand` |
| `ROTATE_USER` / `ROTATE_USER_HOST` | aus DSN / `%` | zu rotierender DB-User |
| `ROTATE_ADMIN_USER` | `root` | Admin mit `ALTER`-Recht |
| `ROTATE_ADMIN_PASSWORD` / `…_FILE` | – | Admin-Passwort (Datei bevorzugt) |
| `ROTATE_KEEP_BACKUPS` | `5` | Anzahl alter DSN-Backups |
| `ROTATE_DRY_RUN` / `ROTATE_SKIP_DB` | – | nur anzeigen / DB nicht ändern (nur Datei) |

Nach dem Setzen verifiziert das Skript den Login mit dem neuen Passwort (`SELECT 1`).
Bei Bedarf als separater, seltener Scheduler-Job (z. B. vierteljährlich) ausführen.

**Reporting-User (`report_ro`):** wird separat rotiert; danach die TYPO3-Connection in
`config/system/additional.php` anpassen (siehe Extension-Handbuch §4). Ein read-only-User
ohne Schreibrechte ist als Backup-Credential ebenfalls geeignet (`BACKUP_DSN`).

---

## 7. Log-Format konfigurieren

Das Ingestion-Skript unterstützt verschiedene Webserver-Log-Formate über die
ENV-Variable `SM_LOG_FORMAT`. Standard ist `combined` (Apache/nginx Combined Log Format).

### Vordefinierte Formate

| `SM_LOG_FORMAT` | Format | Beschreibung |
|---|---|---|
| `combined` *(Standard)* | `IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"` | Apache/nginx Combined Log Format |
| `combined_vhost` | `HOST:PORT IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"` | nginx mit `$host:$server_port`-Präfix |
| `common` | `IP - - [ts] "METHOD URL PROTO" STATUS SIZE` | Common Log Format (ohne Referrer/UA) |
| `custom` | beliebig | Eigener Regex + Timestamp-Format |

### Verwendung

```bash
# combined_vhost (nginx mit Vhost-Präfix)
SM_LOG_FORMAT=combined_vhost ./load_cube.sh /logs/access.log "Behörde A" 1

# oder für alle Sites:
SM_LOG_FORMAT=combined_vhost ./run_all.sh
```

### Custom-Format

Für abweichende Log-Formate können Regex und Timestamp-Format frei definiert werden:

```bash
# Beispiel: ISO 8601-Zeitstempel statt CLF-Format
export SM_LOG_FORMAT=custom
export SM_LOG_REGEX_CUSTOM='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
export SM_TS_FORMAT_CUSTOM='%Y-%m-%dT%H:%M:%S%z'
./load_cube.sh /logs/access.log "Site" 1
```

**Wichtig:** Der Regex muss exakt **8 Capture-Groups** in dieser Reihenfolge liefern:
`(ip)(tsraw)(method)(url)(status)(size)(referrer)(ua)`.
Fehlen Felder (z. B. beim Common-Format), leere Gruppen `()` verwenden.

Der `tsformat`-Wert ist ein `strptime`-Format (DuckDB-Syntax). Häufige Formate:

| Zeitstempel-Beispiel | `SM_TS_FORMAT_CUSTOM` |
|---|---|
| `10/Jan/2026:10:00:00 +0000` (CLF, Standard) | `%d/%b/%Y:%H:%M:%S %z` |
| `2026-01-10T10:00:00+00:00` (ISO 8601) | `%Y-%m-%dT%H:%M:%S%z` |
| `2026-01-10 10:00:00` (ohne TZ, wird als UTC behandelt) | `%Y-%m-%d %H:%M:%S` |

### ENV-Variable setzen

Im Scheduler/Container als Umgebungsvariable übergeben:
```bash
-e SM_LOG_FORMAT=combined_vhost      # docker run / k8s env
```

---

## 8. Inkrementeller Import & Offset-Tracking

`load_cube.sh` importiert **nur neue Bytes** ab dem letzten bekannten Offset:

- **State-Datei** pro Site/Log in `$STATE_DIR/<hash>.offset`: enthält Byte-Offset
  und Inode-Nummer.
- **Log-Rotation**: wird erkannt über Inode-Vergleich. Nach Rotation beginnt der
  Import von Byte 0 der neuen Datei.
- **Idempotenz**: beim Import wird zuerst der Datumsbereich der neuen Daten aus
  der Cube-DB gelöscht (`DELETE WHERE datum BETWEEN ...`), dann die neuen Zeilen
  eingefügt. Wiederholter Import derselben Bytes ist sicher.
- **Offset wird erst nach erfolgreichem Import gesetzt** — bei Abbruch wird beim
  nächsten Lauf der gleiche Bereich erneut importiert.
- **Leer-Batch-Guard**: enthält der neue Bereich 0 gültige Zeilen, wird kein
  INSERT ausgeführt und der Offset nicht verändert.

---

## 9. Scheduling (Wegwerf-Container)

Betriebsmodell: ein externer Scheduler (Kubernetes-CronJob, Docker-/Compose-Scheduler
oder Host-Cron) startet den Ingestion-Container nachts kurz; er importiert alle Sites
(`run_all.sh`) und beendet sich. **Kein systemd im Container.** Details + Beispiele
(Docker-`run`, k8s-CronJob, Pflicht-State-Volume, DSN-Secret, Alarm) in
[`scheduling/README_scheduling.md`](../ingestion/scheduling/README_scheduling.md).

```cron
# Host-Cron-Alternative (eine Zeile, startet den Container)
15 2 * * * docker run --rm -v sightmetrics_state:/state -v /var/log/access:/logs:ro \
  -e STATE_DIR=/state -e PARALLEL=auto -e CUBE_DSN_FILE=/run/secrets/cube_dsn \
  weg3-ingestion run_all.sh >> /var/log/sightmetrics/cron.log 2>&1
```

**Pflicht:** `STATE_DIR` auf ein **persistentes Volume** legen – sonst Voll-Reimport je Lauf.
**Alarm:** Scheduler wertet den Exit-Code aus; `run_all.sh` ruft bei Fehlern zusätzlich
inline `notify.sh` auf (siehe §12). Purge/Backup/Rotation als separate, seltenere
Scheduler-Jobs (§11, §6).

---

## 10. Parallelisierung & Concurrency

`run_all.sh` unterstützt parallele Einzel-Site-Imports über die ENV-Variable `PARALLEL`:

```bash
PARALLEL=4 ./run_all.sh    # 4 gleichzeitige Site-Imports
```

`PARALLEL=auto` erkennt die Kernzahl automatisch (`nproc`).

**Richtwert**: `PARALLEL` = Anzahl CPU-Kerne, maximal so viele, dass
`MaxRSS × PARALLEL < verfügbarer RAM`. MaxRSS pro Import aus dem Benchmark-Log
ablesen (`state/metrics.log`). Für den nächtlichen Lauf weniger Sites reicht der
Default; ein Feintuning der DuckDB-Threads ist nicht nötig.

**Concurrency-Schutz** (zweistufig):
- `run_all.sh` setzt beim Start ein **flock-Lock** (`state/run_all.lock`); ein
  überlappender Lauf endet sofort mit Exit 0.
- `load_cube.sh` setzt zusätzlich ein **Per-Site-Lock** (`state/site_<id>.lock`) – derselbe
  Site-Import kann sich nie überschneiden (schützt Offset-/Meta-Konsistenz).

### Hochverfügbarkeit (HA)

Für den vorgesehenen Betrieb (eine Instanz, ein nächtlicher Lauf) nicht erforderlich.
Die **Cube-DB liegt in eurer MariaDB** und nutzt deren HA-/Backup-Regime mit. Die
Ingestion ist nur ein DB-Client; fällt ein Nachtlauf aus, holt der nächste Lauf
inkrementell auf (bzw. einmalig voll, idempotent per DELETE+INSERT je Datumsbereich).

---

## 11. Retention & Purging

`purge_cube.sh` löscht alle Zeilen aus `cube`, `daily` und `meta`, deren Datum
älter als `RETENTION_MONTHS` Monate ist.

```bash
# Dry-Run: zeigt, wie viele Zeilen gelöscht würden
CUBE_DSN="..." RETENTION_MONTHS=12 PURGE_DRY_RUN=1 ./purge_cube.sh

# Echtes Löschen
CUBE_DSN="..." RETENTION_MONTHS=12 ./purge_cube.sh
```

`RETENTION_MONTHS` als Env im Purge-Job setzen (Standard: 12 Monate). Der Purge-Lauf
ist idempotent und kann jederzeit wiederholt werden. Empfehlung: Purge als eigener,
seltener Scheduler-Job (z. B. monatlich), nicht im nächtlichen Import.

**Rollback**: Siehe [§17 Rollback](#17-rollback).

### Backup als Rollback-Punkt (vor dem Purge)

`backup_cube.sh` erstellt einen `mysqldump` der Cube-Tabellen mit Rotation. Empfehlung:
im **Purge-Job direkt vor** `purge_cube.sh` ausführen (erst sichern, dann löschen):

```bash
BACKUP_DIR=/state/backups ./backup_cube.sh && RETENTION_MONTHS=12 ./purge_cube.sh
```

> Liegt der Cube in **eurer** ohnehin gesicherten MariaDB, ist dies nur der gezielte
> Rollback-Punkt unmittelbar vor dem Löschen – das reguläre DB-Backup deckt den Rest ab.

```bash
# Manuelles Backup (read-only-User wie report_ro genügt zum Dumpen)
CUBE_DSN="..." BACKUP_DIR=/var/backups/sightmetrics ./backup_cube.sh

# Dry-Run (zeigt Ziel/Konfig, schreibt nichts)
CUBE_DSN="..." BACKUP_DRY_RUN=1 ./backup_cube.sh
```

**Konfiguration (alles über Env, z. B. in `/etc/sightmetrics/backup.env`):**

| Variable | Standard | Bedeutung |
|---|---|---|
| `BACKUP_ENABLED` | `1` | Backup an/aus (`0` = sauberer No-op) |
| `BACKUP_DIR` | `../backups` | Zielverzeichnis |
| `BACKUP_RETENTION` | `14` | Anzahl vorzuhaltender Dumps (`0` = nie löschen) |
| `BACKUP_TABLES` | `meta daily cube` | Zu sichernde Tabellen (leer = ganze DB) |
| `BACKUP_COMPRESS` | `gzip` | `gzip` \| `zstd` \| `none` |
| `BACKUP_PREFIX` | `cube` | Dateinamen-Präfix |
| `BACKUP_DSN` / `BACKUP_DSN_FILE` | (Fallback `CUBE_DSN`) | eigene Backup-Credentials |
| `MYSQLDUMP` / `BACKUP_EXTRA_ARGS` | `mysqldump` / – | Binary bzw. Zusatzargumente |

Wiederherstellung: siehe [§17 Rollback](#17-rollback) (Dump entpacken und einspielen).

---

## 12. Monitoring & Alerting

Im Wegwerf-Container-Modell kommt das Monitoring aus zwei Quellen:

**1. Import-Fehler (sofort):** Der Scheduler wertet den **Exit-Code** von `run_all.sh`
aus (≠0 = mind. eine Site fehlgeschlagen → CronJob-`backoffLimit` / Cron-`MAILTO`).
Zusätzlich ruft `run_all.sh` bei Fehlern **inline `notify.sh`** auf (E-Mail/Webhook),
sofern ein Kanal konfiguriert ist:

| Variable | Standard | Bedeutung |
|---|---|---|
| `ALERT_EMAIL` | – | Empfänger (kommagetrennt); leer = kein Mail |
| `ALERT_MAIL_FROM` | `sightmetrics@<host>` | Absender |
| `ALERT_WEBHOOK` | – | Webhook-URL; leer = kein Webhook |
| `ALERT_WEBHOOK_FORMAT` | `slack` | `slack` \| `teams` \| `json` |
| `ALERT_MIN_LEVEL` | `WARN` | ab welchem Level gesendet wird (`OK`/`WARN`/`CRIT`) |
| `ALERT_PREFIX` | `[SightMetrics]` | Betreff-/Text-Präfix |

```bash
# Alarm-Kanal testen (ohne echten Vorfall):
ALERT_EMAIL=ops@example.org ./notify.sh CRIT "Testalarm"
ALERT_WEBHOOK=https://hooks.slack.com/... ./notify.sh WARN "Testalarm"
```

**1b. Heartbeat / ausbleibender Lauf:** `notify.sh` alarmiert nur bei einem *aktiven*
Fehler innerhalb eines Laufs – merkt aber nichts, wenn der Scheduler den Lauf gar
nicht erst startet (Cron/CronJob defekt, Container crasht vor dem Start, …). Dafür
optional ein **Healthcheck-Ping** (z. B. [healthchecks.io](https://healthchecks.io/)
oder selbstgehostet) in `run_all.sh` **und** `fetch_loki_logs.sh`: Start-, Erfolgs-
und Fehler-Ping (mit Log-Auszug als Body). Bleibt der Ping aus, alarmiert
healthchecks.io von selbst.

```bash
export HEALTHCHECK_URL="https://hc-ping.com/<uuid>"   # oder HEALTHCHECK_URL_FILE
```

Leer/nicht gesetzt = deaktiviert (No-op), Ping-Fehler brechen den Import nicht ab
(nur Warnung auf stderr). Siehe `ingestion/lib_healthcheck.sh`.

**2. Freshness (lief der Import überhaupt?):** aus der **dauerhaft laufenden** TYPO3-
Instanz prüfen – `sightmetrics:health` prüft den Lesepfad der GUI (Cube erreichbar +
Aktualität von `meta.bis` je Site):

```bash
vendor/bin/typo3 sightmetrics:health --warn-hours=26 --crit-hours=50        # Text
vendor/bin/typo3 sightmetrics:health --json                                  # für Agenten
# Exit-Codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
```

Per TYPO3-Scheduler oder externem Monitoring (Uptime-Check) takten.

**Außerdem im Blick behalten:** MariaDB-Verbindung (eigenes DB-Monitoring),
Cube-DB-Wachstum (Tabellengröße), letztes Backup (`state/backup.last`),
`state/metrics.log` (Laufzeiten/Bytes je Lauf).

---

## 13. Log-Rotation

Im Wegwerf-Container schreiben die Skripte nach **stdout/stderr** – Log-Aufbewahrung
und Rotation übernimmt der Orchestrator (Docker-/k8s-Logging, journald des Host-Cron).
Persistente Run-Logs unter `LOG_DIR` (falls gesetzt) ggf. über die normale Host-
Logrotation des Log-Volumes abdecken. Die Erkennung **rotierter Webserver-Logs**
(Quelle) erfolgt automatisch über Inode-Vergleich im Offset-Tracking (§8).

---

## 14. Multi-Site (eine Instanz, mehrere Sites)

Betriebsfall: **eine** TYPO3-Instanz mit mehreren Sites in **einem** Namespace, Cube
in **eurer** MariaDB. Alle Sites liegen in einer `analytics`-DB, unterschieden durch
`site_id`.

`sites.conf` enthält alle Sites; `run_all.sh` importiert sie (seriell oder mit
`PARALLEL`). Jede Site hat ihre eigene `state/<hash>.offset`-Datei. In TYPO3 ordnet
`sightmetrics_site_id` in der jeweiligen Site-Config die TYPO3-Site der Cube-`site_id`
zu (siehe Extension-Handbuch §5); die GUI zeigt die Site-Auswahl entsprechend.

> Eine Mandanten-/DB-Isolation über getrennte Datenbanken ist für diesen Single-
> Instance-Betrieb **nicht nötig** und wurde bewusst nicht eingebaut.

<!-- entfernt: Mandanten-Isolation (Variante A/B) – nicht für Single-Instance-Betrieb -->

---

## 15. Fehler-Runbook & Recovery

### Import schlägt fehl (Exit ≠ 0)

```bash
# 1. Letzten Lauf prüfen (Container-Logs des Schedulers)
docker logs <container>            # bzw. kubectl logs job/<name>
# oder das persistente Run-Log (falls LOG_DIR gesetzt):
tail -200 "$LOG_DIR"/run_<DATUM>.log

# 2. Manuell nachimportieren
CUBE_DSN="..." ./load_cube.sh /logs/site1/access.log "Behörde A" 1

# 3. Wenn MariaDB nicht erreichbar war: Import einfach wiederholen.
#    Idempotenz (DELETE + INSERT) stellt Konsistenz sicher.
```

### Offset-State beschädigt / falsch

```bash
# State-Datei für eine Site löschen → nächster Import beginnt von Byte 0
rm /var/lib/sightmetrics/state/<hash>.offset

# Dann: Daten dieser Site für den betroffenen Zeitraum aus Cube-DB löschen
mysql -u cube_rw -p analytics \
  -e "DELETE FROM cube  WHERE site_id = 1 AND datum >= '2026-01-01';
      DELETE FROM daily WHERE site_id = 1 AND datum >= '2026-01-01';
      DELETE FROM meta  WHERE site_id = 1 AND datum >= '2026-01-01';"

# Import neu starten
CUBE_DSN="..." ./load_cube.sh /logs/site1/access.log "Behörde A" 1
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

# Retention verkürzen (z. B. auf 6 Monate) und Purge anstoßen
CUBE_DSN="..." RETENTION_MONTHS=6 ./purge_cube.sh
```

### Doppelter Import (gleicher Zeitraum)

Ist sicher: `cube_to_mysql.sql` löscht vor dem INSERT den betroffenen Datumsbereich
(`DELETE WHERE datum BETWEEN ...`). Ergebnis ist identisch mit einem Einzelimport.

---

## 16. Datenschutz & BSI-Hinweise

### IP-Adressen

- Rohe IP-Adressen werden **nicht in der Cube-DB gespeichert**.
- Für GeoIP und Unique-Visitor-Zählung wird ein **Tages-Salt-Hash** berechnet:
  `MD5(ip + tagessalt)` — reversierungsresistent und innerhalb eines Tages konsistent.
- `tagessalt` wird täglich neu gewürfelt (DuckDB, beim Import).
- Für strengere Anforderungen: IP vor dem Import kürzen (letztes Oktett auf 0 setzen).

### PII in URLs und Referrern

- URLs werden unverändert gespeichert. Query-Parameter mit PII (Tokens, Namen,
  E-Mails) vor dem Import herausfiltern oder maskieren:
  ```bash
  # Beispiel: Query-Parameter 'token' und 'email' entfernen
  sed -E 's/[?&](token|email)=[^& "]*/\1=REMOVED/g' access.log | ./load_cube.sh - "Site" 1
  ```

### Übertragung der Logs

- Logs dürfen nur verschlüsselt übertragen werden (TLS/SSH/SFTP).
- Least-Privilege: der Import-User auf dem Webserver darf nur lesen, nicht schreiben.
- Aufbewahrungsfristen der Roh-Logs: mit Datenschutzbeauftragten abklären;
  Cube-DB: via `RETENTION_MONTHS` konfigurieren.

### BSI-Grundschutz-Relevanz

- `cube_rw` und `report_ro` strikt trennen (kein Schreibzugriff für die Extension).
- DB-Verbindungen verschlüsseln (MariaDB: `ssl=true` in DSN, falls externer Host).
- Secrets nie in Skripten oder SCM; immer aus Env-Var oder Secret-Datei.
- Audit-Logs des Import-Hosts und der MariaDB aktivieren.

---

## 17. Rollback

Wenn ein fehlerhafter Import rückgängig gemacht werden soll:

```bash
# Option A: Zeitraum gezielt löschen (empfohlen)
mysql -u cube_rw -p analytics -e "
  DELETE FROM cube  WHERE site_id = <ID> AND datum BETWEEN '<VON>' AND '<BIS>';
  DELETE FROM daily WHERE site_id = <ID> AND datum BETWEEN '<VON>' AND '<BIS>';
  DELETE FROM meta  WHERE site_id = <ID> AND datum >= '<VON>';"
# meta wird beim nächsten Import aus der vollständigen daily-Tabelle neu berechnet.

# Dann: State-Offset zurücksetzen und erneut importieren
rm /var/lib/sightmetrics/state/<hash>.offset
CUBE_DSN="..." ./load_cube.sh /logs/site<ID>/access.log "Site-Name" <ID>

# Option B: Vollständiges Backup einspielen (wenn vorhanden)
mysql -u root -p analytics < backup_analytics_YYYYMMDD.sql
```

**Empfehlung**: Tägliche MariaDB-Backups (`mysqldump analytics`) vor dem Import-Fenster
anlegen. `cube_to_mysql.sql` ist idempotent; ein erneuter Import überschreibt
fehlerhafte Daten korrekt.

---

## 18. Wichtige ENV-Variablen

| Variable | Standard | Beschreibung |
|---|---|---|
| `CUBE_DSN` | – | MariaDB-DSN (Pflicht, wenn `CUBE_DSN_FILE` nicht gesetzt) |
| `CUBE_DSN_FILE` | `/run/secrets/cube_dsn` | Alternative: DSN aus Datei (K8s Secrets) |
| `SM_LOG_FORMAT` | `combined` | Log-Format: `combined`, `combined_vhost`, `common`, `custom` |
| `SM_LOG_REGEX_CUSTOM` | – | Regex für `SM_LOG_FORMAT=custom` (8 Capture-Groups) |
| `SM_TS_FORMAT_CUSTOM` | – | strptime-Format für `SM_LOG_FORMAT=custom` |
| `SM_GEO_SOURCE` | `native` | GeoIP-Quelle: `native`, `ip2location`, `dbip`, `maxmind` (siehe §3a) |
| `SM_GEO_PATH` | `geo/country-ipv4-num.csv` | Pfad zur Geo-CSV (Datei selbst beschaffen, s. §3a) |
| `SM_GEO_LOC_PATH` | `geo/GeoLite2-Country-Locations-en.csv` | nur `SM_GEO_SOURCE=maxmind`: Locations-Datei |
| `SM_TABLE_CUBE` | `cube` | Tabellenname Cube (für abweichende Tabellennamen) |
| `SM_TABLE_DAILY` | `daily` | Tabellenname Daily |
| `SM_TABLE_META` | `meta` | Tabellenname Meta |
| `RETENTION_MONTHS` | `12` | Haltezeit für Purge (positive ganze Zahl) |
| `PURGE_DRY_RUN` | *(nicht gesetzt)* | Gesetzt: nur zählen, nicht löschen |
| `PARALLEL` | `1` | Parallele Import-Jobs (`xargs -P` in `run_all.sh`) |
| `STATE_DIR` | `../state/` | Offset-State + Lock + Metriken |
| `LOG_DIR` | `../logs/import-logs/` | Import-Logs |
| `SITES_CONF` | `./sites.conf` | Pfad zur Site-Liste |
| `ALERT_EMAIL` / `ALERT_WEBHOOK` | – | Alarm-Kanäle für `notify.sh` (inline in `run_all.sh`) |
| `HEALTHCHECK_URL` / `_FILE` | – | Heartbeat-Ping (healthchecks.io o.ä.); leer = deaktiviert (§12) |
| `LOKI_URL` / `LOKI_QUERY` | – | `fetch_loki_logs.sh`: Loki-Basis-URL + LogQL-Selector (Pflicht dort) |
| `LOKI_NAMESPACE` | – | `fetch_loki_logs.sh`: Bequemlichkeits-Filter (Label-Matcher) |
| `LOKI_ORG_ID` | – | `fetch_loki_logs.sh`: `X-Scope-OrgID` (Loki Multi-Tenant) |
| `LOKI_LIMIT` / `LOKI_LOOKBACK_HOURS` / `LOKI_SAFETY_SECONDS` | `5000` / `24` / `30` | `fetch_loki_logs.sh`: Pagination/Erstlauf/Sicherheitsabstand |
