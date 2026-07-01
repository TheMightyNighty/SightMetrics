-- ===========================================================================
-- SightMetrics - Matomo-Altdaten-Import: Reporting-API-JSON -> cube_rows/daily_rows.
-- Compute-Teil des Matomo-Pfads (analog zu cube_to_mysql.sql beim Log-Pfad).
-- Erzeugt dieselben TEMP-Tabellen daily_rows / cube_rows; der gemeinsame
-- MariaDB-Sink (sink_mysql.sql) wird von matomo_import.sh angehaengt.
--
-- Parameter (SET VARIABLE, durch matomo_import.sh gesetzt):
--   jsondir    Verzeichnis mit den heruntergeladenen Report-JSONs (eine Datei
--              je Dimension, plus daily.json). Fehlende Dateien sind erlaubt.
--   site_id, site_name  -> vom Sink benoetigt.
--
-- JSON-Form je Datei (period=day + Datums-Range -> nach Datum gekeyt):
--   daily.json:  { "YYYY-MM-DD": { nb_visits, nb_actions, ... }, ... }
--   <dim>.json:  { "YYYY-MM-DD": [ { label, nb_visits, nb_actions, ... }, ... ] }
-- Mapping: v <- nb_visits, pv <- nb_actions (bzw. nb_hits bei Actions-Reports).
-- ===========================================================================

-- ---- daily_rows aus VisitsSummary.get -------------------------------------
-- bytes bleibt 0 (Matomo trackt keine Bandbreite pro Tag wie der Log-Pfad).
CREATE OR REPLACE TEMP TABLE daily_doc AS
  SELECT json(content) j FROM read_text(getvariable('jsondir') || '/daily.json');

CREATE OR REPLACE TEMP TABLE daily_rows AS
SELECT d::DATE AS datum,
       COALESCE((json_extract_string(j -> d, 'nb_visits'))::BIGINT, 0)        AS visits,
       COALESCE((json_extract_string(j -> d, 'nb_actions'))::BIGINT, 0)       AS pageviews,
       COALESCE((json_extract_string(j -> d, 'nb_uniq_visitors'))::BIGINT, 0) AS uniques,
       COALESCE((json_extract_string(j -> d, 'bounce_count'))::BIGINT, 0)     AS bounces,
       0::BIGINT                                                              AS bytes
FROM daily_doc, unnest(json_keys(j)) AS t(d)
WHERE json_type(j -> d) = 'OBJECT';

-- ---- Generischer Dimensions-Reader ----------------------------------------
-- file:    Dateiname relativ zu jsondir (z. B. 'country.json')
-- dimname: Ziel-dim im Cube
-- pv_field/v_field: Matomo-Felder fuer pv (pageviews) und v (visits)
-- matomo_import.sh legt fuer jede Dimension eine Datei an (leere/fehlende
-- Reports als '{}'), daher liefert json_keys() dann 0 Zeilen.
-- Nicht-Array-Tage werden uebersprungen.
CREATE OR REPLACE TEMP MACRO dim_rows(file, dimname, pv_field, v_field) AS TABLE
  WITH doc AS (
    SELECT json(content) j
    FROM read_text(getvariable('jsondir') || '/' || file)
  )
  SELECT d::DATE AS datum,
         dimname AS dim,
         json_extract_string(elem, 'label') AS dimkey,
         COALESCE((json_extract_string(elem, pv_field))::BIGINT, 0) AS pv,
         COALESCE((json_extract_string(elem, v_field))::BIGINT, 0)  AS v
  FROM doc,
       unnest(json_keys(j)) AS t(d),
       unnest(CASE WHEN json_type(j -> d) = 'ARRAY' THEN CAST(j -> d AS JSON[]) ELSE CAST([] AS JSON[]) END) AS e(elem)
  WHERE json_extract_string(elem, 'label') IS NOT NULL;

CREATE OR REPLACE TEMP TABLE cube_rows AS
SELECT * FROM (
  SELECT * FROM dim_rows('url.json',      'url',           'nb_hits',         'nb_visits')
  UNION ALL SELECT * FROM dim_rows('download.json', 'download',      'nb_hits',         'nb_visits')
  UNION ALL SELECT * FROM dim_rows('entry.json',    'entry',         'entry_nb_actions','entry_nb_visits')
  UNION ALL SELECT * FROM dim_rows('exit.json',     'exit',          'nb_hits',         'exit_nb_visits')
  UNION ALL SELECT * FROM dim_rows('country.json',  'country',       'nb_actions',      'nb_visits')
  UNION ALL SELECT * FROM dim_rows('browser.json',  'browser',       'nb_actions',      'nb_visits')
  UNION ALL SELECT * FROM dim_rows('os.json',       'os',            'nb_actions',      'nb_visits')
  UNION ALL SELECT * FROM dim_rows('device.json',   'device',        'nb_actions',      'nb_visits')
  UNION ALL SELECT * FROM dim_rows('reftype.json',  'referrer_type', 'nb_actions',      'nb_visits')
  UNION ALL SELECT * FROM dim_rows('keyword.json',  'keyword',       'nb_actions',      'nb_visits')
  -- hour: dimkey auf '00'..'23' normalisieren (Matomo-Label z. B. '0h').
  UNION ALL
  SELECT datum, 'hour' AS dim,
         lpad(regexp_extract(dimkey, '(\d+)', 1), 2, '0') AS dimkey, pv, v
  FROM dim_rows('hour.json', 'hour_raw', 'nb_actions', 'nb_visits')
  WHERE regexp_extract(dimkey, '(\d+)', 1) <> ''
)
-- Leerzeilen verwerfen (Matomo paddet z. B. alle 24 Stunden, auch ohne Hits);
-- der Log-Pfad speichert ebenfalls nur Dimensionswerte mit Treffern.
WHERE pv > 0 OR v > 0;

-- Nicht abgedeckt (bewusst, v1):
--   * status, method, bytes  -> von Matomo nicht getrackt.
--   * browser_version, os_version, device_model, referrer_name, referrer_url
--     -> Cube-dimkey ist 'Eltern\x1fKind'; Matomos flache Reports liefern den
--        Eltern-Prefix nicht zuverlaessig. Dashboard zeigt diese Unteransichten
--        fuer importierte historische Zeitraeume leer. Siehe Doku.
