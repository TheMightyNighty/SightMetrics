> 🇬🇧 [English version](SCHEMA.md)

# SightMetrics-Cube-Datenbankschema (normativer Contract)

Dieses Dokument ist der **Contract zwischen Paket A (Ingestion, Schreiber)
und Paket B (TYPO3-Extension, Leser)**. Die beiden Pakete teilen sich
keinen Code — nur diese Tabellen. Jede Änderung, die Leser bricht, MUSS die
Schema-Version erhöhen und hier dokumentiert werden.

- Schreiber: `ingestion/sink_mysql.sql` deklariert `sm_schema_version` und
  schreibt sie bei jedem Import in `meta.schema_version`.
- Leser: `CubeRepository::SCHEMA_VERSION` ist die Schema-Version, die die
  Extension erfordert. Seit v2 benötigt der Leser eine **exakte
  Übereinstimmung**: Eine neuere Version bricht mit der Aufforderung ab, die
  Extension zu aktualisieren; eine ältere/fehlende Version bricht mit einem
  Verweis auf die Migration (`ingestion/migrations/v1_to_v2.sql`) oder einen
  Re-Import ab. Sowohl das Backend-Modul als auch `sightmetrics:health`
  erzwingen dies.

## Aktuelle Version: 2

Tabellennamen sind konfigurierbar
(`SM_TABLE_CUBE`/`SM_TABLE_DAILY`/`SM_TABLE_META`, Standard
`cube`/`daily`/`meta`).

### `cube` — Tagesaggregate je Dimensionswert

| Spalte | Typ | Bedeutung |
|---|---|---|
| `site_id` | INTEGER | Site, zu der die Zeile gehört (Multi-Site) |
| `datum` | DATE | Tag in der Zeitzone der Site (`meta.tz`, Standard UTC) |
| `dim` | VARCHAR | Dimension: `url`, `status`, `method`, `hour`, `download`, `entry`, `exit`, `referrer_type`, `referrer_name`, `referrer_url`, `keyword`, `country`, `browser`, `browser_version`, `os`, `os_version`, `device`, `device_model` |
| `parent` | VARCHAR NULL | Übergeordneter Wert für Drill-down-Dimensionen (`browser_version` → Browsername, `os_version` → OS-Name, `device_model` → Gerätetyp, `referrer_name` → referrer_type-Schlüssel, `referrer_url` → Referrer-Name); NULL für Root-Dimensionen |
| `dimkey` | VARCHAR | Dimensionswert (unverändert; seit v2 keine `CHR(31)`-Kodierung) |
| `pv` | BIGINT | Seitenaufrufe (bei `status`: alle Nicht-Bot-Zugriffe inkl. 4xx/5xx) |
| `v` | BIGINT | Besuche (bei `status`: eindeutig betroffene Besucher) |

`referrer_type`-Werte sind seit v2 sprachneutrale Schlüssel: `direct`,
`search`, `social`, `website`. Anzeigebeschriftungen liegen im Leser
(Extension-XLF).

### `daily` — eine Zeile je Site und Tag

| Spalte | Typ |
|---|---|
| `site_id` | INTEGER |
| `datum` | DATE |
| `visits`, `pageviews`, `uniques`, `bounces`, `bytes` | BIGINT |

### `meta` — eine Zeile je Site (bei jedem Import ersetzt)

| Spalte | Typ | Bedeutung |
|---|---|---|
| `site_id` | INTEGER | |
| `site` | VARCHAR | Anzeigename |
| `von`, `bis` | VARCHAR | Erster/letzter Tag mit Daten (`YYYY-MM-DD`) |
| `visits_total`, `pageviews_total`, `uniques_total`, `bounces_total`, `bytes_total` | BIGINT | Summen über `daily` (`uniques_total` additiv approximiert) |
| `erzeugt` | VARCHAR | Zeitstempel des letzten Imports (`YYYY-MM-DD HH:MM`) |
| `tz` | VARCHAR | für `datum`/`hour`-Bündelung verwendete Site-Zeitzone (`SM_TZ`, z. B. `Europe/Berlin`; seit v2) |
| `schema_version` | INTEGER | von der Ingestion geschriebene Contract-Version (seit v1; NULL = Altbestand) |

## `topn` — vorberechnete Top-N-Zeilen (additiv, seit 2026-07)

Beschleunigt `CubeRepository::topN()` für die Standard-Preset-Fenster ohne
ein Live-`GROUP BY` über den gesamten Zeitraum bei Dimensionen mit hoher
Kardinalität. Wird bei jedem Import vollständig aus `cube` neu berechnet
(`sink_mysql.sql`); Leser müssen fehlende/veraltete Zeilen als "nicht
verfügbar" behandeln und auf eine Live-Abfrage zurückfallen — diese Tabelle
ist ein Cache, keine Quelle der Wahrheit. Details:
`docs/topn-precompute-spec.de.md`.

| Spalte | Typ | Bedeutung |
|---|---|---|
| `site_id` | INTEGER | |
| `win` | VARCHAR | einer von `last30`, `last90`, `last365`, `thisyear`, `lastyear`, `all` (heißt `win`, nicht `window` -- reserviertes Wort in DuckDB/MariaDB) |
| `dim` | VARCHAR | siehe `cube.dim`; nur Dimensionen, die in `TopNDims::ROOT_METRIC_BY_DIM`/`CHILD_METRIC_BY_DIM` gelistet sind |
| `parent` | VARCHAR NULL | `NULL` = flache Root-Dimensions-Liste (kein Parent-Filter, entspricht `topN()` mit `parentKey=null`); gesetzt = Drill-down-Kinder dieses Parent-Werts |
| `dimkey` | VARCHAR | wie `cube.dimkey` |
| `pv`, `v` | BIGINT | über das Fenster summiert |
| `rnk` | SMALLINT | Rang 1..100 innerhalb von `(win, dim, parent)`, nach der für die Dimension fest hinterlegten Metrik (`pv` oder `v`) |

## Indizes (additiv, kein Versionssprung)

Der Schreiber legt für den Leser Abfrageindizes an (idempotent,
`CREATE INDEX IF NOT EXISTS` bei jedem Import; für große bestehende Cubes
erlaubt `ingestion/migrations/v2_add_indexes.sql`, sie zu einem
kontrollierten Zeitpunkt zu erstellen):

| Index | Spalten | Dient |
|---|---|---|
| `sm_dim_datum` | `cube (site_id, dim(32), datum)` | alle Top-N-/Summary-Abfragen je Panel |
| `sm_drilldown` | `cube (site_id, dim(32), parent(191), datum)` | Drill-down-Kind-Abfragen (erst seit der v2-`parent`-Spalte möglich) |
| `sm_daily` | `daily (site_id, datum)` | Tagesverlauf/KPI-Fenster |
| `sm_topn_lookup` | `topn (site_id, dim(32), win(16), parent(191), rnk)` | Top-N-Precompute-Lookup |

## Vom Schreiber garantierte Semantik

- Ein Tag wird erst geschrieben, wenn er **vollständig** ist
  (Tagesgrenzen-Cut, Runbook §8); Tage des aktuellen Batches werden je Site
  atomar ersetzt (`DELETE`-Bereich + `INSERT`).
- Bot-/Crawler-Zugriffe werden ausgeschlossen (UA-Heuristik/
  device-detector-Liste, `SM_BOT_FILTER`).
- `datum`- und `hour`-Bündelung folgen der Site-Zeitzone `SM_TZ`
  (geschrieben nach `meta.tz`; Standard UTC). Der Tagesgrenzen-Cut des
  inkrementellen Imports verwendet dieselbe Zeitzone, sodass ein Tag erst
  geschrieben wird, wenn er in **lokaler** Zeit vollständig ist.
- Exakte tagesübergreifende eindeutige Besucher sind **konstruktionsbedingt
  unmöglich**: Der Besucher-Hash wird pro Import-Tag gesalzen, genau damit
  Besucher nicht über Tage hinweg verknüpft werden können (Privacy by
  Design, Zielgruppe DSGVO/BSI). `uniques_total` und jede tagesübergreifende
  Eindeutigkeits-Kennzahl bleiben daher additive Näherungen, in der Oberfläche
  entsprechend gekennzeichnet. Dies ist ein bewusster, dauerhafter
  Kompromiss, keine Lücke.
- Datenbankbenutzer: Schreiber `cube_rw` (volles DML), Leser `report_ro`
  (nur `SELECT`).

## Contract-Test

`tests/contract/run.sh` erzwingt dieses Dokument mechanisch: Es importiert
`ingestion/tests/fixture.log` über die echte Ingestion in die Demo-MariaDB
(Site 990, eingebaute Heuristiken für Determinismus erzwungen) und liest
die Zahlen anschließend über den `CubeRepository` der Extension zurück
(`Tests/Functional/CubeContractTest.php`, Read-Only-Benutzer `report_ro`).
Läuft lokal (`bash tests/contract/run.sh`, benötigt Docker) und in CI
(E2E-Job).

## Versionshistorie

| Version | Datum | Änderung |
|---|---|---|
| 2 | 2026-07-08 | Tagesgrenzen in lokaler Zeit (`SM_TZ` → `meta.tz`); `cube.parent`-Spalte ersetzt die `CHR(31)`-Dimkey-Kodierung; `referrer_type`-Werte werden zu neutralen Schlüsseln (`direct`/`search`/`social`/`website`); Leser erfordert exakte Versionsübereinstimmung. Migration: `ingestion/migrations/v1_to_v2.sql` (oder Re-Import) |
| 1 | 2026-07-07 | Erster versionierter Contract; ergänzt `meta.schema_version` (ältere Datenbanken: Spalte fehlt = Altbestand, lesekompatibel) |

## Regeln für künftige Änderungen

- **Additive** Änderungen (neue Dimensionswerte, neue nullable Spalten):
  kein Versionssprung erforderlich; Leser müssen unbekannte Spalten/
  Dimensionen ignorieren.
- **Breaking** Änderungen (Spaltenumbenennung/-entfernung, Typ- oder
  Semantikänderung): `sm_schema_version` in `ingestion/sink_mysql.sql`
  erhöhen, `CubeRepository::SCHEMA_VERSION` im selben Release anheben und
  die Migration hier dokumentieren.
