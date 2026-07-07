-- ===========================================================================
-- Geo source: IP2Location LITE DB1 (CSV, "IPv4 to Country").
-- Download (license CC-BY-SA-4.0, attribution required):
--   https://lite.ip2location.com/database/ip-country  (free account required)
-- Expected raw format, no header, 4 columns:
--   ip_from,ip_to,country_code,country_name   (ip_from/ip_to as integer)
-- Parameter (SET VARIABLE): geopath
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW geo_ranges AS
SELECT ip_from AS start, ip_to AS "end", country_code AS cc
FROM read_csv(getvariable('geopath'),
    columns={'ip_from':'BIGINT','ip_to':'BIGINT','country_code':'VARCHAR','country_name':'VARCHAR'},
    header=false);
