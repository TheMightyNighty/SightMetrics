-- ===========================================================================
-- Geo source: DB-IP Country-Lite (CSV, monthly, license CC-BY-4.0).
-- Download (no account needed): https://db-ip.com/db/download/ip-to-country-lite
-- Expected raw format, no header, 3 columns:
--   ip_start,ip_end,country_code   (IPs in dot/colon notation, IPv4+IPv6)
-- SightMetrics only evaluates IPv4 -> IPv6 lines (containing ":") are discarded.
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
