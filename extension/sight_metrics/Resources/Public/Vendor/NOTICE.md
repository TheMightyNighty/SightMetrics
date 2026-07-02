# Third-Party-Bibliotheken

Lizenztexte liegen REUSE-konform unter `LICENSES/` (Extension-Root). Zuordnung Datei -> Lizenz
siehe `REUSE.toml` (Extension-Root).

## Chart.js (chart.umd.min.js)
- Version: 4.5.1
- Lizenz: MIT. Copyright (c) 2014-2025 Chart.js Contributors.
- Quelle: https://www.chartjs.org / https://github.com/chartjs/Chart.js
- Bezogen von: https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js
- SHA-256: 48444a82d4edcb5bec0f1965faacdde18d9c17db3063d042abada2f705c9f54a

## Leaflet (leaflet.js, leaflet.css)
- Version: 1.9.4
- Lizenz: BSD-2-Clause. Copyright (c) 2010-2023 Vladimir Agafonkin, (c) 2010-2011 CloudMade.
- Quelle: https://leafletjs.com / https://github.com/Leaflet/Leaflet
- Bezogen von: https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js bzw. .../leaflet.css
- SHA-256 (leaflet.js): db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a
- SHA-256 (leaflet.css): a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6

## Hinweis fuer eine spaetere Uebernahme durch das GSB11-Team
Diese Dateien wurden manuell per `curl` von jsDelivr bezogen (kein npm-Lockfile). Fuer eine
produktive Uebernahme mit Supply-Chain-Anforderungen empfiehlt sich ein versionsgepinnter
Bezug ueber einen Paketmanager (z. B. npm mit package-lock.json oder ein Composer-Asset-Plugin)
statt eines Ad-hoc-Downloads. Die obigen Pruefsummen dienen bis dahin der Nachvollziehbarkeit.
