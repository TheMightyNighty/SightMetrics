> 🇬🇧 [English version](topn-precompute-spec.md)

# Spec: Top-N-Precompute (v2.1)

Status: Implementiert (2026-07-15) — Ingestion, Leser, Frontend,
Contract-Test verifiziert (lokaler Demo-Stack + Round-Trip gegen echte
MariaDB). Additiv zu Schema v2 (`docs/SCHEMA.de.md`), kein Versionssprung
nötig. Offen: Performance-Messung auf einem großen Cube (siehe "Nach der
Implementierung zu prüfen").

**Implementierungshinweis:** Die Spalte heißt `win`, nicht `window` —
reserviertes Wort in DuckDB und MariaDB (Window-Funktionen). Gilt für alle
SQL-Ausschnitte unten.

## Problem

`CubeRepository::topN()` aggregiert bei jedem Panel-Laden live über `cube`:

```sql
SELECT dimkey, SUM(pv), SUM(v) FROM cube
WHERE site_id=? AND dim=? AND datum BETWEEN ? AND ?
GROUP BY dimkey ORDER BY <metric> DESC LIMIT ?
```

Der Index `sm_dim_datum (site_id, dim(32), datum)` (Perf-Paket,
unveröffentlicht) begrenzt den **Scan** auf den richtigen
Site/Dim/Datumsbereich, reduziert aber nicht die **Aggregationskosten**:
Bei Dimensionen mit hoher Kardinalität (`referrer_url`, `keyword`, `url`)
und langen Fenstern (ein Jahr, "gesamter Zeitraum") muss die Engine dennoch
potenziell zehntausende `(datum, dimkey)`-Zeilen gruppieren und sortieren,
bevor auf `LIMIT` gekürzt wird. Bei einem bestehenden Kunden mit 2,5 Mio.
Besuchen/Monat wird dies der nächste Engpass für lange Zeitfenster, nachdem
die vollständigen Tabellenscans bereits behoben wurden.

Dimensions-Kardinalität und Fenstergröße multiplizieren sich: Ein Jahr an
Daten auf einer großen Site kann für `referrer_url` über 365 Tage leicht
50.000+ eindeutige `dimkey`-Werte erzeugen, obwohl das Frontend
(`topn.js`) je Panel nur 8–10 Zeilen anzeigt (plus ein optionales
"+ N weitere" über `TopNAjaxController`, gedeckelt auf `limit<=100`,
`offset<=10000`).

## Nicht-Ziel

`cube` selbst ist **bereits** eine Vorberechnung (tägliches Rollup aus den
Rohzugriffen, siehe `ingestion/transform.sql`). Diese Spec fügt eine
*zweite* Precompute-Stufe hinzu: Top-K über Standard-Zeitfenster, abgeleitet
aus `cube` — nicht aus den Rohdaten.

## Design

### Neue additive Tabelle `topn`

```sql
CREATE TABLE IF NOT EXISTS topn (
  site_id INTEGER,
  win     VARCHAR(16),   -- Fenster-Label, siehe "Abgedeckte Fenster" unten; 'win'
                          -- statt 'window', da reserviertes Wort in DuckDB/MariaDB
                          -- (Window-Funktionen)
  dim     VARCHAR(32),
  parent  VARCHAR(191) NULL,
  dimkey  VARCHAR(1024),
  pv      BIGINT,
  v       BIGINT,
  rnk     SMALLINT       -- 1..K, Rang nach der für die Dimension fest hinterlegten
                          -- Metrik (TopNDims::ROOT_METRIC_BY_DIM)
);
CREATE INDEX IF NOT EXISTS sm_topn_lookup ON topn (site_id, dim(32), win(16), rnk);
```

Analog zu `sink_mysql.sql`/`v2_add_indexes.sql`: `CREATE TABLE/INDEX IF NOT
EXISTS`, keine Migration für bestehende DBs nötig (die Tabelle bleibt
schlicht leer/ungenutzt, bis die Senke sie beim nächsten Import befüllt —
bis dahin fällt der Leser auf Live-Abfragen zurück, siehe unten).

### Berechnung (Ingestion, nach dem `cube`-Insert)

Je Import und betroffener Site: die Fenster ableiten, deren Enddatum in den
gerade geschriebenen Tagesbereich fällt (effektiv "alle" bei einem
täglichen Lauf), frisch aus `cube` über `DELETE site_id+window` +
`INSERT` — dasselbe Ersetzungsmuster wie bei `daily`/`cube` selbst
(Runbook §8, Tagesgrenzen-Cut).

```sql
-- Für jedes (Fenster, Dimension) mit dimensionsspezifischer Metrik (siehe TopNDims):
INSERT INTO topn
  SELECT site_id, '<window>' AS win, dim, parent, dimkey, pv, v, rnk FROM (
    SELECT site_id, dim, parent, dimkey, SUM(pv) pv, SUM(v) v,
           ROW_NUMBER() OVER (PARTITION BY dim, parent ORDER BY SUM(<metric>) DESC) AS rnk
    FROM cube
    WHERE site_id=? AND dim IN (<root-Dimensionen ohne parent>) AND datum BETWEEN <window_start> AND <window_end>
    GROUP BY site_id, dim, parent, dimkey
  ) WHERE rnk <= 100
```

`<metric>` ist je `dim` fest hinterlegt (pv oder v,
`TopNDims::ROOT_METRIC_BY_DIM`) — die `UNION ALL`-Struktur aus
`transform.sql` (Zeilen 189ff.) kann hier direkt wiederverwendet werden,
lediglich mit `cube` statt `sess`/`visits` als Quelle, und
`ROW_NUMBER() ... QUALIFY`/Subquery-Cutoff statt eines schlichten
`GROUP BY`.

K=100 wurde gewählt, weil `TopNAjaxController` `limit` auf 100 deckelt —
die Vorberechnung deckt damit genau die erste "Seite" jeder Pagination ab.

### Abgedeckte Fenster

Fenster, die (a) vom Import-Zeitstempel aus kalenderdeterministisch sind
(keine "custom"-Bereiche) und (b) tatsächlich teuer:

| Fenster | Definition | Warum vorberechnet |
|---|---|---|
| `last30` | rollierende 30 Tage | häufigstes Preset, vorsorglich mit aufgenommen (noch nicht gemessen, ob nötig) |
| `last90` | rollierende 90 Tage | hier wird ein Live-`GROUP BY` spürbar |
| `last365` | rollierende 365 Tage | größte gängige Fensterwahl |
| `thisyear` / `lastyear` | Kalenderjahr | Preset im Frontend (`presets.js`) |
| `all` | der gesamte Datenbestand der Site | teuerste Abfrage, meta.von..meta.bis |

**Nicht** vorberechnet: `today`, `yesterday`, `thismonth`, `lastmonth` —
kurze Fenster, für die der Index bereits ausreicht (siehe die
Perf-Messung: 1,2 s→0,3 s bei ca. 870.000 Zeilen), sowie einzelne
vergangene Jahre (`year:YYYY`) — zu selten gewählt, um den Pflegeaufwand
zu rechtfertigen (kann später bei Bedarf ergänzt werden, da additiv).

**Drill-down-Kinder (`parent` gesetzt) werden bereits in v1
vorberechnet**, z. B. `browser_version` unter jedem `browser`,
`referrer_url` unter jedem `referrer_name`. Dies multipliziert die
Zeilenzahl mit der Parent-Kardinalität
(`Fenster × Dimension × Parent-Anzahl × 100`) — noch nicht gemessen, ob
dies für Referrer-lastige Sites relevant ist; siehe "Nach der
Implementierung zu prüfen" unten. Die `INSERT`-Struktur ist identisch zu
den Root-Dimensionen, lediglich `PARTITION BY dim, parent` statt
`PARTITION BY dim`, und `parent IS NOT NULL`.

### Leser-Integration (`CubeRepository::topN()`)

```
wenn window (vom Frontend gesendet) in SUPPORTED_WINDOWS && offset < 100:
    → SELECT aus `topn` (site_id, dim, parent, win, rnk BETWEEN offset+1 AND offset+limit)
sonst:
    → bestehende Live-Abfrage (unverändert)
```

Das Frontend kennt bereits das gewählte Preset (`w-preset`-Wert in
`presets.js`) und sendet es als zusätzlichen, optionalen Query-Parameter
`window` an `TopNAjaxController` (additiv, kein Bruch der bestehenden
API — alte Clients ohne den Parameter fallen automatisch auf den
Live-Pfad zurück). Der Server **vertraut** dem Label nicht blind: Er
validiert serverseitig (Site-Zeitzone `meta.tz`, heutiges Datum), dass die
vom Client übermittelten `from`/`to` tatsächlich der Kalenderdefinition des
behaupteten `window`-Werts entsprechen — weichen sie ab (z. B.
Client-Uhrdrift, veraltete Preset-Liste), wird die Anfrage als "kein
vorberechnetes Fenster" behandelt und läuft live. Diese Validierung ist
einfacher als die Rekonstruktion des Fensters allein aus `from`/`to` (kein
Raten, welches Preset gemeint war), während der Server alleinige Quelle der
Kalenderlogik bleibt.

`dimSummary()` (Gesamtsumme + `COUNT(DISTINCT dimkey)` für die
Prozentanzeige und "+ N weitere") bleibt **unverändert, live** — es ist ein
einzelner aggregierter Skalarwert über den Index, bereits günstig, und muss
exakt sein (nicht auf Top-K gedeckelt).

### Migration / Rollout

- Additiv, kein `schema_version`-Sprung.
  `ingestion/migrations/v2_add_topn.sql` analog zu `v2_add_indexes.sql`
  für bestehende DBs (legt Tabelle+Index an; die erste Befüllung geschieht
  automatisch beim nächsten Import).
- Gebündelt mit dem Perf-Paket als **v2.1** (siehe die
  `release-plan-v21`-Erinnerung).
- CHANGELOG-Eintrag unter "Unreleased" → "Performance", mit denselben
  Vorher/Nachher-Zahlen wie beim Index-Paket, aber speziell für
  `last365`/`all` bei Dimensionen mit hoher Kardinalität (`referrer_url`,
  `keyword`, `url`) auf dem 867.000-Zeilen-Test-Cube.

### Tests

- **Contract-Test-Erweiterung** (`tests/contract/run.sh` /
  `CubeContractTest`): für mindestens eine Root-Dimension mit hoher
  Kardinalität und eine Drill-down-Dimension verifizieren, dass `topN()`
  mit einem vorberechneten Fenster identische Ergebnisse liefert wie eine
  Referenzabfrage, die direkt gegen `cube` berechnet wird
  (Regressionsschutz gegen Drift zwischen der `topn`- und der
  `cube`-Tabelle).
- **Fallback-Test**: `offset>=100`, ein unbekanntes/fehlendes
  `window`-Label sowie ein `window`-Label, das nicht zu den übermittelten
  `from`/`to` passt, liefern weiterhin korrekte Ergebnisse über den
  Live-Pfad.
- **Perf-Test** (siehe "Nach der Implementierung zu prüfen" unten):
  `last365`/`all` bei `referrer_url`/`keyword`/`url` vorher/nachher,
  derselbe 867.000-Zeilen-Test-Cube wie beim Index-Paket, damit die Zahlen
  vergleichbar bleiben.

## Entscheidungen (2026-07-15, mit Robert)

1. **Fensterliste**: `last30`, `last90`, `last365`, `thisyear`, `lastyear`,
   `all` — `last30` zusätzlich zum ursprünglichen Vorschlag aufgenommen
   (vorsorglich, ungemessen). Einzelne Jahre (`year:YYYY`) bleiben außen
   vor.
2. **Fenster-Label**: Das Frontend sendet `window` (das Preset-Label)
   zusätzlich zu `from`/`to` an `TopNAjaxController`; additiver Parameter,
   der Server validiert dagegen (siehe Leser-Integration oben).
3. **Drill-down-Kinder**: bereits in v1 vorberechnet (nicht verschoben).
4. **Import-Overhead**: wird **nach** der Implementierung gemessen (nicht
   als vorgelagertes Gate) — erst bauen, dann Perf-Check.

### Nach der Implementierung zu prüfen

Da die Entscheidungen 3+4 zusammen das Risiko erhöhen (Drill-down-Precompute
multipliziert die Zeilenzahl, und die Messung erfolgt erst nachträglich):
nach dem ersten funktionierenden Lauf auf dem 867.000-Zeilen-Test-Cube
explizit prüfen — (a) Import-Zeit vorher/nachher (Zielkorridor <10% länger,
kein hartes Gate, aber ein Warnsignal bei deutlicher Überschreitung),
(b) Zeilenzahl der `topn`-Tabelle für Referrer-lastige Testdaten
(`referrer_name`→`referrer_url` ist der Drill-down-Kandidat mit der höchsten
Kardinalität). Ergebnis in den finalen CHANGELOG-Eintrag aufnehmen.
