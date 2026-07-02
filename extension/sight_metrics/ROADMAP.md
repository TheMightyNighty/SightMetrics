# Roadmap

Offene Punkte (Stand 2026-07-02). Behobene Findings wurden entfernt, siehe Git-Historie
fuer Details zu abgeschlossenen Themen.

## Pruefung vom 2026-07-02 (zweiter Durchgang)

Sicht: TYPO3-Entwickler (Einbindung/Pflege), Softwarearchitekt, Betrieb.
Sortiert nach Schwere; Sicherheits-Findings zuerst.

### Sicherheit

1. ~~**[Hoch] Mandantentrennung-Bypass bei "kein Webmount-Zugriff"**~~ **[behoben]** —
   `Classes/Support/SiteSelector.php`, `allowedSiteIds()`. Gab in zwei voellig
   verschiedenen Situationen dieselbe leere Liste zurueck: (a) keine Site hat ein
   `sightmetrics_site_id`-Mapping (gewollte Rueckwaertskompatibilitaet) und (b) Mappings
   existieren, aber der Benutzer hat auf KEINE gemappte Site Webmount-Zugriff. Downstream
   bedeutete `[]` aber "kein Filter": `CubeRepository::sites([])` lieferte ALLE Sites. Ein
   Nicht-Admin mit Modulzugriff, dessen Webmounts nur auf einem nicht gemappten Seitenbaum
   liegen, sah die Analytics aller Mandanten. Der Unit-Test
   `testAllowedSiteIdsExcludesAllForNonAdminWithoutWebmountAccess` asserted `[]` und
   zementierte das Fehlverhalten sogar.

   **Fix (2026-07-02):** Rueckgabe disambiguiert — `null` = "kein Mapping konfiguriert"
   (weiterhin filterlos, Rueckwaertskompatibilitaet) vs. `[]` = "nichts erlaubt".
   `DashboardController` zeigt bei `[]` ein leeres Dashboard (und fragt `meta(0)` gar nicht
   erst ab, damit ein Cube mit tatsaechlicher site_id 0 nicht durchsickert; das
   1970-Sentinel-Fenster des `WindowResolver` blockt die uebrigen Queries datumsseitig).
   `TopNAjaxController` antwortet bei `[]` mit 403. Unit-Tests angepasst (No-Mapping-Faelle
   erwarten `null`) und explizit im Container gegen echte TYPO3-Klassen ausgefuehrt (der
   Phar-Runner ueberspringt sie). Handbuch §5 um die Verhaltens-Tabelle ("leeres Dashboard,
   bewusst kein Rueckfall auf alle Sites") und einen Multi-Mandanten-Warnhinweis ergaenzt.

2. ~~**[Mittel] Ajax-Route erbt keine Modul-Berechtigung**~~ **[behoben]** —
   `Configuration/Backend/AjaxRoutes.php` nutzte nicht
   `'inheritAccessFromModule' => 'web_sightmetrics'` (TYPO3 12.4+, Changelog #106983).
   Jeder authentifizierte Backend-Benutzer — auch ohne Rechte am SightMetrics-Modul —
   konnte `/typo3/ajax/sightmetrics/topn` aufrufen; in einer Installation ohne Site-Mapping
   (Rueckwaertskompatibilitaetsmodus) ganz ohne weitere Zugriffspruefung.

   **Fix (2026-07-02):** Option ergaenzt; `BackendModuleValidator` (Middleware, laeuft vor
   dem CSRF-Token-Check) antwortet jetzt 403, wenn dem Benutzer das Modul fehlt.
   Verifiziert im Demo-Stack mit einem eigens angelegten Backend-Benutzer ohne
   Modulrechte: eingeloggt + Ajax-Aufruf -> 403; Admin ueber das Modul (mit Token) ->
   200 mit korrekten Daten (keine Aussperrung des regulaeren Pfads).

### Logik / Fehler (niedrig)

3. ~~**[Niedrig] Server-Top-N filtert `dimkey = ''` nicht**~~ **[behoben]** — das alte
   client-seitige `agg()` uebersprang leere Keys; die Server-Queries taten das nicht
   (leere Barlisten-Zeile moeglich, `dimSummary`-Prozentbasis zaehlte sie mit).
   **Fix (2026-07-02):** `dimkey <> ''` in `topN()` und `dimSummary()` (schliesst per
   SQL-Semantik auch NULL aus); Functional-Tests fuer beide Methoden ergaenzt.

4. ~~**[Niedrig] Ajax-Datumsvalidierung ohne `checkdate()`**~~ **[behoben]** —
   `TopNAjaxController` nutzt jetzt `WindowResolver::iso()` (dafuer public gemacht statt
   Regex-Duplikat): Format + `checkdate`, `2026-99-99` liefert 400. `offset` auf 10000
   gedeckelt (tiefe Pagination = voller Sort pro Seite). Unit-Tests fuer `iso()` ergaenzt
   (Schaltjahr, Monat 13, falsches Format).

5. ~~**[Nit] Ajax-Rows liefern `pv`/`v` als Strings**~~ **[behoben]** — `topN()` castet
   die Aggregat-Summen jetzt explizit auf int (sauberer JSON-Vertrag statt impliziter
   JS-Koerzierung); per Functional-Test auf identische Typen gesichert.

### Betrieb

6. **[Mittel] `cache_sight_metrics` waechst unbegrenzt** — `Typo3DatabaseBackend` loescht
   abgelaufene Eintraege nicht selbst; dafuer braucht es den Scheduler-Task "Caching
   framework garbage collection". Die Cache-Keys sind hochkardinal (jede
   from/to/offset/parentKey-Kombination = eigene Zeile, TTL 60s) — ohne GC-Task sammeln
   sich tote Zeilen unbegrenzt an. Nirgends dokumentiert. **Fix:** Doku-Abschnitt im
   Handbuch (Betrieb/Produktions-Haertung) + Runbook; alternativ/ergaenzend pruefen, ob
   ein Backend mit automatischer Verdraengung sinnvoller ist.

### Dokumentation

7. **Verzeichnisstruktur (Handbuch §2) stark veraltet** — listet `echarts.min.js`
   (existiert nicht mehr; heute `chart.umd.min.js`, `leaflet.js`, `leaflet.css`,
   `images/`); es fehlen `TopNAjaxController`, `TopNDims`, `HealthCommand`,
   `WindowResolver`, `AjaxRoutes.php`, `ext_localconf.php`, `Tests/JavaScript/`,
   `WindowResolverTest`, `package.json`, `scripts/`; "10 Tests" stimmt nicht mehr (23
   functional); die `Commands.php`-Zeile nennt nur `smoke`, nicht `health`.

8. **ECharts-Verweise an 7 Stellen nicht nachgezogen** (Chart.js/Leaflet-Migration):
   Handbuch Zeilen 75/77/78/330/525/529, `README.md:159`, `DashboardController.php:27`
   (Docblock), `dashboard.js:173` (Kommentar). Der CSP-Troubleshooting-Abschnitt empfiehlt
   sogar, "ECharts zu verschieben".

9. **§ "Neue Dimension hinzufuegen" faktisch falsch** — Schritt 2 verweist auf
   Fluid-`<f:for>` ueber `{cubeByDim...}` (Template ist laengst JSON-getrieben), und
   "Kein PHP-Code muss geaendert werden" stimmt seit Top-N nicht mehr: eine hochkardinale
   neue Dimension gehoert in die `TopNDims`-Whitelist, sonst geht sie ungebremst in den
   Payload bzw. der Ajax-Endpunkt antwortet 400. Wer der Anleitung folgt, scheitert.

10. **`cacheLifetime` fehlt in der Konfigurationstabelle §6** (steht nur versteckt in
    "Bekannte Grenzen").

11. **Troubleshooting "Datums-Picker: Standard ist der aktuelle Monat" falsch** —
    Standard ist das geladene Fenster (`windowDays`, 92 Tage).

12. **`ext_emconf.php` Version 1.2.0 nicht angehoben** trotz Caching, Top-N,
    Drill-down-Nachladen und neuer Ajax-Route — fuer Pflege-/Upgrade-Nachvollziehbarkeit
    sollte die Version mitwachsen.

## Architektur

- **Skalierung ueber Kardinalitaet ungeloest** — rohe Cube-Zeilen gehen komplett an den
  Browser, Aggregation passiert clientseitig. `windowDays` begrenzt nur die Zeitachse; bei
  vielen unterschiedlichen URLs/Referrern im Fenster waechst die JSON-Payload unbegrenzt.

  **Status: dokumentiert (`docs/extension-handbuch.md` Abschnitt "Bekannte Grenzen"),
  Umsetzung als eigener Task zurueckgestellt (2026-07-02).** Entscheidung: "echtes Top-N +
  Nachladen" (nicht nur ein harter Sicherheits-Deckel) — siehe Task-Skizze unten.

  ### Task: Top-N + Nachladen fuer Barlisten/Drill-down

  Betrifft drei unterschiedliche Darstellungsmuster im Dashboard, die nicht gleich behandelt
  werden koennen:
  1. **Flache Barlisten** (Land, Browser, OS, Referrer-Typ, Keywords, Downloads, Status,
     Methoden, Einstiegs-/Ausstiegsseiten) — einfach Top-N-faehig, groesstes
     Kardinalitaetsrisiko bei Referrer-URLs/Keywords/Einstiegs-Ausstiegsseiten.
  2. **Zweistufiger Drill-down** (Referrer-Typ→Name→URL, Browser→Version, OS→Version,
     Geraet→Modell) — Kind-Kategorien muessen bei Bedarf nachgeladen werden, nicht nur die
     Top N der Elternebene.
  3. **Seitenbaum** (`url`-Dimension, `buildTree()`/`renderTree()`) — rekursiver Pfad-Baum,
     strukturell anders als 1./2. (kein Top-N/Kind-Schema, sondern Pfadsegmente). **Bewusst
     nicht Teil dieses Tasks** — braucht ein eigenes Baum-Nachlade-Konzept.

  ~~**Blocker**~~ **Geklaert (2026-07-02):** `SEP` in `dashboard.js` (Zeile 6, `var SEP =
  '\x1f';`) ist **kein leerer String**, sondern das ASCII-Steuerzeichen Unit Separator
  (0x1F/`chr(31)`) — im Editor/Terminal unsichtbar, deshalb der urspruengliche Verdacht auf
  einen leeren String. Per Hexdump verifiziert: `hexdump -C` auf die Quellzeile zeigt Byte
  `1f` zwischen den Anfuehrungszeichen. Die Ingestion (`ingestion/transform.sql`, Zeilen
  126/127/131/133/135) baut die Drill-down-`dimkey`-Werte exakt mit `chr(31)` als Trenner
  (`ref_type||chr(31)||ref_name`, `browser||chr(31)||browser_version` usw.) — Client und
  Ingestion sind konsistent, kein Bug, funktioniert nicht "zufaellig". Per jsdom-Repro
  bestaetigt: `firstSeg()`/`lastSeg()`/`childrenOf()` verhalten sich fuer echte Werte wie
  erwartet (z. B. `lastSeg('Firefox')` liefert `'Firefox'`, nicht `''`, weil `0x1f` in
  `'Firefox'` nicht vorkommt und `indexOf`/`lastIndexOf` dann `-1` liefern, nicht 0).
  Eine serverseitige Top-N-Query fuer Kind-Dimensionen kann also 1:1 mit `chr(31)` als
  Trennzeichen bauen (z. B. `SUBSTRING_INDEX(dimkey, CHAR(31), 1)` fuer den Eltern-Praefix
  in MySQL/MariaDB).

  ~~**Phase 1: flache Barlisten ohne Drill-down-Kind**~~ **[behoben, 2026-07-02]** — Keyword,
  Entry, Exit, Download, Status, Methode. Land bewusst ausgenommen (Choropleth-Karte braucht
  alle Laender, ISO-Kardinalitaet ohnehin begrenzt); Browser/OS/Geraet/Referrer-Typ ebenfalls
  ausgenommen (haben ein DRILL-Kind, siehe Phase 2 unten).

  **Umgesetzt:**
  - `Classes/Support/TopNDims.php`: dim->Metrik-Zuordnung + Default-Limit (8) fuer die
    6 governed Dims.
  - `CubeRepository::topN()` (GROUP BY dimkey ORDER BY metric DESC LIMIT/OFFSET, Metrik
    gegen `['pv','v']`-Whitelist geprueft) und `::dimSummary()` (Gesamtsumme + Anzahl
    unterschiedlicher dimkeys, Basis fuer Prozentanzeige und "+ N weitere"). Beide ueber
    `cached()` (siehe Caching-Punkt oben) TTL-gecacht. `::cube()` bekommt einen
    `$excludeDims`-Parameter; `DashboardController` schliesst die 6 governed Dims damit aus
    dem Initial-Payload aus.
  - Neuer Ajax-Endpunkt `Configuration/Backend/AjaxRoutes.php` ->
    `TopNAjaxController::handleRequest()` (Routenname `ajax_sightmetrics_topn` — TYPO3
    praefixiert Ajax-Routen automatisch mit `ajax_`/`/ajax`, siehe Kommentar in
    AjaxRoutes.php). Prueft `SiteSelector::allowedSiteIds()` wie das Hauptmodul (kein
    Site-Zugriff am Modul vorbei ueber die Ajax-Route), validiert `dim` gegen die
    TopNDims-Whitelist und `from`/`to` als `YYYY-MM-DD`.
  - `dashboard.js`: `reloadTopNAll()`/`renderTopN()` ersetzen fuer diese 6 Dims die alten
    `barlist()`-Aufrufe. Der client-seitige Datumsbereich-Picker (`w-from`/`w-to`, sofortige
    Neuberechnung fuer den Rest des Dashboards) loest fuer diese 6 Listen einen Ajax-Reload
    aus (Race-Guard ueber `st.from`/`st.to`, falls waehrend eines laufenden Fetches erneut
    der Zeitraum gewechselt wird); "+ N weitere" laedt per Offset-Pagination nach.
  - CSV-Export (`EXPORT_DIMS`/`buildCsv()`): fuer diese 6 Dims bewusst nur der aktuell im
    Dashboard geladene Ausschnitt (Top-N + evtl. nachgeladene Seiten), mit Hinweis in der
    CSV-Spaltenueberschrift — kein zusaetzlicher Vollstaendigkeits-Request beim Export.
  - Tests: `CubeRepositoryFunctionalTest` (Sortierung/Limit/Offset, Aggregation ueber
    mehrere Tage, Metrik-Whitelist, `dimSummary()`), neuer JS-Test fuer initiales
    Top-N-Rendering + Ajax-Nachladen-Klick. Manuell im Demo-Stack per Playwright verifiziert
    (Login, Modul laden, "+ N weitere" klicken, Datumsbereich wechseln -> alle 6 Ajax-Calls
    200, keine Konsolenfehler).

  ~~**Phase 2: zweistufiger Drill-down**~~ **[behoben, 2026-07-02]** — Referrer-Typ→Name→URL,
  Browser→Version, OS→Version, Geraet→Modell. Damit sind jetzt auch die vier verbleibenden
  Root-Dims aus Phase 1 (Browser, OS, Geraet, Referrer-Typ) serverseitig Top-N-begrenzt,
  inklusive ihrer Kind-Ebenen. Die eigenstaendige flache "Referrer-URLs"-Liste (`bl-refurl`,
  ungruppiert nach Eltern-Referrer-Name) ist ebenfalls migriert.

  **Umgesetzt:**
  - `TopNDims`: `ROOT_METRIC_BY_DIM` (Top-Level, im Initial-Payload) und
    `CHILD_METRIC_BY_DIM` (nur ueber `parentKey` erreichbar, nie vorab geladen) getrennt.
    `referrer_url` steht bewusst in beiden Listen: einmal als eigene flache Top-Level-Liste
    (alle referrer_url-Zeilen ungruppiert, Limit 10 wie zuvor), einmal als Kind von
    `referrer_name` (Limit 8). `CHILD_OF_ROOT` dokumentiert die Eltern-Kind-Zuordnung.
  - `CubeRepository::topN()`/`dimSummary()` haben jetzt einen optionalen `$parentKey`-
    Parameter; `applyParentPrefix()` filtert per `SUBSTR(dimkey, 1, N) = 'Eltern' . chr(31)`
    (N = `mb_strlen()` in Unicode-Codepoints, nicht Bytes -- sonst wuerden mehrbyte-UTF-8-
    Elternlabels an der falschen Stelle abgeschnitten). **Stolperstein dabei:**
    `$qb->expr()->eq()` quotet sein erstes Argument als Spalten-Identifier
    (`Connection::quoteIdentifier()`) -- ein `SUBSTR(...)`-Ausdruck als "Feldname" wird damit
    kaputt-gequotet und SQLite interpretiert das Ergebnis dann still als String-Literal
    (kein Fehler, aber 0 Treffer). Fix: `andWhere()` mit einem rohen SQL-String statt
    `expr()->eq()`.
  - `TopNAjaxController`: `parentKey`-Query-Parameter, waehlt je nachdem `ROOT_METRIC_BY_DIM`
    oder `CHILD_METRIC_BY_DIM` als Whitelist.
  - `dashboard.js`: `DRILL`-Map, `childrenOf()`, `firstSeg()` entfernt (obsolet -- der
    Server filtert jetzt per `parentKey`). `TOPN_ROOT`/`TOPN_CHILD` + generischer
    `paintTopN()`-Renderer (gemeinsam fuer Root- und Kind-Listen) ersetzen `renderInto()`
    fuer alle Dims ausser Land (das bleibt die einzige verbleibende `barlist()`-Nutzung,
    keine Kinder). Aufklappen einer Zeile mit Kind-Dim laedt einmalig per Ajax nach
    (`parentKey` = vollstaendiger dimkey der Elternzeile); Datumsbereich-Aenderung verwirft
    aufgeklappte Kind-Listen konsistent mit dem bisherigen Verhalten.
  - Tests: `CubeRepositoryFunctionalTest` (parentKey-Filterung, Abgrenzung gegen
    Praefix-Ueberlappung wie "Chrom" vs. "Chromium", Mehrbyte-Elternlabel), neuer JS-Test
    fuer Drill-down-Nachladen. Manuell im Demo-Stack per Playwright verifiziert (Aufklappen
    von "Chrome" laedt `browser_version?parentKey=Chrome`, zeigt "Chrome 125.0" korrekt
    Eltern-Praefix-bereinigt; alle Root-Listen inkl. Referrer-URLs laden bei Datumswechsel
    neu, keine Konsolenfehler).

  **Bewusst nicht Teil dieses Tasks: Seitenbaum** (`url`-Dimension,
  `buildTree()`/`renderTree()`) — rekursiver Pfad-Baum, strukturell anders als das
  Eltern-Kind-Schema oben (Pfadsegmente statt fester Dimensionen), braucht ein eigenes
  Baum-Nachlade-Konzept. Bleibt vorerst client-seitig mit dem vollstaendigen `url`-Datensatz.

- ~~**Kein Caching**~~ **[behoben]** — `CubeRepository::daily()`/`cube()` (die beiden mit dem
  Zeitfenster wachsenden Reads) laufen jetzt ueber den TYPO3-Cache-Framework-Cache
  `sight_metrics` (`VariableFrontend` + `Typo3DatabaseBackend`, registriert in
  `ext_localconf.php`). TTL per Extension-Konfiguration `cacheLifetime` (Default 60s, 0 =
  deaktiviert). `meta()`/`sites()` bleiben bewusst live (kleine Einzelzeilen/Listen, neue
  Sites sollen sofort sichtbar sein). Fehlt die Cache-Konfiguration (z. B. in Unit-/
  Functional-Tests ohne geladenes `ext_localconf.php`), faellt `CubeRepository::cached()`
  fehlertolerant auf die Live-Query zurueck — Caching ist ein Perf-Feature, keine
  Korrektheitsvoraussetzung. Verifiziert per `sightmetrics:smoke` (Cache-Tabelle
  `cache_sight_metrics` nach Aufruf befuellt) und bestehender Test-Suite (2a/2b/2c/2d gruen).
  Cache-Tabelle wird von TYPO3 selbst angelegt (`extension:setup`/DB-Compare), keine eigene
  Migration noetig.

## Vendor-Provenienz

- ~~Chart.js/Leaflet werden per Ad-hoc-`curl` bezogen (kein npm-Lockfile)~~ **[behoben]** —
  beide jetzt als `devDependencies` in `package.json`, versionsgepinnt via
  `package-lock.json`. `npm run vendor:update` (`scripts/update-vendor.mjs`) kopiert die
  Dist-Dateien aus `node_modules/` nach `Resources/Public/Vendor/` und gibt die
  SHA-256-Summen aus. Verifiziert: alle kopierten Dateien sind byte-identisch mit den
  zuvor per `curl` bezogenen (SHA-256 unveraendert). `world.js` (Natural-Earth-Geodaten)
  bleibt bewusst aussen vor — einmaliger TopoJSON-zu-GeoJSON-Konvertierungsschritt, kein
  1:1-Dateikopie. Details in `Resources/Public/Vendor/NOTICE.md`.
