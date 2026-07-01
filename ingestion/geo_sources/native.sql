-- ===========================================================================
-- Geo-Quelle: native (SightMetrics-eigenes Schema).
-- Erwartet: CSV ohne Header, 3 Spalten: start,end,cc (beide IPs als Integer,
-- Ländercode als ISO-2). Format identisch zu tests/geo_mini.csv.
-- Parameter (SET VARIABLE): geopath
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW geo_ranges AS
SELECT start, "end", cc
FROM read_csv(getvariable('geopath'),
    columns={'start':'BIGINT','end':'BIGINT','cc':'VARCHAR'}, header=false);
