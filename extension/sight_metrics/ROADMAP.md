# Roadmap

Offene Punkte (Stand 2026-07-02). Behobene Findings wurden entfernt, siehe Git-Historie
fuer Details zu abgeschlossenen Themen.

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

  **Blocker, der zuerst geklaert werden muss:** die Eltern-Kind-Kodierung der
  Drill-down-Dimensionen nutzt `dimkey = Elternlabel + SEP + Kindlabel`; in `dashboard.js`
  ist `SEP` aber ein **leerer String** (`var SEP = '';`). Unklar, ob das Absicht ist (echter
  Trenner steckt schon in den dimkey-Werten aus der Ingestion) oder ein bestehender Bug, der
  nur zufaellig funktioniert. Eine serverseitige Top-N-Query fuer Kind-Dimensionen muss
  exakt das gleiche Praefix-Matching wie `firstSeg()`/`childrenOf()` nachbauen — das laesst
  sich nicht sauber entwerfen, ohne das SEP-Verhalten vorher zu verstehen. **Erster Schritt
  jeder Umsetzung: SEP-Kodierung in der Ingestion-Pipeline (`transform.sql` o. ae.) und in
  `dashboard.js` nachvollziehen und dokumentieren.**

  **Grobskizze danach** (final zu entwerfen, nicht final):
  - `CubeRepository`: neue Methode `topKeys($siteId, $from, $bis, $dim, $metric, $limit)`
    (SUM($metric) GROUP BY dimkey ORDER BY total DESC LIMIT $limit) und eine Methode, die
    Zeilen nur fuer eine gegebene Menge von dimkeys bzw. einen Eltern-Praefix liefert.
  - Ein generischer neuer Controller-Endpunkt (nicht einer pro Dimension) fuer Nachladen:
    Parameter dim, optional parentKey, from, to, limit/offset.
  - `dashboard.js`: `agg()`/`childrenOf()`/`barlist()` auf asynchrones Nachladen umstellen
    (Ladezustand fuer "+ N weitere" und beim Aufklappen einer Kind-Kategorie, die nicht
    schon im initialen Payload steckt).
  - Tests: PHP Unit/Functional fuer die neuen Repository-Methoden, JS-Smoke-Test fuer den
    async Drill-down-Pfad erweitern.

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

## Vendor-Provenienz (aus vorheriger Pruefung, Kontext)

- Chart.js/Leaflet werden per Ad-hoc-`curl` bezogen (kein npm-Lockfile). Fuer eine
  produktive Uebernahme mit Supply-Chain-Anforderungen: Bezug ueber Paketmanager mit
  Versions-Pinning (siehe `Resources/Public/Vendor/NOTICE.md`).
