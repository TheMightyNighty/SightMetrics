# Changelog

## 1.2.0 (unveroeffentlicht, Branch `feature/chartjs-statt-echarts`)

### Sicherheit
- **Mandantentrennung benutzerbezogen**: Site-Sichtbarkeit folgt dem TYPO3-Webmount-
  Modell (`SiteSelector::allowedSiteIds()`); ein Benutzer ohne Webmount auf eine
  gemappte Site sieht deren Analytics nicht mehr. Leere Berechtigungsmenge wird nicht
  mit "kein Mapping konfiguriert" verwechselt (kein Rueckfall auf "alle Sites").
- **Ajax-Route erbt Modul-Berechtigung** (`inheritAccessFromModule`): Backend-Benutzer
  ohne das Modul `web_sightmetrics` erhalten 403.
- **CSV-Export gegen Formel-Injection gehaertet** (fuehrende `=`/`+`/`-`/`@`
  entschaerft); technische Fehlermeldungen nur noch fuer Admins; Error-Logging via
  `LoggerAwareInterface`.

### Neu
- **Serverseitiges Top-N + Nachladen** fuer alle hochkardinalen Barlisten (Suchbegriffe,
  Einstiegs-/Ausstiegsseiten, Downloads, Statuscodes, HTTP-Methoden, Browser, OS,
  Geraetetyp, Referrer): initial nur Top-8 (Referrer-URLs: 10) im Payload; "+ N weitere"
  und Drill-down-Kinder (Browser-Version usw.) werden per Ajax-Route
  `ajax_sightmetrics_topn` nachgeladen (`TopNAjaxController`, `TopNDims`-Whitelists,
  `CubeRepository::topN()`/`dimSummary()` mit `parentKey`-Praefixfilter).
- **Seitenbaum serverseitig segmentiert + lazy**: `CubeRepository::urlTree()` extrahiert
  Pfad-Segmente mit Unterbaum-Summen direkt in SQL (portable SUBSTR/INSTR, MariaDB +
  SQLite); Initial-Payload enthaelt zwei Ebenen (Top-8 je Ebene), tiefere Aeste und
  "+ N weitere" laedt die Ajax-Route `ajax_sightmetrics_tree` nach
  (`TreeAjaxController`). Die `url`-Zeilen stehen damit nicht mehr komplett im Payload.
  Gemeinsame Site-Zugriffspruefung beider Ajax-Endpunkte in `AjaxSiteGuard` gebuendelt.
- **Query-Caching**: Cube-DB-Reads laufen ueber den TYPO3-Cache `sight_metrics`
  (Extension-Konfiguration `cacheLifetime`, Default 60 s, 0 = aus). Betrieb: Cache-GC
  einrichten, siehe Handbuch "Bekannte Grenzen".
- **CLI `sightmetrics:health`**: Datenaktualitaet je Site, Nagios-kompatible Exit-Codes,
  optional JSON (Monitoring-Agenten). Validiert `--crit-hours >= --warn-hours`.
- **JS-Smoke-Test** (`Tests/JavaScript/`, node:test + jsdom) inkl. Top-N-/Drill-down-
  Nachladen; neue Test-Stufe 2d in `run-tests.sh`.

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
- **Weltkarten-Geodaten** (`world.js`) durch verifizierte Quelle ersetzt (Natural Earth
  via [world-atlas](https://github.com/topojson/world-atlas) 2.0.2, public domain;
  Herkunft/Pruefsummen in `NOTICE.md`).
- **Vendor-Bezug ueber npm mit Versions-Pinning** (`package.json`/`package-lock.json`,
  `npm run vendor:update`) statt Ad-hoc-`curl`; REUSE-konforme Lizenzstruktur
  (`LICENSES/`, `REUSE.toml`, `LICENSE`).

## 1.1.0
- Siehe Git-Historie.
