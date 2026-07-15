-- ===========================================================================
-- Optional migration: Top-N precompute table (docs/topn-precompute-spec.md).
--
-- Since 2026-07 the ingestion sink creates and populates this table
-- automatically on the next import (sink_mysql.sql). This script only
-- creates the empty schema ahead of time -- e.g. if you want the table/index
-- to exist before the next scheduled import runs, or to inspect the schema
-- without waiting. Safe to run more than once; safe to skip entirely (the
-- next import creates it anyway).
--
-- Until the next import actually populates it, CubeRepository::topN() simply
-- finds no matching rows and falls back to the live query path -- there is
-- no correctness risk in running this early or not at all.
--
--   mysql -u cube_rw -p analytics < ingestion/migrations/v2_add_topn.sql
-- ===========================================================================

CREATE TABLE IF NOT EXISTS topn (
  site_id INTEGER,
  win  VARCHAR(16),
  dim     VARCHAR(32),
  parent  VARCHAR(191) NULL,
  dimkey  VARCHAR(1024),
  pv      BIGINT,
  v       BIGINT,
  rnk     SMALLINT
);
CREATE INDEX IF NOT EXISTS sm_topn_lookup ON topn (site_id, dim(32), win(16), parent(191), rnk);
