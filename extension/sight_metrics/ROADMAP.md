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

2. **[Hoch] Mandantentrennung nicht benutzerbezogen** — `Classes/Support/SiteSelector.php`,
   `allowedSiteIds()`. Filtert global ueber alle Site-Configs, nicht pro Backend-Benutzer.
   Leere Liste = alle Cube-Sites sichtbar. Jeder Benutzer mit Modulzugriff sieht Analytics
   aller Mandanten, unabhaengig von seinen TYPO3-Seiten-/Site-Rechten. Fuer eine Multi-Mandanten-
   Instanz (z. B. GSB11 mit mehreren Behoerden) ein Ausschlusskriterium. **Fix:** Sichtbare
   Site-IDs aus den tatsaechlichen Benutzerrechten (`$BE_USER->getWebmounts()` /
   Seitenbaum-Zugriff) statt aus einer globalen Konfigurationsliste ableiten.

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

5. **[Niedrig] Lizenz von world.js unverifiziert** — `REUSE.toml` deklariert CC0/Natural
   Earth fuer `Resources/Public/Vendor/world.js` auf Annahme, nicht auf Verifikation. Muss vor
   einer Uebergabe an das GSB11-Team bestaetigt werden (echte Quelle/Lizenz der Geodaten).

6. **[Niedrig] Fehlende Leaflet-Bildassets** — `leaflet.css` referenziert
   `images/layers.png`, `images/layers-2x.png`, `images/marker-icon.png`, die nicht
   mitgeliefert werden. Aktuell ungenutzt (keine Marker/Layer-Control aktiv), fuehrt aber zu
   404s, sobald die Karte um Marker/Layer-Steuerung erweitert wird. **Fix:** Assets ergaenzen
   oder ungenutzte Leaflet-Controls per CSS/Option explizit deaktivieren.

7. **[Niedrig] Betriebs-Vorlagen mit unsicheren Defaults** —
   `demo/app/config/system/additional.php` setzt `trustedHostsPattern = ".*"` (Host-Header-
   Injection-Risiko) und `demo/initdb/01-analytics.sh` grantet `report_ro'@'%'` (Host-Wildcard).
   Als Demo kommentiert, aber diese Dateien sind die Vorlage, die Betreiber kopieren werden.
   **Fix:** Produktions-Beispielkonfiguration separat dokumentieren mit explizitem Hostnamen/
   IP-Range statt Wildcard, deutlicher Warnhinweis im Kommentar.

## TYPO3-Pflege

- **Keine Lokalisierung der UI**: Dashboard-Texte (`dashboard.js`, Template) sind hart
  deutsch. Nur Modul-Labels liegen in `locallang_mod.xlf`. Fuer mehrsprachige Backends
  (Bund) ein Pflegepunkt.
- **Kein Build-Prozess / keine JS-Tests** fuer `dashboard.js` (~500 Zeilen IIFE). Die
  Kartenfehler der letzten Iteration waeren durch einen minimalen DOM-Smoke-Test
  (Modul laedt, Canvas/Map-Container vorhanden, keine Konsolenfehler) automatisiert
  aufgefallen.
- `CubeRepository::sites()` baut das `IN (...)` per `array_map('intval', ...)` statt
  durchgaengig Named Parameters wie die uebrigen Queries — Stilbruch, keine
  Sicherheitsluecke (Werte sind bereits `int`-gecastet).

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
