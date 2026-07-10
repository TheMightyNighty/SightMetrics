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

SELECT 'cube_rows_this_site' k, (SELECT count(*) FROM m.${SM_TABLE_CUBE} WHERE site_id = getvariable('site_id')::INTEGER) n
UNION ALL SELECT 'sites_total', (SELECT count(DISTINCT site_id) FROM m.${SM_TABLE_META});
