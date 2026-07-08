# SightMetrics – datensparsame Webzugriffs-Auswertung

SightMetrics wertet **Webserver-Logs** (Apache/nginx) aus und stellt die Ergebnisse
als Dashboard in einem **TYPO3-Backend-Modul** dar – ohne JavaScript-Tracker, ohne
Cookies, ohne dass Besucherdaten das eigene System verlassen.

Statt jeden einzelnen Seitenaufruf über eine Tracking-API zu erfassen (wie z. B.
Matomo es tut), liest SightMetrics die ohnehin vorhandenen Logdateien, rechnet sie
**einmalig mit [DuckDB](https://duckdb.org/)** zu kompakten Tages-Aggregaten
(„Cubes") herunter und legt nur diese in einer Datenbank ab. Das ist schnell,
ressourcenschonend und **datenschutzfreundlich** – ein Entwurf, der besonders für
Behörden und den öffentlichen Sektor (DSGVO/BSI) gedacht ist.

---

## Wie es funktioniert (in einem Bild)

```
   Apache/nginx          Paket A: Ingestion (DuckDB)              MariaDB           Paket B: TYPO3-Extension
   ─────────────         ────────────────────────────            ─────────         ────────────────────────
   access.log    ──────► parse → sessionisieren → aggregieren ──► Cube-DB   ◄────── Backend-Modul "Logauswertung"
   (Rohzeilen)           (load_cube.sh / transform.sql)          (cube/daily/meta)   (liest nur, rendert Charts)
                              ▲
   Matomo (Altdaten) ─────────┘
   Reporting-API (JSON)   matomo_import.sh  (einmaliger Import der Vergangenheit)
```

- **Paket A schreibt** den Cube (DB-User `cube_rw`), **Paket B liest nur** (`report_ro`, ausschließlich `SELECT`).
- Die beiden Pakete teilen sich **keinen Code**, nur die Datenbank – eine bewusste Architektur-Grenze (Konzept §11).

---

## Zentrale Begriffe

| Begriff | Bedeutung |
|---|---|
| **Cube** | Vorab aggregierte Auswertungsdaten in der MariaDB. Tabelle `cube(site_id, datum, dim, parent, dimkey, pv, v)`: pro Tag, pro Dimension, pro Ausprägung die Pageviews (`pv`) und Visits (`v`); `parent` trägt bei Drill-down-Dimensionen den Elternwert. `datum` ist in der Site-Zeitzone (`meta.tz`) gebucketet. |
| **Dimension (`dim`)** | Auswertungsachse, z. B. `url`, `country`, `browser`, `os`, `device`, `referrer_type`, `keyword`, `hour`, `entry`/`exit`, `download`, `status`, `method`. |
| **`daily` / `meta`** | Tageskennzahlen (Visits, Pageviews, Unique Visitors, Bounces, Bytes) bzw. Gesamt-Metadaten je Site. |
| **Sessionisierung** | Gruppierung von Einzel-Hits zu Besuchen (Visits) anhand von IP+User-Agent und 30-Minuten-Inaktivität – passiert in DuckDB, nicht in der DB. |
| **Site / `site_id`** | Eine ausgewertete Website. Mehrere Sites liegen mit unterschiedlicher `site_id` in **einer** Cube-DB (Multi-Site). |
| **Schema-Vertrag** | Die Cube-Tabellen sind die einzige Schnittstelle zwischen beiden Paketen. Der Vertrag ist versioniert (`meta.schema_version`) und normativ dokumentiert in [`docs/SCHEMA.md`](docs/SCHEMA.md); die Extension prüft die Version beim Start. |

---

## Repository-Aufbau

| Pfad | Inhalt |
|------|--------|
| `ingestion/` | **Paket A – Ingestion/Auswertung (DuckDB)**, der betriebliche Teil. Log-Parser, Aggregations-SQL, Import-Skripte, GeoIP-Daten, das DuckDB-Binary. Einziger Schreiber der Cube-DB. → [`ingestion/README.md`](ingestion/README.md) |
| `extension/` | **Paket B – TYPO3-Reporting-Extension** `sight_metrics`. Read-only-Backend-Modul, kein DuckDB. → [`extension/README.md`](extension/README.md) |
| `demo/` | **Wegwerf-Stack** zum Ausprobieren: TYPO3 v13 + MariaDB (Cube-DB) per Docker Compose. Nicht für Produktion. |
| `docs/` | Ausführliche Dokumentation: [Extension-Handbuch](docs/extension-handbuch.md) (Entwickler/Admin) · [Ingestion-Runbook](docs/ingestion-runbook.md) (Ops/Betrieb) · [Matomo-Import](docs/matomo-import.md). |
| `logs/` | Beispiel-/Test-Logs. |

---

## Schnellstart (Demo)

Voraussetzungen: Docker + Docker Compose, Bash, `curl`/`unzip`, Python 3. Kein
lokales PHP/Composer/Apache nötig – TYPO3 läuft im Container über den eingebauten
PHP-Dev-Server, Composer läuft ebenfalls containerisiert.

`demo/setup.sh` holt/erzeugt einmalig alles, was bewusst **nicht** im Repo liegt
(große Binärdateien, generierte Installationen, lizenzpflichtige Datensätze):
DuckDB-Binary, ein Beispiel-Log, eine synthetische Demo-Geo-CSV (siehe
[Ingestion-Runbook §3a](docs/ingestion-runbook.md#3a-geoip-datensatz-todo-für-betreiber)
für echte GeoIP-Quellen im Produktivbetrieb) sowie die TYPO3-Installation selbst.

```bash
# 1) Einmaliges Setup (dauert beim ersten Mal ein paar Minuten: composer install,
#    TYPO3-Setup, Extension-Deploy). Danach läuft der komplette Stack bereits.
cd demo && ./setup.sh && cd ..

# 2) Beispiel-Log importieren: Log -> DuckDB-Cube -> MariaDB
cd ingestion && ./load_cube.sh ../logs/example_1k.log "Bürgeramt Mitte" 1 && cd ..
#                ./load_cube.sh <Logdatei> "<Site-Name>" <site_id>
#                (multi-site-fähig, idempotent pro Site)

# 3) Im Backend ansehen:
#    http://localhost:8091/typo3/   (admin / SightMetrics-Admin-2026!)
#    -> Modul  Web > "Logauswertung"

# Weitere Terminal-Sessions (Stack schon eingerichtet): nur noch
cd demo && docker compose up -d && cd ..
```

Import als **Container** (Paket A als nächtlicher One-Shot). Standardlauf = alle Sites
aus `sites.conf`:

```bash
# alle Sites importieren
cd demo && docker compose --profile import run --rm ingestion
# einzelne Site
cd demo && docker compose --profile import run --rm ingestion load_cube.sh /logs/<datei> "Site-Name" <id>
```

Für den **produktiven Betrieb** siehe
[`ingestion/scheduling/README_scheduling.md`](ingestion/scheduling/README_scheduling.md)
und das [Ingestion-Runbook](docs/ingestion-runbook.md). Enthalten sind u. a.:
gehärtetes Container-Image (non-root UID 10001, `readOnlyRootFilesystem`-tauglich),
vollständige **Kubernetes-Manifeste** (`ingestion/scheduling/k8s/`, CronJob nach
Pod-Security „restricted"), **Prometheus**-Metriken (node_exporter-Textfile-Format)
sowie Secrets-Rotation, Backup und Retention.

---

## Altdaten aus Matomo übernehmen

Wer von Matomo umsteigt, kann die **historischen Daten einmalig pro Site** übernehmen –
über Matomos Reporting-API, ohne Rohlogs. Funktioniert auch dann, wenn Matomos
Roh-Trackingdaten längst gelöscht sind, und skaliert für Sites mit Millionen Hits/Tag:

```bash
cd ingestion
export MATOMO_TOKEN="…"   # View-Token aus Matomo
export CUBE_DSN="host=… user=cube_rw password=… database=analytics"
./matomo_import.sh --url https://matomo.example.org --matomo-idsite 7 \
                   --site-id 1 --site-name "Bürgeramt Mitte" \
                   --from 2020-01-01 --to 2024-12-31
```

Details, Mapping und Grenzen: [`docs/matomo-import.md`](docs/matomo-import.md).

---

## Funktionsumfang des Dashboards

- **Verlauf** über die Zeit, **Weltkarte** (Choropleth) und Länder-Liste
- **Besuchszeiten** (Stunden-Heatmap), **Browser / Betriebssystem / Gerät** mit **Drill-down** (→ Versionen/Modelle)
- **Referrer**-Typen und -URLs, **Suchbegriffe**
- **Ein-/Ausstiegsseiten**, **Downloads**, **Statuscodes**, **HTTP-Methoden**, **Seitenbaum-Drill-down**
- **KPIs** inkl. Absprungrate und Bandbreite
- **Zeitraum-Auswahl** (ein Matomo-artiges Dropdown: relativ / Kalender / einzelne Jahre / benutzerdefiniert), **Perioden-Vergleich**
- **CSV- und PDF-Export**, **Dark Mode**, vollständige **Lokalisierung** (Englisch/Deutsch)
- **Bot-/Crawler-Filter** – gezählt werden nur menschliche Besucher; Statuscodes zeigen auch 4xx/5xx zur Fehlerdiagnose

Datenqualität und Robustheit der Ingestion (jeweils abschaltbar/optional):

- **Bot- und Browser/OS-Erkennung** wahlweise auf Basis von
  [matomo/device-detector](https://github.com/matomo-org/device-detector)
  (Matomo-vergleichbar, `tools/fetch_bot_list.sh` / `tools/fetch_ua_lists.sh`) –
  ohne diese Listen greift eine eingebaute UA-Heuristik.
- **IPv6-robust**: IPv6-Adressen werden gezählt; mit optionalem v6-Geo-Datensatz
  (`SM_GEO6_PATH`) auch einem Land zugeordnet.
- **Lokale Tages-Buckets** (`SM_TZ`) und **Tagesgrenzen-Cut** (kein Datenverlust
  an der Tagesgrenze; ein Tag erscheint erst nach Abschluss).

---

## Multi-Site

Der Cube trägt eine `site_id`; mehrere Sites liegen gemeinsam in einer Cube-DB, das
Dashboard hat eine Site-Auswahl. Die Zuordnung **TYPO3-Site → Cube-`site_id`** erfolgt
über `sightmetrics_site_id` in der TYPO3-Site-Konfiguration. Ausgelegt für **eine**
TYPO3-Instanz mit mehreren Sites in einem Namespace (Cube in derselben MariaDB).

---

## Entwicklung & Tests

```bash
./run-tests.sh            # Lint + alle Testsuiten (Ingestion-Pipeline + Extension)
extension/lint.sh         # nur Lint: PHPStan level max + strict-rules + TYPO3 Coding Standards
```

Getestet wird auf mehreren Ebenen (alle in der CI, siehe `.github/workflows/ci.yml`):
DuckDB-Pipeline-Suite, PHP-Unit/Functional (TYPO3 13.4/14 × PHP 8.2–8.4),
JavaScript-Typecheck (`tsc --checkJs`) + jsdom-Smoke, ein **Contract-Test**
(Ingestion schreibt → Extension liest, gegen echte MariaDB) und ein **e2e**-Lauf
(Puppeteer gegen das echte TYPO3-Backend).

Die Extension-Quelle (`extension/sight_metrics/`) ist im Demo-Stack per Bind-Mount
live eingebunden (siehe `demo/docker-compose.yml`) – Änderungen sind ohne
Kopier-/Sync-Schritt sofort im laufenden Container sichtbar.

---

## Technologie-Stack

TYPO3 v13.4 LTS / v14 · PHP 8.2–8.4 · DuckDB 1.5.4 (statisches Binary in `ingestion/bin/`) ·
MariaDB · [Chart.js](https://www.chartjs.org/) (Verlaufs-/Stundendiagramm) ·
[Leaflet](https://leafletjs.com/) (Besucherkarte). Das Backend-Modul-Frontend besteht
aus nativen ES-Modulen (kein Build-Schritt), geladen über TYPO3s
`JavaScriptModules.php`.

---

## Versionierung & Upgrade

Die Extension folgt SemVer; die Cube-DB trägt eine eigene Schema-Version
(`meta.schema_version`, Vertrag in [`docs/SCHEMA.md`](docs/SCHEMA.md)).

> **Upgrade auf 2.0 (Breaking):** Version 2.0 ändert den DB-Vertrag (lokale
> Tages-Buckets, `cube.parent`-Spalte statt kodierter Keys, neutrale
> `referrer_type`-Werte). Bestehende Cube-DBs einmalig migrieren –
> `mysql … analytics < ingestion/migrations/v1_to_v2.sql` (idempotent) – oder
> neu importieren. Die Extension 2.x verweigert ältere Daten mit klarer Meldung.
> Details: [`docs/SCHEMA.md`](docs/SCHEMA.md) und
> [`CHANGELOG`](extension/sight_metrics/CHANGELOG.md).
