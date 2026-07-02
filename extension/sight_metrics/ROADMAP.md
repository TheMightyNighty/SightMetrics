# Roadmap

Ergebnis der Prüfung vom 2026-07-02 (Sicht TYPO3-Entwickler, Softwarearchitekt, Betrieb).
Sortiert nach Schwere; Sicherheits-Findings zuerst.

## Sicherheit (7 Findings, absteigend nach Schwere)

1. ~~**[Hoch] CSV-Injection im Export**~~ **[behoben]** — `Resources/Public/JavaScript/dashboard.js`,
   Funktion `csvCell()`. Escaped nur `["; \n]`, nicht aber fuehrende `=`, `+`, `-`, `@`.
   Suchbegriffe und Referrer-URLs stammen roh aus Weblogs und sind angreiferkontrolliert —
   ein Besucher kann per Referrer z. B. `=HYPERLINK(...)` injizieren, das beim Oeffnen der
   CSV in Excel ausgefuehrt wird. **Fix:** Zellen, die mit `= + - @` beginnen, mit
   fuehrendem `'` (Apostroph) escapen, bevor sie gequotet werden.

2. ~~**[Hoch] Mandantentrennung nicht benutzerbezogen**~~ **[behoben]** —
   `Classes/Support/SiteSelector.php`, `allowedSiteIds()`. Filterte bisher global ueber alle
   Site-Configs, nicht pro Backend-Benutzer. Leere Liste = alle Cube-Sites sichtbar. Jeder
   Benutzer mit Modulzugriff sah Analytics aller Mandanten, unabhaengig von seinen TYPO3-
   Seiten-/Site-Rechten.

   **Umgesetzt (2026-07-02)** nach dem unten skizzierten Design: das generelle TYPO3-
   Seitenbaum-/Webmount-Modell wird genutzt (kein separates Berechtigungskonzept).
   `allowedSiteIds(SiteFinder, BackendUserAuthentication)` prueft pro Site
   `isAdmin() || isInWebMount(rootPageId) !== null`; `DashboardController` uebergibt den
   Backend-User ueber eine neue `beUser()`-Hilfsmethode (wirft bei fehlendem `BE_USER`, landet
   im bestehenden Catch-/Logging-Pfad). Rueckwaertskompatibilitaet erhalten: ohne jegliches
   `sightmetrics_site_id`-Mapping bleibt es filterlos. Unit-Tests fuer Admin-, Webmount- und
   Kein-Zugriff-Fall ergaenzt (`Tests/Unit/SiteSelectorTest.php`).

   **Bekannte Test-Luecke (nicht neu, betraf schon die alten 5 Tests):** die
   `allowedSiteIds`-Tests mocken TYPO3-Klassen (`SiteFinder`, `BackendUserAuthentication`) und
   laufen nur, wenn diese Klassen im Testprozess vorhanden sind. Der phar-basierte Unit-Runner
   (`run-tests.sh` 2a) hat keinen TYPO3-Autoloader, dort werden sie uebersprungen; der
   Functional-Runner (2b) deckt nur `Tests/Functional/` ab. Der Code laeuft damit aktuell nie
   automatisiert gegen echte TYPO3-Klassen. **Fix-Vorschlag:** `Tests/Unit/SiteSelectorTest.php`
   zusaetzlich in die Functional-Suite aufnehmen (oder eine dritte, TYPO3-testing-framework-
   basierte Unit-Suite ergaenzen), damit diese Faelle tatsaechlich exekutiert werden.

   ---

   Ursprüngliche Design-Skizze (zur Nachvollziehbarkeit):
   Die Extension hat bewusst keine TCA/eigene Berechtigungstabelle (Design-Prinzip: nur
   lesender DBAL-Zugriff, kein Extbase). Ein sauberer Fix sollte dieses Prinzip nicht
   durchbrechen, sondern TYPO3s vorhandenes Modell (Webmounts + Seitenrechte) wiederverwenden:

   1. **Kopplung Site <-> Seitenbaum ist bereits da**: jede TYPO3-`Site`-Config hat einen
      `rootPageId` und (per bestehender Konvention) ein `sightmetrics_site_id`-Feld. Diese
      Zuordnung existiert schon, wird aber aktuell nicht mit Benutzerrechten verschnitten.
   2. **`allowedSiteIds()` um den Backend-User erweitern** (Signatur z. B.
      `allowedSiteIds(SiteFinder $siteFinder, BackendUserAuthentication $beUser)` —
      Zugriff auf `$GLOBALS['BE_USER']` ist im Controller ohnehin schon Muster, siehe Fix zu
      Finding 4). Fuer jede `Site` pruefen, ob der Benutzer Zugriff auf deren `rootPageId`
      hat: `$beUser->isAdmin() || $beUser->isInWebMount($rootPageId) !== false`. Nur die
      `sightmetrics_site_id`-Werte der zugaenglichen Sites zurueckgeben.
   3. **Admin-Bypass beibehalten**: `isAdmin()` sieht weiterhin alles — konsistent mit dem
      Finding-4-Fix und dem uebrigen TYPO3-Backend-Verhalten.
   4. **Migrationsverhalten**: aktuell bedeutet "keine `sightmetrics_site_id` konfiguriert"
      = kein Filter (Ruckwaertskompatibilitaet, siehe Docblock). Das sollte so bleiben, sonst
      brechen bestehende Installationen ohne Site-Mapping. Nur *wenn* eine Zuordnung existiert,
      greift die Webmount-Pruefung.
   5. ~~Offene Frage fuer das GSB11-Team~~ **Geklaert (2026-07-02):** Webmount-/Seitenbaum-
      Pruefung auf `rootPageId` reicht — kein zusaetzliches, seitenbaum-unabhaengiges
      Berechtigungskonzept. Konsistent mit dem generellen TYPO3-Rechtemodell, das im Projekt
      durchgaengig genutzt wird.

   **Bewusst nicht vorgeschlagen:** eigene Berechtigungstabelle/TCA — würde das
   "kein Extbase/keine TCA"-Designprinzip der Extension durchbrechen und zu einer
   Parallelstruktur neben TYPO3s Seitenrechten fuehren (zwei Quellen der Wahrheit,
   Wartungsrisiko).

3. ~~**[Mittel] Kein Error-Logging**~~ **[behoben]** — `Classes/Controller/DashboardController.php`,
   `handleRequest()`. Faengt `\Throwable` global, zeigt nur die Fehlerseite. Kein
   `LoggerInterface` injiziert, nichts landet im TYPO3-Log. Betrieb sieht "Auswertung nicht
   verfuegbar", hat aber keinen Log-Eintrag zum Debuggen (ausser `showTechnical=1`, das man
   produktiv nicht dauerhaft aktivieren will). **Fix:** `LoggerAwareInterface`/`LoggerAwareTrait`
   (TYPO3-Standardmuster, DI-Container injiziert automatisch), Exception in beiden
   Catch-/Fehlerpfaden geloggt (inkl. Kontext: siteParam bzw. JSON-Fehler).

4. ~~**[Mittel] Technische Fehlermeldung nicht auf Admins beschraenkt**~~ **[behoben]** —
   `Classes/Support/ErrorPage.php` + `ext_conf_template.txt` (`showTechnical`).
   Zeigt bei Aktivierung rohe Exception-Messages (mysqli-Fehler enthalten Host/User der
   Cube-DB) allen Modul-Nutzern, nicht nur Admins. **Fix:** `ErrorPage::resolve()` um
   Pflichtparameter `bool $isAdmin` erweitert; Controller ermittelt ihn ueber
   `$GLOBALS['BE_USER']->isAdmin()` und blendet `technical` fuer Nicht-Admins aus, auch wenn
   `showTechnical` aktiv ist.

5. ~~**[Niedrig] Lizenz von world.js unverifiziert**~~ **[behoben]** — die urspruengliche
   `world.js` lag seit dem allerersten Commit im Repo, ohne rekonstruierbare Herkunft; die
   REUSE.toml-Angabe (CC0/Natural Earth) war eine plausible, aber unverifizierte Annahme.

   **Fix:** komplett durch eine nachvollziehbare Quelle ersetzt: Natural-Earth-Kartendaten
   (public domain, keine Attribution noetig) ueber
   [world-atlas](https://github.com/topojson/world-atlas) v2.0.2 (ISC-lizenzierte
   Redistribution/Tooling von Michael Bostock), Datei `countries-50m.json`, lokal mit
   `topojson-client` zu GeoJSON konvertiert (Koordinaten auf 2 Nachkommastellen gerundet,
   ~1,4 MB statt ~3,9 MB unkomprimiert). 110m-Aufloesung bewusst verworfen, weil ihr u. a.
   Singapur und Hongkong fehlen (kleine Staaten werden bei 110m aus Natural-Earth
   ausgespart) — beides Laender mit realem Traffic in den Demo-Daten. `LICENSES/ISC.txt` und
   `LICENSES/LicenseRef-Public-Domain-NaturalEarth.txt` ergaenzt, Herkunft/Version/SHA-256 in
   `NOTICE.md` dokumentiert. `ISO2NAME`-Mapping in `dashboard.js` an drei Stellen angepasst
   (US, KR, CZ heissen im neuen Datensatz anders als im alten), der Laufzeit-Patch fuer das
   fehlende `type:"Feature"`-Feld (noetig fuer die alte Datei, siehe Leaflet-Migration) konnte
   entfallen, da der neue Datensatz bereits korrektes GeoJSON liefert.

6. ~~**[Niedrig] Fehlende Leaflet-Bildassets**~~ **[behoben]** — `leaflet.css` referenzierte
   `images/layers.png`, `images/layers-2x.png`, `images/marker-icon.png`, die nicht
   mitgeliefert wurden. Aktuell ungenutzt (keine Marker/Layer-Control aktiv), haette aber zu
   404s gefuehrt, sobald die Karte um Marker/Layer-Steuerung erweitert wird. **Fix:** die
   5 offiziellen Leaflet-1.9.4-Bilddateien (`layers.png`, `layers-2x.png`, `marker-icon.png`,
   `marker-icon-2x.png`, `marker-shadow.png`) nach `Resources/Public/Vendor/images/` ergaenzt,
   Quelle/Version/SHA-256 in `NOTICE.md` und `REUSE.toml` dokumentiert.

7. ~~**[Niedrig] Betriebs-Vorlagen mit unsicheren Defaults**~~ **[behoben — Dokumentation, s.
   Einschraenkung unten]** — `demo/app/config/system/additional.php` setzt
   `trustedHostsPattern = ".*"` (Host-Header-Injection-Risiko) und
   `demo/initdb/01-analytics.sh` grantet `report_ro'@'%'` (Host-Wildcard). Als Demo
   kommentiert, aber diese Dateien sind die Vorlage, die Betreiber kopieren werden.

   **Fix:** Kommentare in beiden Dateien zu unmissverstaendlichen Warnungen ("ACHTUNG NUR FUER
   DIESE LOKALE DEMO, NICHT PRODUKTIV UEBERNEHMEN") ausgebaut, mit konkreter Anleitung, worauf
   in Produktion umzustellen ist. Neuer Abschnitt "Produktions-Haertung" in
   `docs/extension-handbuch.md` (nach "Verbindung testen") mit den konkreten Produktivwerten
   fuer beide Punkte.

   **Bewusste Einschraenkung:** die Demo-Defaults selbst (`.*` bzw. `'%'`) wurden *nicht*
   geaendert — der lokale Docker-Compose-Stack braucht das, weil Container-IPs im Bridge-
   Netzwerk nicht statisch sind. Eine echte Produktions-Beispieldatei mit hartcodierten
   Werten wuerde nur fuer eine konkrete Infrastruktur passen und waere selbst wieder eine
   Kopiervorlage mit falschen Annahmen; die Doku-Anleitung ist hier der robustere Weg als
   eine zweite Vorlagendatei.

## TYPO3-Pflege

- ~~**Kein Build-Prozess / keine JS-Tests**~~ **[behoben]** fuer `dashboard.js`
  (~500 Zeilen IIFE). Die Kartenfehler der letzten Iterationen (Invalid-GeoJSON-Crash,
  falsches `outline`, keine Faerbung) waeren durch einen minimalen DOM-Smoke-Test
  automatisiert aufgefallen.

  **Fix:** `Tests/JavaScript/dashboard.smoke.test.mjs` ergaenzt — laedt das echte
  Fluid-Template (nur der `<f:else>`-Zweig, keine TYPO3/Fluid-Engine noetig) und den
  echten `dashboard.js`-Quelltext in [jsdom](https://github.com/jsdom/jsdom) (MIT), mit
  Fake-Implementierungen fuer Chart.js/Leaflet statt der echten Bibliotheken (kein echtes
  Canvas/WebGL noetig, sehr schnell). Zwei Faelle: (1) mit Daten + Fake-Libs — prueft
  KPI-Rendering, dass genau ein Line- und ein Bar-Chart erzeugt werden, dass jedes an
  `L.geoJSON` uebergebene Feature `type:"Feature"` hat (genau der Fehler, der zum
  "Invalid GeoJSON object"-Crash fuehrte) und dass keine unbehandelten Exceptions
  auftreten; (2) ohne Chart.js/Leaflet — Modul muss sauber fruehzeitig abbrechen statt zu
  werfen. Verifiziert durch bewusst injizierten Bug (Test schlaegt fehl, nach Rueckbau
  wieder gruen).

  Kein Build-Prozess im engeren Sinne (kein Bundler/Transpiler) — nur `node:test` +
  `jsdom` als Dev-Dependency (`package.json`, `package-lock.json` versioniert,
  `node_modules/` ignoriert). Neue Stufe **2d** in `run-tests.sh` ergaenzt, laeuft ohne
  TYPO3/Demo-Stack. `npm test` auch direkt in `extension/sight_metrics/` ausfuehrbar.

- ~~`CubeRepository::sites()` baut das `IN (...)` per `array_map('intval', ...)` statt
  durchgaengig Named Parameters wie die uebrigen Queries~~ **[behoben]** — Stilbruch, keine
  Sicherheitsluecke (Werte waren bereits `int`-gecastet). Jetzt `createNamedParameter(...,
  ArrayParameterType::INTEGER)` wie die uebrigen Methoden der Klasse.

## Architektur

- **Skalierung ueber Kardinalitaet ungeloest**: rohe Cube-Zeilen gehen komplett an den
  Browser, Aggregation passiert clientseitig. `windowDays` begrenzt nur die Zeitachse —
  bei vielen unterschiedlichen URLs/Referrern im Fenster waechst die JSON-Payload
  unbegrenzt. Fuer grosse Sites braucht es serverseitige Top-N-Begrenzung pro Dimension
  oder Vor-Aggregation im Backend.
- **Kein Caching**: jeder Modulaufruf feuert alle Queries neu. Fuer ein Backend-Modul
  vertretbar, sollte aber dokumentiert sein (bewusste Entscheidung, kein Vergessen).

## Betrieb

- `sightmetrics:health` validiert nicht `--crit-hours >= --warn-hours`; vertauschte Werte
  ergeben stumm unsinnige Schwellenwert-Ergebnisse. **Fix:** Validierung + Fehlermeldung
  bei `critH < warnH`.

## Vendor-Provenienz (aus vorheriger Pruefung, Kontext)

- Chart.js/Leaflet werden per Ad-hoc-`curl` bezogen (kein npm-Lockfile). Fuer eine
  produktive Uebernahme mit Supply-Chain-Anforderungen: Bezug ueber Paketmanager mit
  Versions-Pinning (siehe `Resources/Public/Vendor/NOTICE.md`).
