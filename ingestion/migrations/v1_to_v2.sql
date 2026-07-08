-- ===========================================================================
-- Cube-DB migration: schema v1 -> v2 (see docs/SCHEMA.md, version history).
-- Run ONCE against the cube database (as cube_rw or root), e.g.:
--   mysql -u cube_rw -p analytics < ingestion/migrations/v1_to_v2.sql
-- Alternative: drop the tables and re-import all logs (offsets reset).
--
-- Changes:
--   * cube.parent column; CHR(31)-encoded drill-down keys are split
--   * referrer_type values become neutral keys (direct/search/social/website)
--   * meta.tz records the bucketing timezone; existing data WAS bucketed in
--     UTC, so it is stamped 'UTC' (correct even if you set SM_TZ afterwards:
--     new days will be local, old days stay what they were)
--   * meta.schema_version = 2
-- Idempotent: re-running is safe (splits/updates only match v1-style rows).
-- ===========================================================================

ALTER TABLE cube ADD COLUMN IF NOT EXISTS parent VARCHAR(1024) AFTER dim;
ALTER TABLE meta ADD COLUMN IF NOT EXISTS tz VARCHAR(64);
ALTER TABLE meta ADD COLUMN IF NOT EXISTS schema_version INTEGER;

-- Split 'parent CHR(31) child' into (parent, dimkey)
UPDATE cube
   SET parent = SUBSTRING_INDEX(dimkey, CHAR(31), 1),
       dimkey = SUBSTRING(dimkey, CHAR_LENGTH(SUBSTRING_INDEX(dimkey, CHAR(31), 1)) + 2)
 WHERE dim IN ('referrer_name','referrer_url','browser_version','os_version','device_model')
   AND INSTR(dimkey, CHAR(31)) > 0;

-- referrer_type values -> neutral keys (German v1 labels)
UPDATE cube SET dimkey = CASE dimkey
    WHEN 'Direkt' THEN 'direct'
    WHEN 'Suchmaschine' THEN 'search'
    WHEN 'Soziale Medien' THEN 'social'
    WHEN 'Website' THEN 'website'
    ELSE dimkey END
 WHERE dim = 'referrer_type';

-- referrer_name parents referenced the old referrer_type labels
UPDATE cube SET parent = CASE parent
    WHEN 'Direkt' THEN 'direct'
    WHEN 'Suchmaschine' THEN 'search'
    WHEN 'Soziale Medien' THEN 'social'
    WHEN 'Website' THEN 'website'
    ELSE parent END
 WHERE dim = 'referrer_name';

UPDATE meta SET tz = 'UTC' WHERE tz IS NULL OR tz = '';
UPDATE meta SET schema_version = 2;
