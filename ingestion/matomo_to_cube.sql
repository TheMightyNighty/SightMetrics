-- ===========================================================================
-- SightMetrics – Matomo historical-data import: Reporting API JSON -> cube_rows/daily_rows.
-- Compute part of the Matomo path (analogous to cube_to_mysql.sql for the log path).
-- Creates the same TEMP tables daily_rows / cube_rows; the shared
-- MariaDB sink (sink_mysql.sql) is appended by matomo_import.sh.
--
-- Parameters (SET VARIABLE, set by matomo_import.sh):
--   jsondir    directory with the downloaded report JSONs (one file
--              per dimension, plus daily.json). Missing files are allowed.
--   site_id, site_name  -> needed by the sink.
--
-- JSON shape per file (period=day + date range -> keyed by date):
--   daily.json:  { "YYYY-MM-DD": { nb_visits, nb_actions, ... }, ... }
--   <dim>.json:  { "YYYY-MM-DD": [ { label, nb_visits, nb_actions, ... }, ... ] }
-- Mapping: v <- nb_visits, pv <- nb_actions (or nb_hits for Actions reports).
-- ===========================================================================

-- ---- daily_rows from VisitsSummary.get -------------------------------------
-- bytes stays 0 (Matomo doesn't track bandwidth per day like the log path).
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

-- ---- Generic dimension reader ----------------------------------------------
-- file:    filename relative to jsondir (e.g. 'country.json')
-- dimname: target dim in the cube
-- pv_field/v_field: Matomo fields for pv (pageviews) and v (visits)
-- matomo_import.sh creates a file for each dimension (empty/missing
-- reports as '{}'), so json_keys() then returns 0 rows.
-- Non-array days are skipped.
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
  -- hour: normalize dimkey to '00'..'23' (Matomo label e.g. '0h').
  UNION ALL
  SELECT datum, 'hour' AS dim,
         lpad(regexp_extract(dimkey, '(\d+)', 1), 2, '0') AS dimkey, pv, v
  FROM dim_rows('hour.json', 'hour_raw', 'nb_actions', 'nb_visits')
  WHERE regexp_extract(dimkey, '(\d+)', 1) <> ''
)
-- Discard empty rows (Matomo pads e.g. all 24 hours, even without hits);
-- the log path likewise only stores dimension values with hits.
WHERE pv > 0 OR v > 0;

-- Not covered (deliberately, v1):
--   * status, method, bytes  -> not tracked by Matomo.
--   * browser_version, os_version, device_model, referrer_name, referrer_url
--     -> cube dimkey is 'parent\x1fchild'; Matomo's flat reports don't reliably
--        provide the parent prefix. Dashboard shows these sub-views
--        empty for imported historical periods. See docs.
