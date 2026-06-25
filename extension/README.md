# Paket B – TYPO3-Reporting-Extension `sight_metrics`

TYPO3-v13-Backend-Modul „Logauswertung". Liest **ausschließlich read-only** (User `report_ro`,
nur SELECT) die Cube-DB und rendert die Auswertung (Barlisten + Drill-down, Weltkarte, Verlauf,
Seitenbaum). Enthält **kein** DuckDB/Parquet (das ist Paket A).

- Composer-Paket `sightmetrics/sight-metrics` (path-repo). Cube-Connection via `additional.php` (Connection `cube`).
- Deploy ins Wegwerf-TYPO3: `./sync-to-demo.sh`.
