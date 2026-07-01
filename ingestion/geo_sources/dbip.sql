-- ===========================================================================
-- Geo-Quelle: DB-IP Country-Lite (CSV, monatlich, Lizenz CC-BY-4.0).
-- Download (kein Account nötig): https://db-ip.com/db/download/ip-to-country-lite
-- Erwartetes Rohformat, ohne Header, 3 Spalten:
--   ip_start,ip_end,country_code   (IPs in Punkt-/Doppelpunktnotation, IPv4+IPv6)
-- SightMetrics wertet nur IPv4 aus -> IPv6-Zeilen (":"-haltig) werden verworfen.
-- Parameter (SET VARIABLE): geopath
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW geo_ranges AS
SELECT
  (split_part(ip_start,'.',1)::BIGINT*16777216 + split_part(ip_start,'.',2)::BIGINT*65536
     + split_part(ip_start,'.',3)::BIGINT*256 + split_part(ip_start,'.',4)::BIGINT) AS start,
  (split_part(ip_end,'.',1)::BIGINT*16777216 + split_part(ip_end,'.',2)::BIGINT*65536
     + split_part(ip_end,'.',3)::BIGINT*256 + split_part(ip_end,'.',4)::BIGINT) AS "end",
  country_code AS cc
FROM read_csv(getvariable('geopath'),
    columns={'ip_start':'VARCHAR','ip_end':'VARCHAR','country_code':'VARCHAR'}, header=false)
WHERE ip_start NOT LIKE '%:%';
