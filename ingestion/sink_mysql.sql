-- ===========================================================================
-- SightMetrics – shared MariaDB sink (section 11).
-- Expects the TEMP tables daily_rows / cube_rows (created sink-neutral) and
-- a schema 'm' mounted via ATTACH ... (TYPE mysql).
-- Used by:
--   * Log path:    cube_to_mysql.sql + transform.sql   (load_cube.sh)
--   * Matomo path: matomo_to_cube.sql                  (matomo_import.sh)
-- Both drivers append this file via `cat ... | envsubst` to their
-- compute part, so ${SM_TABLE_*} is correctly substituted here.
-- Incrementally safe: only days of the current batch are replaced.
-- Parameters (SET VARIABLE): site_id, site_name
-- ===========================================================================

-- IMPORTANT: the DuckDB->MySQL write path (mysql extension) is not crash-safe
-- with multiple threads – larger INSERTs sporadically trigger a heap race
-- (SIGSEGV/SIGBUS/SIGABRT). Force single-threaded execution from here on: the
-- sink only writes the small aggregates (cube/daily/meta), so single-thread is
-- imperceptibly slower. The heavy aggregation (transform.sql) has already run
-- fully parallel before this point; this SET only affects what follows.
SET threads=1;

-- Versioned DB contract between package A (writer) and package B (reader).
-- Bump this on INCOMPATIBLE changes to cube/daily/meta and update docs/SCHEMA.md
-- accordingly; the extension checks the version when building the module.
SET VARIABLE sm_schema_version = 2;

-- Schema (idempotent, multi-site)
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_CUBE}  (site_id INTEGER, datum DATE, dim VARCHAR, parent VARCHAR, dimkey VARCHAR, pv BIGINT, v BIGINT);
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_DAILY} (site_id INTEGER, datum DATE, visits BIGINT, pageviews BIGINT, uniques BIGINT, bounces BIGINT, bytes BIGINT);
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_META}  (site_id INTEGER, site VARCHAR, von VARCHAR, bis VARCHAR,
                                    visits_total BIGINT, pageviews_total BIGINT, uniques_total BIGINT,
                                    bounces_total BIGINT, bytes_total BIGINT, erzeugt VARCHAR,
                                    schema_version INTEGER, tz VARCHAR);
-- Top-N precompute (additive, docs/topn-precompute-spec.md): top-100 rows per
-- site/window/dim(/parent), derived from ${SM_TABLE_CUBE} at import time so
-- CubeRepository::topN() can serve the common preset windows without a live
-- GROUP BY over the whole range on high-cardinality dims. Column is named
-- 'win' not 'window' -- reserved word in both DuckDB and MariaDB (window
-- functions). parent=NULL rows are the flat root-dim lists (no parent
-- filter, matches topN()'s behaviour when parentKey is null); parent<>NULL
-- rows are drill-down children.
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_TOPN} (site_id INTEGER, win VARCHAR, dim VARCHAR, parent VARCHAR, dimkey VARCHAR, pv BIGINT, v BIGINT, rnk SMALLINT);
-- Backfill existing DBs (pre schema version); MariaDB understands IF NOT EXISTS.
CALL mysql_execute('m', 'ALTER TABLE ${SM_TABLE_META} ADD COLUMN IF NOT EXISTS schema_version INTEGER');
CALL mysql_execute('m', 'ALTER TABLE ${SM_TABLE_META} ADD COLUMN IF NOT EXISTS tz VARCHAR(64)');
-- v1 databases: the DDL is self-migrating (column add), the DATA is not --
-- existing CHR(31) rows must be converted via migrations/v1_to_v2.sql.
CALL mysql_execute('m', 'ALTER TABLE ${SM_TABLE_CUBE} ADD COLUMN IF NOT EXISTS parent VARCHAR(1024) AFTER dim');

-- Query indexes for the reader (extension). Without them every dashboard panel
-- is a full-table scan over the site's entire cube (measured ~4x slower on an
-- ~870k-row cube; the drill-down filter cannot use an index at all otherwise).
-- Prefix lengths: dim values are short identifiers (32 chars is plenty);
-- parent(191) keeps the key under InnoDB's 3072-byte limit with utf8mb4.
-- IF NOT EXISTS makes the nightly re-run a no-op. On very large existing cubes
-- the first import after this change builds the indexes once (online DDL) --
-- alternatively run migrations/v2_add_indexes.sql at a time of your choosing.
CALL mysql_execute('m', 'CREATE INDEX IF NOT EXISTS sm_dim_datum ON ${SM_TABLE_CUBE} (site_id, dim(32), datum)');
CALL mysql_execute('m', 'CREATE INDEX IF NOT EXISTS sm_drilldown ON ${SM_TABLE_CUBE} (site_id, dim(32), parent(191), datum)');
CALL mysql_execute('m', 'CREATE INDEX IF NOT EXISTS sm_daily ON ${SM_TABLE_DAILY} (site_id, datum)');
CALL mysql_execute('m', 'CREATE INDEX IF NOT EXISTS sm_topn_lookup ON ${SM_TABLE_TOPN} (site_id, dim(32), win(16), parent(191), rnk)');

-- Date range of the batch to be replaced (VARCHAR 'YYYY-MM-DD').
-- Priority is given to an explicitly set range_from/range_to (the Matomo path
-- sets the full --from/--to chunk here, so that days WITHOUT new data are
-- also cleanly cleared); otherwise MIN/MAX of the actually generated daily_rows
-- (log path – range_* is not set there -> getvariable() = NULL).
SET VARIABLE d_min = COALESCE(getvariable('range_from'), (SELECT MIN(datum)::VARCHAR FROM daily_rows), '1970-01-01');
SET VARIABLE d_max = COALESCE(getvariable('range_to'),   (SELECT MAX(datum)::VARCHAR FROM daily_rows), '1970-01-01');
SET VARIABLE sid   = getvariable('site_id')::INTEGER::VARCHAR;

-- Simple range DELETE via mysql_execute() (raw MariaDB SQL).
-- CHR(39) = single quote; avoids DuckDB type annotations (::DATE).
-- Touches only days of this batch; other sites/days are preserved.
CALL mysql_execute('m',
  'DELETE FROM ${SM_TABLE_CUBE}  WHERE site_id = ' || getvariable('sid')
  || ' AND datum >= ' || CHR(39) || getvariable('d_min') || CHR(39)
  || ' AND datum <= ' || CHR(39) || getvariable('d_max') || CHR(39)
);
CALL mysql_execute('m',
  'DELETE FROM ${SM_TABLE_DAILY} WHERE site_id = ' || getvariable('sid')
  || ' AND datum >= ' || CHR(39) || getvariable('d_min') || CHR(39)
  || ' AND datum <= ' || CHR(39) || getvariable('d_max') || CHR(39)
);

INSERT INTO m.${SM_TABLE_DAILY} SELECT getvariable('site_id')::INTEGER, datum, visits, pageviews, uniques, bounces, bytes FROM daily_rows;
INSERT INTO m.${SM_TABLE_CUBE}  SELECT getvariable('site_id')::INTEGER, CAST(datum AS DATE), dim, parent, dimkey, pv, v FROM cube_rows;

-- Meta: recomputed from the full daily table.
-- Uniques total is an additive approximation (daily values summed).
CALL mysql_execute('m', 'DELETE FROM ${SM_TABLE_META} WHERE site_id = ' || getvariable('sid'));
INSERT INTO m.${SM_TABLE_META}
  SELECT getvariable('site_id')::INTEGER,
         getvariable('site_name'),
         CAST(MIN(datum) AS VARCHAR), CAST(MAX(datum) AS VARCHAR),
         SUM(visits)::BIGINT, SUM(pageviews)::BIGINT, SUM(uniques)::BIGINT,
         SUM(bounces)::BIGINT, SUM(bytes)::BIGINT,
         strftime(now(), '%Y-%m-%d %H:%M'),
         getvariable('sm_schema_version')::INTEGER,
         COALESCE(NULLIF(getvariable('tz'), ''), 'UTC')
  FROM m.${SM_TABLE_DAILY} WHERE site_id = getvariable('site_id')::INTEGER;

-- ---------------------------------------------------------------------------
-- Top-N precompute (docs/topn-precompute-spec.md). Recomputed in full for
-- this site on every import (cheap DELETE+INSERT, same replace pattern as
-- above) -- windows are anchored on meta.bis (the site's newest complete
-- day), which mirrors the frontend's anchor() in presets.js (min(today,
-- meta.bis)): ingestion always lags at least one day behind "today", so
-- meta.bis IS that clamp target in practice.
SET VARIABLE meta_von = (SELECT von FROM m.${SM_TABLE_META} WHERE site_id = getvariable('site_id')::INTEGER);
SET VARIABLE meta_bis = (SELECT bis FROM m.${SM_TABLE_META} WHERE site_id = getvariable('site_id')::INTEGER);

CALL mysql_execute('m', 'DELETE FROM ${SM_TABLE_TOPN} WHERE site_id = ' || getvariable('sid'));

-- One row per supported preset win (docs/topn-precompute-spec.md
-- "Abgedeckte Fenster"); bounds match presets.js applyPreset() exactly.
-- wfrom is clamped to meta_von below (a fresh site has less than 365 days).
CREATE OR REPLACE TEMP TABLE topn_windows AS
  SELECT * FROM (VALUES
    ('last30',   CAST(getvariable('meta_bis') AS DATE) - INTERVAL 29 DAY,  CAST(getvariable('meta_bis') AS DATE)),
    ('last90',   CAST(getvariable('meta_bis') AS DATE) - INTERVAL 89 DAY,  CAST(getvariable('meta_bis') AS DATE)),
    ('last365',  CAST(getvariable('meta_bis') AS DATE) - INTERVAL 364 DAY, CAST(getvariable('meta_bis') AS DATE)),
    ('thisyear', date_trunc('year', CAST(getvariable('meta_bis') AS DATE)),
                 date_trunc('year', CAST(getvariable('meta_bis') AS DATE)) + INTERVAL 1 YEAR - INTERVAL 1 DAY),
    ('lastyear', date_trunc('year', CAST(getvariable('meta_bis') AS DATE) - INTERVAL 1 YEAR),
                 date_trunc('year', CAST(getvariable('meta_bis') AS DATE)) - INTERVAL 1 DAY),
    ('all',      CAST(getvariable('meta_von') AS DATE), CAST(getvariable('meta_bis') AS DATE))
  ) AS t(win, wfrom, wto);

-- Root dims (TopNDims::ROOT_METRIC_BY_DIM): parent is ignored (topN() with
-- parentKey=null does not filter on it either -- flat, ungrouped list), so
-- rows are written with parent=NULL. Metric is 'pv' for download/status/
-- method, 'v' for the rest (must stay in sync with TopNDims.php).
CREATE OR REPLACE TEMP TABLE topn_root AS
  SELECT win, dim, CAST(NULL AS VARCHAR) AS parent, dimkey, pv, v,
         ROW_NUMBER() OVER (
           PARTITION BY win, dim
           ORDER BY (CASE WHEN dim IN ('download', 'status', 'method') THEN pv ELSE v END) DESC
         ) AS rnk
  FROM (
    SELECT tw.win, c.dim, c.dimkey, SUM(c.pv)::BIGINT AS pv, SUM(c.v)::BIGINT AS v
    FROM topn_windows tw
    JOIN m.${SM_TABLE_CUBE} c
      ON c.datum BETWEEN GREATEST(tw.wfrom, CAST(getvariable('meta_von') AS DATE)) AND tw.wto
    WHERE c.site_id = getvariable('site_id')::INTEGER
      AND c.dim IN ('keyword', 'entry', 'exit', 'download', 'status', 'method',
                     'browser', 'os', 'device', 'referrer_type', 'referrer_url')
      AND c.dimkey <> ''
    GROUP BY tw.win, c.dim, c.dimkey
  );

-- Drill-down children (TopNDims::CHILD_METRIC_BY_DIM), all metric 'v':
-- ranked within each (win, dim, parent) group, so every parent category
-- (e.g. each browser) gets its own top-100 of children.
CREATE OR REPLACE TEMP TABLE topn_child AS
  SELECT tw.win, c.dim, c.parent, c.dimkey, SUM(c.pv)::BIGINT AS pv, SUM(c.v)::BIGINT AS v,
         ROW_NUMBER() OVER (
           PARTITION BY tw.win, c.dim, c.parent
           ORDER BY SUM(c.v) DESC
         ) AS rnk
  FROM topn_windows tw
  JOIN m.${SM_TABLE_CUBE} c
    ON c.datum BETWEEN GREATEST(tw.wfrom, CAST(getvariable('meta_von') AS DATE)) AND tw.wto
  WHERE c.site_id = getvariable('site_id')::INTEGER
    AND c.dim IN ('browser_version', 'os_version', 'device_model', 'referrer_name', 'referrer_url')
    AND c.parent IS NOT NULL
    AND c.dimkey <> ''
  GROUP BY tw.win, c.dim, c.parent, c.dimkey;

INSERT INTO m.${SM_TABLE_TOPN}
  SELECT getvariable('site_id')::INTEGER, win, dim, parent, dimkey, pv, v, rnk FROM topn_root WHERE rnk <= 100
  UNION ALL
  SELECT getvariable('site_id')::INTEGER, win, dim, parent, dimkey, pv, v, rnk FROM topn_child WHERE rnk <= 100;

SELECT 'cube_rows_this_site' k, (SELECT count(*) FROM m.${SM_TABLE_CUBE} WHERE site_id = getvariable('site_id')::INTEGER) n
UNION ALL SELECT 'sites_total', (SELECT count(DISTINCT site_id) FROM m.${SM_TABLE_META})
UNION ALL SELECT 'topn_rows_this_site', (SELECT count(*) FROM m.${SM_TABLE_TOPN} WHERE site_id = getvariable('site_id')::INTEGER);
