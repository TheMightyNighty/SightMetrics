> 🇬🇧 [English version](README.md)

# SightMetrics – datenschutzfreundliche Webzugriffsanalyse

SightMetrics wertet **Webserver-Logs** (Apache/nginx) aus und stellt die
Ergebnisse als Dashboard in einem **TYPO3-Backend-Modul** dar — kein
JavaScript-Tracker, keine Cookies, Besucherdaten verlassen niemals das
eigene System.

Statt jeden einzelnen Seitenaufruf über eine Tracking-API zu erfassen (wie
es z. B. Matomo tut), liest SightMetrics die ohnehin vorhandenen Logdateien
ein, reduziert sie **einmalig mit [DuckDB](https://duckdb.org/)** auf
kompakte Tagesaggregate ("Cubes") und speichert nur diese in einer
Datenbank. Das ist schnell, ressourcenschonend und **datenschutzfreundlich**
— eine Architektur, die sich besonders für den Einsatz in Behörden und im
öffentlichen Sektor eignet (DSGVO/BSI).

---

## Funktionsweise (in einem Bild)

```
   Apache/nginx          Paket A: Ingestion (DuckDB)                MariaDB           Paket B: TYPO3-Extension
   ─────────────         ───────────────────────────────           ─────────         ──────────────────────────
   access.log    ──────► parse → sessionize → aggregate ─────────► cube DB   ◄────── Backend-Modul "Web Analytics"
   (Rohzeilen)           (load_cube.sh / transform.sql)          (cube/daily/meta)   (nur lesend, rendert Charts)
                              ▲
   Matomo (Altdaten) ─────────┘
   Reporting-API (JSON)   matomo_import.sh  (einmaliger Import historischer Daten)
```

- **Paket A schreibt** den Cube (DB-Benutzer `cube_rw`), **Paket B liest nur**
  (`report_ro`, nur `SELECT`).
- Die beiden Pakete teilen sich **keinen Code**, nur die Datenbank — eine
  bewusste architektonische Grenze (Konzept §11).

---

## Kernbegriffe

| Begriff | Bedeutung |
|---|---|
| **Cube** | Vorberechnete Analysedaten in MariaDB. Tabelle `cube(site_id, datum, dim, parent, dimkey, pv, v)`: Seitenaufrufe (`pv`) und Besuche (`v`) pro Tag, pro Dimension, pro Wert; `parent` enthält den übergeordneten Wert für Drill-down-Dimensionen. `datum` wird in der Zeitzone der Site gebündelt (`meta.tz`). |
| **Dimension (`dim`)** | Eine Analyseachse, z. B. `url`, `country`, `browser`, `os`, `device`, `referrer_type`, `keyword`, `hour`, `entry`/`exit`, `download`, `status`, `method`. |
| **`daily` / `meta`** | Tägliche Kennzahlen (Besuche, Seitenaufrufe, eindeutige Besucher, Absprünge, Bytes) bzw. übergreifende Metadaten je Site. |
| **Sessionisierung** | Gruppierung einzelner Zugriffe zu Besuchen, basierend auf IP+User-Agent und 30 Minuten Inaktivität — geschieht in DuckDB, nicht in der Datenbank. |
| **Site / `site_id`** | Eine analysierte Website. Mehrere Sites mit unterschiedlichen `site_id`s leben in **einer** Cube-DB (Multi-Site). |
| **Schema-Contract** | Die Cube-Tabellen sind die einzige Schnittstelle zwischen den beiden Paketen. Der Contract ist versioniert (`meta.schema_version`) und normativ dokumentiert in [`docs/SCHEMA.de.md`](docs/SCHEMA.de.md); die Extension prüft die Version beim Start. |

---

## Repository-Struktur

| Pfad | Inhalt |
|------|--------|
| `ingestion/` | **Paket A – Ingestion/Auswertung (DuckDB)**, der operative Teil. Log-Parser, Aggregations-SQL, Import-Skripte, GeoIP-Daten, das DuckDB-Binary. Alleiniger Schreiber der Cube-DB. → [`ingestion/README.de.md`](ingestion/README.de.md) |
| `extension/` | **Paket B – TYPO3-Reporting-Extension** `sight_metrics`. Read-Only-Backend-Modul, kein DuckDB. → [`extension/README.md`](extension/README.md) |
| `demo/` | **Wegwerf-Stack** zum Ausprobieren: TYPO3 v13 + MariaDB (Cube-DB) via Docker Compose. Nicht für den Produktivbetrieb. |
| `docs/` | Detaildokumentation: [Extension-Handbuch](docs/extension-handbuch.de.md) (Entwicklung/Administration) · [Ingestion-Runbook](docs/ingestion-runbook.md) (Betrieb) · [Matomo-Import](docs/matomo-import.md). |
| `logs/` | Beispiel-/Test-Logs. |

---

## Schnellstart (Demo)

Voraussetzungen: Docker + Docker Compose, Bash, `curl`/`unzip`, Python 3.
Kein lokales PHP/Composer/Apache nötig — TYPO3 läuft im Container über den
eingebauten PHP-Dev-Server, Composer läuft ebenfalls containerisiert.

```bash
# 1) Stack starten. TYPO3 installiert sich beim ersten Start selbst
#    (composer install, nicht-interaktives Setup) über den Entrypoint
#    des Web-Containers.
docker compose -f demo/docker-compose.yaml up -d

# 2) Beispiel-Log importieren: Log -> DuckDB-Cube -> MariaDB
docker exec -it sightmetrics-ingestion bash
# innerhalb des Containers:
python3 generate_demo_geo.py -o geo/country-ipv4-num.csv

# 2a) Dateibasierte Logs
./generate_logs.py
./load_cube.sh logs/example_1k.log "Sample Authority" 1
# ./load_cube.sh <logdatei> "<site-name>" <site_id>
# (multi-site-fähig, idempotent pro Site)

# 2b) Loki-Logs
python3 generate_loki_logs.py --loki-url http://loki:3100 --label "namespace=foo" --hours $(( 24 * 14 )) --num $(( 10000 * 14 ))
SM_LOG_FORMAT=json_ecs ./fetch_loki_logs.sh --url http://loki:3100 --query '{job="nginx", namespace="foo"}' --site-id 1 --site-name "Authority A" --lookback-days 14

# 3) Im Backend ansehen:
#    http://localhost:8091/typo3/   (admin / SightMetrics-Admin-2026!)
#    -> Modul  Web > "Web Analytics"
```

Für den **Produktivbetrieb** siehe
[`ingestion/scheduling/README_scheduling.md`](ingestion/scheduling/README_scheduling.md)
und das [Ingestion-Runbook](docs/ingestion-runbook.md). Dazu gehören:
ein gehärtetes Container-Image (non-root UID 10001,
`readOnlyRootFilesystem`-fähig), vollständige **Kubernetes-Manifeste**
(`ingestion/scheduling/k8s/`, CronJob nach Pod-Security-Standard
"restricted"), **Prometheus**-Metriken (node_exporter-Textfile-Format)
sowie Secret-Rotation, Backup und Aufbewahrung.

---

## Import von Matomo-Altdaten

Eine Migration von Matomo erlaubt es, **einmalig pro Site historische Daten**
zu übernehmen — über die Matomo-Reporting-API, ohne Rohlogs. Funktioniert
selbst dann, wenn Matomos rohe Tracking-Daten bereits gelöscht sind, und
skaliert auch für Sites mit Millionen Zugriffen pro Tag:

```bash
cd ingestion
export MATOMO_TOKEN="…"   # View-Token aus Matomo
export CUBE_DSN="host=… user=cube_rw password=… database=analytics"
./matomo_import.sh --url https://matomo.example.org --matomo-idsite 7 \
                   --site-id 1 --site-name "Sample Authority" \
                   --from 2020-01-01 --to 2024-12-31
```

Details, Mapping und Einschränkungen: [`docs/matomo-import.md`](docs/matomo-import.md).

---

## Funktionsumfang des Dashboards

- **Trend** über die Zeit, **Weltkarte** (Choroplethen) und Länderliste
- **Besuchszeiten** (stündliche Heatmap), **Browser/OS/Gerät** mit
  **Drill-down** (→ Versionen/Modelle)
- **Referrer**-Typen und -URLs, **Suchbegriffe**
- **Einstiegs-/Ausstiegsseiten**, **Downloads**, **Statuscodes**,
  **HTTP-Methoden**, **Seitenbaum-Drill-down**
- **KPIs** einschließlich Absprungrate und Bandbreite
- **Zeitraum-Auswahl** (ein Matomo-artiges Dropdown: relativ / Kalender /
  einzelne Jahre / individuell), **Zeitraumvergleich**
- **CSV- und PDF-Export**, **Dark Mode**, vollständige **Lokalisierung**
  (Englisch/Deutsch)
- **Bot-/Crawler-Filter** — es werden nur menschliche Besucher gezählt;
  Statuscodes zeigen zur Fehlerdiagnose zusätzlich 4xx/5xx
- **Anonymisierung beim Import** — bei IPv4-Adressen wird das letzte Oktett
  entfernt, IPv6 wird auf `/48` gekürzt, und Query-Strings werden sowohl aus
  der aufgerufenen URL *als auch* aus dem Referrer verworfen, bevor überhaupt
  etwas aggregiert wird. Kein Schalter: kein Query-Parameter erreicht den Cube
  (siehe
  [Runbook §16](docs/ingestion-runbook.de.md#16-datenschutz--bsi-hinweise))

Datenqualität und Robustheit der Ingestion (jeweils zu- und abschaltbar/optional):

- **Bot- und Browser-/OS-Erkennung**, optional basierend auf
  [matomo/device-detector](https://github.com/matomo-org/device-detector)
  (Matomo-vergleichbar, `tools/fetch_bot_list.sh` / `tools/fetch_ua_lists.sh`)
  — ohne diese Listen kommt stattdessen eine eingebaute UA-Heuristik zum
  Einsatz.
- **IPv6-robust**: IPv6-Adressen werden gezählt; mit einem optionalen
  v6-Geo-Datensatz (`SM_GEO6_PATH`) werden sie zusätzlich einem Land
  zugeordnet.
- **Lokale Tagesgrenzen** (`SM_TZ`) und ein **Tagesgrenzen-Cut** (kein
  Datenverlust an der Tagesgrenze; ein Tag erscheint erst, wenn er
  vollständig ist).

---

## Multi-Site

Der Cube trägt eine `site_id`; mehrere Sites leben gemeinsam in einer
Cube-DB, das Dashboard bietet eine Site-Auswahl. Das Mapping **TYPO3-Site →
Cube-`site_id`** erfolgt über `sightmetrics_site_id` in der
TYPO3-Site-Konfiguration. Ausgelegt für **eine** TYPO3-Instanz mit mehreren
Sites in einem gemeinsamen Namespace (Cube in derselben MariaDB).

---

## Entwicklung & Tests

```bash
./run-tests.sh            # Lint + alle Testsuiten (Ingestion-Pipeline + Extension)
extension/lint.sh         # nur Lint: PHPStan Level max + strict-rules + TYPO3-Coding-Standards
```

Tests laufen auf mehreren Ebenen (alle in CI, siehe `.github/workflows/ci.yml`):
DuckDB-Pipeline-Suite, PHP Unit/Functional (TYPO3 13.4/14 × PHP 8.2–8.4),
JavaScript-Typcheck (`tsc --checkJs`) + jsdom-Smoke-Test, ein
**Contract-Test** (Ingestion schreibt → Extension liest, gegen eine echte
MariaDB) und ein **E2E**-Lauf (Puppeteer gegen das echte TYPO3-Backend).

Der Extension-Quellcode (`extension/sight_metrics/`) wird live in den
Demo-Stack gebindmountet (siehe `demo/docker-compose.yaml`) — Änderungen
sind sofort im laufenden Container sichtbar, kein Kopier-/Sync-Schritt
nötig.

---

## Technologie-Stack

TYPO3 v13.4 LTS / v14 · PHP 8.2–8.4 · DuckDB 1.5.4 (statisches Binary in
`ingestion/bin/`) · MariaDB · [Chart.js](https://www.chartjs.org/)
(Trend-/Stunden-Chart) · [Leaflet](https://leafletjs.com/) (Besucherkarte).
Das Frontend des Backend-Moduls besteht aus nativen ES-Modulen (kein
Build-Schritt), geladen über TYPO3s `JavaScriptModules.php`.

---

## Release

1. Version in `extension/sight_metrics/ext_emconf.php`, im `<project>`-Release
   von `Documentation/guides.xml` und in der `CHANGELOG.md`-Überschrift
   anheben, danach `./run-tests.sh` laufen lassen.
2. Taggen: `git tag -a v2.1.0 -m "SightMetrics 2.1.0" && git push --tags`.

Der Tag startet zwei Workflows: `image.yml` baut das Ingestion-Image und
schiebt es nach GHCR, `ter.yml` veröffentlicht die Extension im TER. Der
TER-Job prüft zuerst den Tag gegen `ext_emconf.php` und das CHANGELOG und
überspringt sich selbst (ohne Fehler), solange das Repository-Secret
`TYPO3_API_TOKEN` fehlt. Vorausgesetzt werden der auf extensions.typo3.org
registrierte Extension-Key `sight_metrics` und ein typo3.org-Access-Token mit
dem Scope `extension:write`.

## Versionierung & Upgrades

Die Extension folgt SemVer; die Cube-DB trägt eine eigene Schema-Version
(`meta.schema_version`, Contract in [`docs/SCHEMA.de.md`](docs/SCHEMA.de.md)).

> **Upgrade auf 2.0 (breaking):** Version 2.0 ändert den DB-Contract
> (lokale Tagesgrenzen, `cube.parent`-Spalte statt kodierter Schlüssel,
> neutrale `referrer_type`-Werte). Bestehende Cube-DBs einmalig migrieren —
> `mysql … analytics < ingestion/migrations/v1_to_v2.sql` (idempotent) —
> oder neu importieren. Extension 2.x verweigert ältere Daten mit einer
> klaren Meldung.
> Details: [`docs/SCHEMA.de.md`](docs/SCHEMA.de.md) und
> [`CHANGELOG`](extension/sight_metrics/CHANGELOG.md).
