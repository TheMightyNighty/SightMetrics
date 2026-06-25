# SightMetrics – effiziente Logauswertung ohne Matomo-Import

Prototyp zum Konzept in [`loganalyse-gruene-wiese.md`](loganalyse-gruene-wiese.md):
Webserver-Logs werden mit **DuckDB** (Heavy Lifting in C) geparst, sessionisiert und zu
**Cubes** aggregiert – statt sie zeilenweise über Matomos Tracker-API zu importieren.
Auswertung als **TYPO3-Backend-Extension**, die read-only auf die Cube-DB liest.

## Struktur (zwei Pakete + Demo)

| Pfad | Was |
|------|-----|
| `ingestion/` | **Paket A – Auswertung/Import (DuckDB)**, der *betriebliche* Teil. Generator, `cube_to_mysql.sql` (wertet die Logs aus), `load_cube.sh`, `bin/duckdb`, `geo/`. Einziger Schreiber der Cube-DB. |
| `extension/` | **Paket B – TYPO3-Reporting-Extension** `sight_metrics`. Liest nur (`report_ro`), kein DuckDB. |
| `demo/` | **Wegwerf-Stack**: TYPO3 v13 + MariaDB (Cube-DB), zum Testen. Nicht für Produktion. |
| `docs/` | **Dokumentation**: [Extension-Handbuch](docs/extension-handbuch.md) (Entwickler/Admin) · [Ingestion-Runbook](docs/ingestion-runbook.md) (Ops/Betrieb). |
| `logs/` | Test-Logs. |

## Schnellstart

```bash
# 1) Demo-Stack hoch (MariaDB + TYPO3 v13, Extension ist installiert)
cd demo && docker compose up -d && cd ..

# 2) Import/Auswertung: Log -> DuckDB-Cube -> MariaDB
cd ingestion && ./load_cube.sh ../logs/example_1k.log "Bürgeramt Mitte" 1 && cd ..
#                ./load_cube.sh <log> "<Site-Name>" <site_id>   (Multi-Site, idempotent pro Site)

# 3) Backend ansehen
#    http://localhost:8091/typo3/   (admin / Weg3-Admin-2026!)  ->  Web -> "Logauswertung"
```

Import auch als **Container** (Paket A, nächtlicher one-shot). Standardlauf = alle Sites aus
`sites.conf`; Einzelimport via `load_cube.sh`:
```bash
# alle Sites
cd demo && docker compose --profile import run --rm ingestion
# Einzelimport
cd demo && docker compose --profile import run --rm ingestion load_cube.sh /logs/<datei> "Site-Name" <id>
```
Betrieb produktiv: siehe [`ingestion/scheduling/README_scheduling.md`](ingestion/scheduling/README_scheduling.md)
(CronJob/Cron, persistentes `STATE_DIR`-Volume, DSN als Laufzeit-Secret, Alarm).

Tests (Lint + alle Suiten): `./run-tests.sh` · nur Lint: `extension/lint.sh` (PHPStan 2 + TYPO3
Coding Standards). Extension neu deployen: `extension/sync-to-demo.sh`.

GUI-Umfang: Verlauf, **Weltkarte (Choropleth)**, Länder, Besuchszeiten, Browser/OS/Gerät
**mit Drill-down** (→ Versionen/Modelle), Referrer-Typen/-URLs, **Suchbegriffe**, Ein-/Ausstieg,
Downloads, Statuscodes, HTTP-Methoden, Seitenbaum-Drill-down, KPIs (inkl. Absprungrate/Bandbreite),
**Zeitraum-Auswahl** (Matomo-artiges Dropdown: relativ/Kalender/Jahre + benutzerdefiniert),
**Perioden-Vergleich**, **CSV-/PDF-Export** und **Dark Mode**.

> Architektur-Grenze (Konzept §11): Paket A schreibt den Cube (`cube_rw`), Paket B liest nur
> (`report_ro`, SELECT). `demo/app/` ist das temporäre TYPO3 (kein Paket-Bestandteil).

**Multi-Site:** Der Cube trägt `site_id`; mehrere Sites liegen in einer DB, die GUI hat eine
Site-Auswahl. Zuordnung TYPO3-Site → Cube-`site_id` über `sightmetrics_site_id` in der Site-Config.
Ausgelegt für **eine** TYPO3-Instanz mit mehreren Sites in einem Namespace (Cube in derselben MariaDB).

## Stack

TYPO3 v13.4 LTS / v14 · PHP 8.2–8.4 · DuckDB 1.5.4 · MariaDB · ECharts (Backend-Modul).
