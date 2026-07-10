-- ===========================================================================
-- Optional performance migration: query indexes on the cube tables.
--
-- Since 2026-07 the ingestion sink creates these indexes automatically on the
-- next import (CREATE INDEX IF NOT EXISTS in sink_mysql.sql). On LARGE
-- existing cubes you may prefer to build them at a controlled time instead of
-- during the nightly import window -- that is what this script is for. Safe to
-- run more than once; safe to skip if an import has already run with the new
-- sink.
--
--   mysql -u cube_rw -p analytics < ingestion/migrations/v2_add_indexes.sql
--
-- Effect (measured on an ~870k-row cube): dashboard panel queries drop from a
-- full-table scan per panel (~1.2s each, ~13 queries per load) to indexed
-- range scans (~0.3s); drill-down clicks become millisecond lookups (the
-- filter on 'parent' can only be indexed since schema v2).
-- ===========================================================================

CREATE INDEX IF NOT EXISTS sm_dim_datum ON cube  (site_id, dim(32), datum);
CREATE INDEX IF NOT EXISTS sm_drilldown ON cube  (site_id, dim(32), parent(191), datum);
CREATE INDEX IF NOT EXISTS sm_daily     ON daily (site_id, datum);

ANALYZE TABLE cube, daily;
