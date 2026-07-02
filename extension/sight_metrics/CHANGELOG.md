# Changelog

## 1.2.0 (unveroeffentlicht, Branch `feature/chartjs-statt-echarts`)

### Geaendert
- **Diagramm-Bibliothek**: Apache ECharts (Apache-2.0) ersetzt durch
  [Chart.js](https://www.chartjs.org/) (MIT) fuer Verlaufs- und Stundendiagramm.
- **Besucherkarte**: statt des ECharts-Kartentyps (bzw. des zunaechst getesteten,
  aber nicht ausgereiften `chartjs-chart-geo`-Plugins) kommt jetzt
  [Leaflet](https://leafletjs.com/) (BSD-2-Clause) mit `L.geoJSON`-Choroplethen-Styling
  zum Einsatz.
- Grund: Apache-2.0 haette bei Einbindung in ein GPLv2-Projekt eine Lizenzpruefung
  noetig gemacht (GPLv3-Aufwaertskompatibilitaet der Extension war zwar gegeben, aber
  MIT/BSD-2-Clause sind unabhaengig von der GPL-Version des Zielprojekts unproblematisch
  einzubinden).
- Vendor-Dateien liegen weiterhin als Build-Artefakte in `Resources/Public/Vendor/`,
  jetzt mit Versions-/Pruefsummenangabe in `NOTICE.md`.
- REUSE-konforme Lizenzstruktur ergaenzt (`LICENSES/`, `REUSE.toml`, `LICENSE`).

### Bekannte Einschraenkungen
- Vendor-JS wird per Ad-hoc-Download bezogen (kein npm-Lockfile) — siehe Hinweis in
  `Resources/Public/Vendor/NOTICE.md`.

## 1.1.0
- Siehe Git-Historie.
