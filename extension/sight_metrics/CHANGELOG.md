# Changelog

## 2.0.0 (2026-07-08) - Schema v2

**Breaking:** Die Extension verlangt Cube-Schema-Version 2. Bestands-DBs mit
`ingestion/migrations/v1_to_v2.sql` migrieren (idempotent) oder neu importieren;
Modul und `sightmetrics:health` brechen sonst mit klarer Meldung ab.

### Geaendert (DB-Vertrag, docs/SCHEMA.md v2)
- **Lokale Tages-Buckets:** `datum`/`hour` und der Tagesgrenzen-Cut folgen der
  Site-Zeitzone `SM_TZ` (in `meta.tz` hinterlegt, Default UTC); das Frontend
  ankert relative Zeitraeume ("Heute", "Letzte 7 Tage") in dieser Zone,
  `sightmetrics:health` rechnet das Datenalter darin.
- **`cube.parent`-Spalte** ersetzt die CHR(31)-kodierten Drill-down-Keys:
  Kind-Abfragen sind jetzt einfache (indexierbare) Gleichheit, Anzeige-Labels
  sind reine Werte.
- **Neutrale `referrer_type`-Keys** (`direct`/`search`/`social`/`website`)
  statt deutscher Anzeigewerte im Datenbestand; Labels kommen aus der XLF.
- **Mehrtages-Uniques bleiben bewusst genaehert:** exakte Werte sind mit dem
  Tages-Salt-Privacy-Design (keine Besucher-Verkettung ueber Tage) prinzipiell
  unvereinbar -- als permanente Design-Entscheidung in SCHEMA.md dokumentiert.

### Neu
- **Contract-Test** (`tests/contract/run.sh` + `CubeContractTest`): echter
  Ingestion-Import -> echte MariaDB -> echtes CubeRepository, in CI (e2e-Job).

## 1.3.0 (2026-07-07)

### Qualitaets-Offensive (Notenschnitt-Massnahmen 1-5)
- **Versionierter DB-Vertrag** (`docs/SCHEMA.md`): Ingestion stempelt
  `meta.schema_version`; `CubeRepository::SCHEMA_VERSION` prueft beim Modulaufbau
  und im `sightmetrics:health`-Command -- eine NEUERE Schreiber-Version bricht mit
  klarer Meldung ab, Legacy-DBs (ohne Spalte) bleiben kompatibel.
- **Onboarding-Seite**: leeres Cube -> gefuehrte 3-Schritte-Seite statt leerem
  Dashboard; eigener "Kein Zugriff"-Hinweis bei Webmount-Sperre (beides lokalisiert).
- **Bot-Erkennung auf Datenbasis**: `ingestion/tools/fetch_bot_list.sh` baut aus
  matomo/device-detector (`bots.yml`) eine validierte RE2-Liste (~800 Muster,
  `SM_BOT_RE_PATH`); ohne Liste greift weiter die eingebaute Heuristik.
- **Screenshots** in der ReST-Doku (`Documentation/Images/`), deutsches Handbuch
  verweist auf die ReST-Doku als massgebliche Quelle.
- **Frontend als native ES-Module** (`Configuration/JavaScriptModules.php`,
  `loadJavaScriptModule()`): dashboard.js + `modules/{util,i18n,export}.js`;
  `tsc --checkJs`-Typpruefung (`npm run typecheck`) und JS-Tests in der CI;
  referrer_type-Datenwerte werden fuer die Anzeige lokalisiert.

### TER-Vorbereitung
- **Vollstaendige Lokalisierung**: alle UI-Texte (Template, dashboard.js, Fehlerseite)
  aus `locallang_mod.xlf` (Default Englisch) mit deutscher Uebersetzung
  (`de.locallang_mod.xlf`). dashboard.js erhaelt die Labels als `lang`-Map im Payload
  (`DashboardController::jsLabels()`), Laendernamen via `Intl.DisplayNames` in der
  Sprache des BE-Benutzers, Zahlenformate via BE-User-Locale.
- **ReST-Dokumentation** unter `Documentation/` (docs.typo3.org-Format, Englisch):
  Introduction, Installation, Configuration, Usage, Known Problems – inkl. deutlichem
  Hinweis, dass die separat betriebene SightMetrics-Ingestion Voraussetzung ist.
- **Formalia**: Author/E-Mail in `ext_emconf.php`/`composer.json`, `support`-Links,
  englische Extension-Beschreibung; `ext_conf_template.txt`-Labels englisch,
  Fehlerseiten-Defaults englisch (per Extension-Konfiguration ueberschreibbar).

### Geaendert (Ingestion, Paket A)
- Tagesgrenzen-Cut im inkrementellen Import (kein Datenverlust an der Tagesgrenze;
  ein Tag erscheint erst nach Abschluss), Bot-/Crawler-Filter (`SM_BOT_FILTER`),
  IPv6-robustes Parsing (Land `??`), Statuscode-Panel zeigt 4xx/5xx,
  Edge/Opera-Erkennung, verankerte Referrer-Heuristik, `SM_TZ` fuer Besuchszeiten,
  konfigurierbare Download-Endungen (`SM_DOWNLOAD_RE`).
- Container gehaertet (non-root UID 10001, readOnlyRootFilesystem-tauglich),
  vollstaendige k8s-Manifeste (`ingestion/scheduling/k8s/`), GHCR-Image-Workflow.

## 1.2.0 (2026-07-03)

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
