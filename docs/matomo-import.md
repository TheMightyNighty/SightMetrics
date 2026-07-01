# Matomo-Altdaten-Import

Einmaliger Import historischer Analytics-Daten aus einer bestehenden
**Matomo**-Installation in den SightMetrics-Cube - pro Kundensite, typischerweise
einmal beim Onboarding („die Kunden wollen ihre alten Daten sehen").

Der Import nutzt **Matomos Reporting-API** (JSON), nicht die Rohlogs. Damit
funktioniert er auch dann, wenn die Roh-Trackingdaten in Matomo längst per
Aufbewahrungsregel gelöscht wurden - die aggregierten Report-Archive bleiben
erhalten und genau die liefert die API.

---

## Verhältnis zum täglichen Log-Import

Beide Pfade bestehen **parallel** und schreiben in denselben Cube:

| | Compute-Skript | Treiber | Quelle |
|---|---|---|---|
| **Täglicher Betrieb** | `cube_to_mysql.sql` + `transform.sql` | `load_cube.sh` / `run_all.sh` | Webserver-Logs |
| **Altdaten (einmalig)** | `matomo_to_cube.sql` | `matomo_import.sh` | Matomo Reporting-API |

Beide erzeugen dieselben TEMP-Tabellen `daily_rows`/`cube_rows` und benutzen
denselben MariaDB-Sink **`sink_mysql.sql`**. Der Sink ersetzt immer nur den
**Datumsbereich des aktuellen Batches** (Bereichs-DELETE je `site_id`). Solange
sich die Zeiträume nicht überschneiden, stören sich die beiden Pfade nicht:

```
   Vergangenheit                      Heute / laufend
   |-------- Matomo-Import --------|---- täglicher Log-Import ---->
   2019 ............... gestern        ab Live-Schaltung
```

Praxis: Matomo-Import bis zum Tag **vor** Beginn des Log-Imports laufen lassen.
Überschneiden sich Tage, gewinnt der zuletzt geschriebene Lauf für diese Tage -
beide Quellen sind für denselben Tag nicht additiv, sondern ersetzend.

---

## Voraussetzungen

1. **Matomo-Zugang:** URL der Installation, `idSite` der Quell-Site und ein
   **Auth-Token** mit **View-Recht** auf diese Site.

   > Hinweis: Matomo authentifiziert die API ausschließlich über `token_auth`,
   > **nicht** über Benutzername/Passwort (der Passwort-→-Token-Endpoint wurde
   > aus Sicherheitsgründen entfernt). Token erzeugen in Matomo unter
   > **Administration → Persönlich → Sicherheit → Auth-Tokens**. Ein reines
   > View-Token genügt.

2. **Cube-DB:** derselbe `CUBE_DSN` wie beim Log-Import (DuckDB-MySQL-DSN).

3. Das DuckDB-Binary unter `ingestion/bin/duckdb` (wie beim Log-Import).

---

## Aufruf

```bash
cd ingestion

export MATOMO_TOKEN="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # oder MATOMO_TOKEN_FILE
export CUBE_DSN="host=... port=3306 user=cube_rw password=... database=analytics"

./matomo_import.sh \
  --url https://matomo.example.org \
  --matomo-idsite 7 \
  --site-id 3 \
  --site-name "Musterbehörde" \
  --from 2020-01-01 \
  --to   2024-12-31
```

| Parameter | Bedeutung |
|---|---|
| `--url` | Basis-URL der Matomo-Installation |
| `--matomo-idsite` | `idSite` **in Matomo** (Quelle) |
| `--site-id` | `site_id` **in SightMetrics** (Ziel im Cube) |
| `--site-name` | Anzeigename (wandert in die `meta`-Tabelle) |
| `--from` / `--to` | Zeitraum `YYYY-MM-DD` (inklusive) |
| `--json-dir DIR` | heruntergeladene JSONs behalten (sonst temporär + Auto-Cleanup) |
| `--dry-run` | nur JSON laden, **nicht** in die DB schreiben (kein `CUBE_DSN` nötig) |

### Secrets als Datei (Docker-Secrets-Pattern)

```bash
MATOMO_TOKEN_FILE=/run/secrets/matomo_token \
CUBE_DSN_FILE=/run/secrets/cube_dsn \
./matomo_import.sh --url ... --matomo-idsite 7 --site-id 3 --site-name "…" \
                   --from 2020-01-01 --to 2024-12-31
```

### Trockenlauf (Mapping prüfen, JSON ablegen)

```bash
./matomo_import.sh --url https://matomo.example.org --matomo-idsite 7 \
  --site-id 3 --site-name "Test" --from 2024-12-01 --to 2024-12-31 \
  --json-dir /tmp/matomo_check --dry-run
```

Legt die Rohantworten unter `/tmp/matomo_check/chunk_N/<dim>.json` ab.

---

## Was importiert wird

`VisitsSummary.get` → `daily` (visits, pageviews, uniques, bounces).
Pro Dimension ein Report → `cube` (`pv` ← Pageviews, `v` ← Visits):

| Cube-`dim` | Matomo-API-Methode |
|---|---|
| `url` | `Actions.getPageUrls` (`flat=1`) |
| `entry` / `exit` | `Actions.getEntryPageUrls` / `getExitPageUrls` |
| `download` | `Actions.getDownloads` |
| `country` | `UserCountry.getCountry` |
| `browser` | `DevicesDetection.getBrowsers` |
| `os` | `DevicesDetection.getOsFamilies` |
| `device` | `DevicesDetection.getType` |
| `referrer_type` | `Referrers.getReferrerType` |
| `keyword` | `Referrers.getKeywords` |
| `hour` | `VisitTime.getVisitInformationPerLocalTime` |

### Bewusste Lücken (v1)

* **`status`, `method`, `bytes`/Bandbreite:** trackt Matomo nicht → bleiben für
  historische Tage leer (`bytes`=0). Sind reine Log-Kennzahlen.
* **Zusammengesetzte Unter-Dimensionen** `browser_version`, `os_version`,
  `device_model`, `referrer_name`, `referrer_url`: Der Cube speichert deren
  `dimkey` als `Eltern\x1fKind`; Matomos flache Reports liefern den Eltern-Prefix
  nicht zuverlässig. Diese Drill-down-Ansichten bleiben für importierte Zeiträume
  leer; die übergeordneten Dimensionen (browser, os, device, referrer_type) sind
  vorhanden.
* **Sprache der Labels:** `referrer_type` trägt die Matomo-Labels (z. B.
  „Search Engines"), der Log-Pfad nutzt deutsche („Suchmaschine"). Kosmetisch.

---

## Skalierung (Sites mit Millionen Hits/Tag)

Der Import zieht **Aggregate**, keine Rohzeilen - ein Tag mit 2 Mio. Hits ergibt
nur so viele Cube-Zeilen wie es distinkte Dimensionswerte gibt. Damit bleibt der
Ansatz auch über 4-5 Jahre handhabbar.

* **Monats-Chunking:** Pro Monat ein API-Call je Report (`period=day` + Range
  liefert die Tage einzeln gebucketet). 5 Jahre ≈ 60 Chunks × 12 Reports.
* **`filter_limit`:** High-Cardinality-Dimensionen (`url`, `entry`, `exit`,
  `keyword`) werden auf **Top-N pro Tag** begrenzt (`FILTER_LIMIT_HIGH`, Default
  `1000`); Low-Cardinality-Dims (country/browser/os/device/referrer_type/hour)
  vollständig (`filter_limit=-1`). Anpassen:

  ```bash
  FILTER_LIMIT_HIGH=500 ./matomo_import.sh ...
  ```

* **Archiving:** Trifft ein Call einen in Matomo noch **nicht archivierten**
  Alt-Zeitraum, archiviert Matomo on-the-fly - bei großen Sites auf dem
  Matomo-Server spürbar. Historische Zeiträume sind i. d. R. längst archiviert;
  falls nicht, vorab beim Kunden `./console core:archive` laufen lassen.

---

## Wiederholbarkeit

Der Import ist **idempotent**: ein erneuter Lauf für denselben Zeitraum ersetzt
die betroffenen Tage (Bereichs-DELETE im Sink, dann INSERT) - die Zahlen werden
**nicht doppelt**, es entstehen keine Duplikate. Ein abgebrochener Lauf kann
gefahrlos wiederholt werden.

Der Matomo-Pfad löscht dabei den **vollen Chunk-Zeitraum** (`range_from`/
`range_to` = `--from/--to` je Monat), nicht nur die Tage mit zurückgelieferten
Daten. So werden auch Tage, die in Matomo (inzwischen) leer sind, sauber geleert
statt mit veralteten Werten stehen zu bleiben.

> Quellen sind **ersetzend, nicht additiv:** Überschreibt ein Matomo-Lauf Tage,
> die schon der Log-Import geschrieben hat, gelten danach die Matomo-Zahlen für
> diese Tage (kein Aufsummieren). Daher Matomo nur bis zum Tag vor Log-Start.

---

## Fehlerbehandlung

* Einzelne fehlschlagende Reports (HTTP-Fehler oder `"result":"error"`) werden zu
  `{}` degradiert und mit `WARN` geloggt - der Import läuft weiter, die betroffene
  Dimension bleibt für den Chunk leer. Mit `--json-dir` lassen sich die
  Rohantworten nachträglich inspizieren.
* `--dry-run` zum Prüfen von Zugang/Token/Mapping ohne DB-Schreibzugriff.
