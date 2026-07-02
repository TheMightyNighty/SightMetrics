# Third-Party-Bibliotheken

Lizenztexte liegen REUSE-konform unter `LICENSES/` (Extension-Root). Zuordnung Datei -> Lizenz
siehe `REUSE.toml` (Extension-Root).

## Chart.js (chart.umd.min.js)
- Version: 4.5.1
- Lizenz: MIT. Copyright (c) 2014-2025 Chart.js Contributors.
- Quelle: https://www.chartjs.org / https://github.com/chartjs/Chart.js
- Bezogen ueber npm (`devDependencies` in `package.json`, versionsgepinnt via
  `package-lock.json`); Datei kopiert aus `node_modules/chart.js/dist/chart.umd.min.js`
  per `npm run vendor:update` (`scripts/update-vendor.mjs`). Ehemals per Ad-hoc-`curl` von
  jsDelivr bezogen (`https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js`) —
  identischer Dateiinhalt (SHA-256 unveraendert), nur die Bezugsart wurde umgestellt.
- SHA-256: 48444a82d4edcb5bec0f1965faacdde18d9c17db3063d042abada2f705c9f54a

## Leaflet (leaflet.js, leaflet.css, images/*.png)
- Version: 1.9.4
- Lizenz: BSD-2-Clause. Copyright (c) 2010-2023 Vladimir Agafonkin, (c) 2010-2011 CloudMade.
- Quelle: https://leafletjs.com / https://github.com/Leaflet/Leaflet
- Bezogen ueber npm (`devDependencies` in `package.json`, versionsgepinnt via
  `package-lock.json`); Dateien kopiert aus `node_modules/leaflet/dist/` per
  `npm run vendor:update` (`scripts/update-vendor.mjs`). Ehemals per Ad-hoc-`curl` von
  jsDelivr bezogen — identischer Dateiinhalt (SHA-256 je Datei unveraendert), nur die
  Bezugsart wurde umgestellt.
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

## Weltkarten-Geodaten (world.js)
- Quelle der Kartendaten: [Natural Earth](https://www.naturalearthdata.com/), public domain
  (keine Attribution noetig, siehe `LICENSES/LicenseRef-Public-Domain-NaturalEarth.txt`).
- Bezogen als vorgefertigtes TopoJSON ueber [world-atlas](https://github.com/topojson/world-atlas)
  (Redistribution/Build-Tooling von Michael Bostock, ISC-Lizenz, siehe `LICENSES/ISC.txt`),
  Version 2.0.2, Datei `countries-50m.json` (Natural-Earth-Quelldaten Version 4.1.0 laut
  world-atlas-Repo).
- Bezogen von: https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/countries-50m.json
- SHA-256 (countries-50m.json, TopoJSON-Original vor Konvertierung):
  04342cdc1e3016bcd7db1630de95684d67b79fe3c8c460321e87aef469502394
- Lokal mit `topojson-client` (ISC) zu GeoJSON konvertiert, Koordinaten auf 2 Nachkommastellen
  gerundet (~1,1 km Praezision am Aequator, fuer die Kartengroesse im Dashboard ausreichend,
  reduziert die Dateigroesse von ~3,9 MB auf ~1,4 MB). 241 Laender/Territorien, inkl. kleiner
  Staaten wie Singapur und Hongkong (in der 110m-Aufloesung von world-atlas nicht enthalten,
  daher bewusst 50m statt 110m gewaehlt).
- Ersetzt die urspruengliche `world.js` (ECharts-Weltkarten-Datensatz seit dem allerersten
  Commit im Repo, Herkunft nicht mehr rekonstruierbar, Lizenzangabe war eine unverifizierte
  Annahme statt einer belegten Quelle — siehe ROADMAP.md Finding 5).

## Aktualisieren (Chart.js/Leaflet)
`npm install` (respektiert `package-lock.json`) gefolgt von `npm run vendor:update`
kopiert die Dist-Dateien nach `Resources/Public/Vendor/` und gibt die SHA-256-Summen aus.
Nach einem Versions-Bump in `package.json`: `npm update chart.js leaflet && npm run
vendor:update`, dann die SHA-256-Werte und die Versionsangaben oben in diesem Dokument
manuell nachziehen.

Die Weltkarten-Geodaten (`world.js`) sind davon ausgenommen — kein 1:1-Dateikopie, sondern
ein einmalig lokal durchgefuehrter TopoJSON-zu-GeoJSON-Konvertierungsschritt (siehe oben),
nicht Teil von `npm run vendor:update`.
