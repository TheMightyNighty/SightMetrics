# Third-Party-Bibliotheken

Lizenztexte liegen REUSE-konform unter `LICENSES/` (Extension-Root). Zuordnung Datei -> Lizenz
siehe `REUSE.toml` (Extension-Root).

## Chart.js (chart.umd.min.js)
- Version: 4.5.1
- Lizenz: MIT. Copyright (c) 2014-2025 Chart.js Contributors.
- Quelle: https://www.chartjs.org / https://github.com/chartjs/Chart.js
- Bezogen von: https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js
- SHA-256: 48444a82d4edcb5bec0f1965faacdde18d9c17db3063d042abada2f705c9f54a

## Leaflet (leaflet.js, leaflet.css, images/*.png)
- Version: 1.9.4
- Lizenz: BSD-2-Clause. Copyright (c) 2010-2023 Vladimir Agafonkin, (c) 2010-2011 CloudMade.
- Quelle: https://leafletjs.com / https://github.com/Leaflet/Leaflet
- Bezogen von: https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js bzw. .../leaflet.css
  bzw. .../dist/images/<datei>.png
- SHA-256 (leaflet.js): db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a
- SHA-256 (leaflet.css): a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6
- SHA-256 (images/layers.png): 1dbbe9d028e292f36fcba8f8b3a28d5e8932754fc2215b9ac69e4cdecf5107c6
- SHA-256 (images/layers-2x.png): 066daca850d8ffbef007af00b06eac0015728dee279c51f3cb6c716df7c42edf
- SHA-256 (images/marker-icon.png): 574c3a5cca85f4114085b6841596d62f00d7c892c7b03f28cbfa301deb1dc437
- SHA-256 (images/marker-icon-2x.png): 00179c4c1ee830d3a108412ae0d294f55776cfeb085c60129a39aa6fc4ae2528
- SHA-256 (images/marker-shadow.png): 264f5c640339f042dd729062cfc04c17f8ea0f29882b538e3848ed8f10edb4da
- Hinweis: `marker-icon-2x.png`/`marker-shadow.png` werden von keiner aktuell genutzten
  Leaflet-Funktion referenziert (keine L.marker()-Nutzung), sind aber Teil des offiziellen
  Default-Icon-Sets und liegen zur Vollstaendigkeit bei, falls spaeter Marker verwendet werden.

## Hinweis fuer eine spaetere Uebernahme durch das GSB11-Team
Diese Dateien wurden manuell per `curl` von jsDelivr bezogen (kein npm-Lockfile). Fuer eine
produktive Uebernahme mit Supply-Chain-Anforderungen empfiehlt sich ein versionsgepinnter
Bezug ueber einen Paketmanager (z. B. npm mit package-lock.json oder ein Composer-Asset-Plugin)
statt eines Ad-hoc-Downloads. Die obigen Pruefsummen dienen bis dahin der Nachvollziehbarkeit.
