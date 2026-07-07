-- ===========================================================================
-- Geo source: native (SightMetrics' own schema).
-- Expected: CSV without header, 3 columns: start,end,cc (both IPs as integer,
-- country code as ISO-2). Format identical to tests/geo_mini.csv.
-- Parameter (SET VARIABLE): geopath
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW geo_ranges AS
SELECT start, "end", cc
FROM read_csv(getvariable('geopath'),
    columns={'start':'BIGINT','end':'BIGINT','cc':'VARCHAR'}, header=false);
