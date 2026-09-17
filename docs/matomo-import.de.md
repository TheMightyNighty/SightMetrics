> 🇬🇧 [English version](matomo-import.md)

# Matomo-Altdaten-Import

Einmaliger Import historischer Analytics-Daten aus einer bestehenden
**Matomo**-Installation in den SightMetrics-Cube — pro Kundensite,
typischerweise einmalig beim Onboarding ("Kunden wollen ihre alten Daten
sehen").

Der Import nutzt **Matomos Reporting-API** (JSON), nicht die Rohlogs. Das
bedeutet, er funktioniert auch dann noch, wenn Matomos rohe Tracking-Daten
längst durch eine Aufbewahrungsregel gelöscht wurden — die aggregierten
Report-Archive bleiben erhalten, und genau die liefert die API zurück.

---

## Unterstützte Matomo-Version

Getestet und unterstützt wird ausschließlich **das aktuelle
Matomo-Release** (Stand dieses Dokuments: **5.12.0**). Kompatibilität mit
älteren Matomo-/Piwik-Versionen wird bewusst **nicht** angestrebt oder
getestet — die Matomo-Instanz des Kunden sollte vor dem Altdaten-Import
innerhalb von Matomo selbst aktualisiert werden (Matomos eigener,
gut dokumentierter Update-Pfad), statt hier Versions-Fallbacks zu
pflegen.

**Warum das besonders für `browser`/`os`/`device` wichtig ist:** diese
drei Dimensionen nutzen die API-Methoden
`DevicesDetection.getBrowsers`, `DevicesDetection.getOsFamilies`,
`DevicesDetection.getType`. Das Plugin `DevicesDetection` hat in älteren
Matomo-/Piwik-Versionen die früheren Endpunkte
`UserSettings.getBrowser`/`getOS` ersetzt — auf einer nicht
aktualisierten Altinstallation könnten diese Aufrufe fehlschlagen. Das
würde den Import nicht abbrechen (siehe "Fehlerbehandlung" unten:
einzelne fehlschlagende Reports degradieren zu `{}` mit einer `WARN`),
aber die drei Dimensionen blieben für den Kunden **stillschweigend leer**,
falls niemand das Log prüft — ein weiterer Grund, erst zu aktualisieren,
statt es einfach laufen zu lassen und zu hoffen.

---

## Verifizierung

`ingestion/tests/matomo/docker-compose.yml` richtet eine Wegwerf-
Matomo-Instanz ein, um den Importer gegen ein reales Matomo-Release zu
verifizieren; siehe `ingestion/tests/matomo_fixture/README.md` für die
genauen Schritte (Installation, Seeding, Erfassen einer Fixture), erneut
auszuführen, sobald die unterstützte Matomo-Version angehoben wird. Die
eingefrorene, aus einem solchen Lauf stammende reale Fixture ist unter
`ingestion/tests/matomo_fixture/` eingecheckt und wird von zwei
automatisierten Tests abgedeckt: `ingestion/tests/matomo_pipeline_test.sql`
(Parsing/Mapping, nur DuckDB) und
`CubeContractTest::testMatomoContractFixtureRoundTrip` (vollständiger
Roundtrip durch die reale Cube-DB und `CubeRepository`).

Ein Abgleich derselben Eingabe über den Log-Pfad und den Matomo-Pfad
zeigt: `daily.visits`/`daily.pageviews`/`daily.bounces` stimmen exakt
überein; `daily.uniques` weicht geringfügig ab (die beiden Systeme
deduplizieren eindeutige Besucher leicht unterschiedlich);
`referrer_type` kann sich bei mehrdeutigen Referrer-Domains um eine
Handvoll Besuche unterscheiden (die beiden Systeme pflegen unabhängige
Referrer-Klassifikationstabellen).

---

## Verhältnis zum täglichen Log-Import

Beide Pfade laufen **parallel** und schreiben in denselben Cube:

| | Compute-Skript | Treiber | Quelle |
|---|---|---|---|
| **Täglicher Betrieb** | `cube_to_mysql.sql` + `transform.sql` | `load_cube.sh` / `run_all.sh` | Webserver-Logs |
| **Altdaten (einmalig)** | `matomo_to_cube.sql` | `matomo_import.sh` | Matomo-Reporting-API |

Beide erzeugen dieselben TEMP-Tabellen `daily_rows`/`cube_rows` und nutzen
dieselbe MariaDB-Senke **`sink_mysql.sql`**. Die Senke ersetzt immer nur
den **Datumsbereich des aktuellen Batches** (Bereichs-`DELETE` pro
`site_id`). Solange sich die Zeiträume nicht überschneiden, stören sich
die beiden Pfade nicht:

```
   Vergangenheit                       Heute / laufend
   |-------- Matomo-Import ---------|---- täglicher Log-Import ---->
   2019 ................ gestern       seit Go-Live
```

In der Praxis: den Matomo-Import bis zum Tag **vor** Beginn des
Log-Imports laufen lassen. Überschneiden sich Tage, gewinnt für diese
Tage der zuletzt geschriebene Lauf — die beiden Quellen addieren sich
nicht für denselben Tag, sie ersetzen sich gegenseitig.

---

## Voraussetzungen

1. **Matomo-Zugang:** URL der Installation, die `idSite` der Quell-Site
   und ein **Auth-Token** mit **Leserechten** auf dieser Site.

   > Hinweis: Matomo authentifiziert die API ausschließlich über
   > `token_auth`, **nicht** über Benutzername/Passwort (der
   > Passwort-zu-Token-Endpunkt wurde aus Sicherheitsgründen entfernt).
   > Ein Token in Matomo unter **Administration → Personal → Security →
   > Auth tokens** erstellen. Ein einfacher View-Token genügt.

2. **Cube-DB:** dieselbe `CUBE_DSN` wie beim Log-Import (DuckDB-MySQL-DSN).

3. Das DuckDB-Binary unter `ingestion/bin/duckdb` (wie beim Log-Import).

---

## Verwendung

```bash
cd ingestion

export MATOMO_TOKEN="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # oder MATOMO_TOKEN_FILE
export CUBE_DSN="host=... port=3306 user=cube_rw password=... database=analytics"

./matomo_import.sh \
  --url https://matomo.example.org \
  --matomo-idsite 7 \
  --site-id 3 \
  --site-name "Sample Authority" \
  --from 2020-01-01 \
  --to   2024-12-31
```

| Parameter | Bedeutung |
|---|---|
| `--url` | Basis-URL der Matomo-Installation |
| `--matomo-idsite` | `idSite` **in Matomo** (Quelle) |
| `--site-id` | `site_id` **in SightMetrics** (Ziel im Cube) |
| `--site-name` | Anzeigename (geht in die Tabelle `meta`) |
| `--from` / `--to` | Zeitraum `YYYY-MM-DD` (einschließlich) |
| `--json-dir DIR` | die heruntergeladenen JSON-Dateien behalten (sonst temporär + automatische Bereinigung) |
| `--dry-run` | lädt nur JSON, schreibt **nicht** in die DB (keine `CUBE_DSN` nötig) |

### Secrets als Datei (Docker-Secrets-Muster)

```bash
MATOMO_TOKEN_FILE=/run/secrets/matomo_token \
CUBE_DSN_FILE=/run/secrets/cube_dsn \
./matomo_import.sh --url ... --matomo-idsite 7 --site-id 3 --site-name "…" \
                   --from 2020-01-01 --to 2024-12-31
```

### Dry-Run (Mapping prüfen, JSON behalten)

```bash
./matomo_import.sh --url https://matomo.example.org --matomo-idsite 7 \
  --site-id 3 --site-name "Test" --from 2024-12-01 --to 2024-12-31 \
  --json-dir /tmp/matomo_check --dry-run
```

Speichert die Rohantworten unter `/tmp/matomo_check/chunk_N/<dim>.json`.

---

## Was importiert wird

`VisitsSummary.get` → `daily` (visits, pageviews, uniques, bounces).
Ein Report pro Dimension → `cube` (`pv` ← pageviews, `v` ← visits):

| Cube-`dim` | Matomo-API-Methode |
|---|---|
| `url` | `Actions.getPageUrls` (`flat=1`) |
| `entry` / `exit` | `Actions.getEntryPageUrls` / `getExitPageUrls` |
| `download` | `Actions.getDownloads` |
| `country` | `UserCountry.getCountry` (über das ISO-2-`code`-Feld, nicht den Anzeigenamen `label`) |
| `browser` | `DevicesDetection.getBrowsers` |
| `os` | `DevicesDetection.getOsFamilies` |
| `device` | `DevicesDetection.getType` |
| `referrer_type` | `Referrers.getReferrerType` |
| `keyword` | `Referrers.getKeywords` |
| `hour` | `VisitTime.getVisitInformationPerLocalTime` |

### Bekannte Lücken (v1)

* **`status`, `method`, `bytes`/Bandbreite:** Matomo erfasst diese nicht →
  bleiben für historische Tage leer (`bytes`=0). Das sind rein
  log-abgeleitete Metriken.
* **Zusammengesetzte Unter-Dimensionen** `browser_version`,
  `os_version`, `device_model`, `referrer_name`, `referrer_url`: der
  Cube speichert deren `dimkey` als `parent\x1fchild`; Matomos flache
  Reports liefern das Parent-Präfix nicht zuverlässig. Diese
  Drill-down-Ansichten bleiben für importierte historische Zeiträume
  leer; die Parent-Dimensionen (browser, os, device, referrer_type) sind
  vorhanden.
* **Label-Sprache:** `referrer_type` trägt Matomos eigene Labels (z. B.
  "Search Engines"); diese werden in `matomo_to_cube.sql` auf die
  neutralen Keys des Vertrags (`direct`/`search`/`social`/`website`)
  gemappt — das ist also eigentlich keine Anzeigesprache-Lücke, sondern
  nur ein Hinweis darauf, dass sich die Quell-Labels von denen des
  Log-Pfads unterscheiden, falls dieses Mapping jemals um einen noch
  nicht abgedeckten Matomo-Referrer-Typ erweitert werden muss.

---

## Skalierung (Sites mit Millionen Hits/Tag)

Der Import zieht **Aggregate**, keine Rohzeilen — ein Tag mit 2 Mio. Hits
ergibt nur so viele Cube-Zeilen, wie es unterschiedliche
Dimensionswerte gibt. Das hält den Ansatz auch über 4–5 Jahre handhabbar.

* **Monatliches Chunking:** ein API-Aufruf pro Report pro Monat
  (`period=day` + Range liefert die Tage in einem Aufruf einzeln
  gebuckelt). 5 Jahre ≈ 60 Chunks × 12 Reports.
* **`filter_limit`:** hochkardinale Dimensionen (`url`, `entry`, `exit`,
  `keyword`) werden auf **Top-N pro Tag** begrenzt (`FILTER_LIMIT_HIGH`,
  Standard `1000`); niedrigkardinale Dimensionen
  (country/browser/os/device/referrer_type/hour) werden vollständig
  gezogen (`filter_limit=-1`). Anpassbar über:

  ```bash
  FILTER_LIMIT_HIGH=500 ./matomo_import.sh ...
  ```

* **Archivierung:** trifft ein Aufruf auf einen historischen Zeitraum,
  den Matomo noch nicht archiviert hat, archiviert Matomo ihn on the
  fly — bei großen Sites auf dem Matomo-Server spürbar. Historische
  Zeiträume sind meist schon archiviert; falls nicht, vorab
  `./console core:archive` auf dem Matomo des Kunden ausführen.

---

## Wiederholbarkeit

Der Import ist **idempotent**: ein erneuter Lauf für denselben Zeitraum
ersetzt die betroffenen Tage (Bereichs-`DELETE` in der Senke, dann
`INSERT`) — Zahlen werden **nicht dupliziert**. Ein abgebrochener Lauf
kann gefahrlos wiederholt werden.

Der Matomo-Pfad löscht den **gesamten Chunk-Bereich**
(`range_from`/`range_to` = `--from`/`--to` pro Monat), nicht nur die
Tage, die tatsächlich Daten geliefert haben. So werden Tage, die in
Matomo (mittlerweile) leer sind, sauber geleert statt mit veralteten
Werten stehen zu bleiben.

> Quellen **ersetzen sich, sie addieren sich nicht:** überschreibt ein
> Matomo-Lauf Tage, die der Log-Import bereits geschrieben hat, gewinnen
> für diese Tage die Matomo-Zahlen (keine Summierung). Deshalb sollte
> Matomo nur bis zum Tag vor Beginn des Log-Imports laufen.

---

## Fehlerbehandlung

* Einzelne fehlschlagende Reports (HTTP-Fehler oder
  `"result":"error"`) degradieren zu `{}` und werden mit `WARN`
  geloggt — der Import läuft weiter, die betroffene Dimension bleibt für
  diesen Chunk leer. Mit `--json-dir` lassen sich die Rohantworten
  anschließend prüfen.
* `--dry-run`, um Zugriff/Token/Mapping ohne DB-Schreibzugriff zu
  prüfen. **Vor jedem echten Kundenimport empfohlen**, insbesondere um
  die `DevicesDetection`-Falle (siehe "Unterstützte Matomo-Version"
  oben) frühzeitig zu erkennen: vor dem Import des vollständigen
  Zeitraums in `--json-dir` prüfen, ob `browser.json`/`os.json`/
  `device.json` echte Daten oder nur `{}` enthalten.
