-- ===========================================================================
-- Geo-Quelle: IP2Location LITE DB1 (CSV, "IPv4 to Country").
-- Download (Lizenz CC-BY-SA-4.0, Attribution erforderlich):
--   https://lite.ip2location.com/database/ip-country  (kostenloser Account nötig)
-- Erwartetes Rohformat, ohne Header, 4 Spalten:
--   ip_from,ip_to,country_code,country_name   (ip_from/ip_to als Integer)
-- Parameter (SET VARIABLE): geopath
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW geo_ranges AS
SELECT ip_from AS start, ip_to AS "end", country_code AS cc
FROM read_csv(getvariable('geopath'),
    columns={'ip_from':'BIGINT','ip_to':'BIGINT','country_code':'VARCHAR','country_name':'VARCHAR'},
    header=false);
