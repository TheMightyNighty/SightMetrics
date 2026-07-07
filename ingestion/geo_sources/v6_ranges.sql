-- ===========================================================================
-- Optional IPv6 geo lookup (loaded only when SM_GEO6_PATH is set, see
-- lib_geo.sh). Uses DuckDB's inet extension for IPv6 range comparisons --
-- the extension is baked into the container image; local/CI runs install it
-- on demand (network required once).
--
-- Expected file format (works for both the "native" v6 format and the
-- DB-IP Country-Lite CSV, which mixes IPv4 and IPv6 rows in one file):
--   start_ip,end_ip,country_code   (textual addresses; IPv4 rows are skipped)
--
-- Builds TEMP TABLE ip6_country(ip, cc): country per distinct IPv6 address of
-- the current batch (parsed_lines must exist). transform.sql joins it; without
-- this step an empty default table is used and IPv6 stays country '??'.
-- Tie-break for nested ranges: highest start address = most specific range.
-- Parameter (SET VARIABLE): geo6path
-- ===========================================================================
INSTALL inet;
LOAD inet;

CREATE OR REPLACE TEMP VIEW geo_ranges_v6 AS
SELECT TRY_CAST(ip_start AS INET) AS start_ip,
       TRY_CAST(ip_end   AS INET) AS end_ip,
       country_code AS cc
FROM read_csv(getvariable('geo6path'),
    columns={'ip_start':'VARCHAR','ip_end':'VARCHAR','country_code':'VARCHAR'}, header=false)
WHERE ip_start LIKE '%:%' AND TRY_CAST(ip_start AS INET) IS NOT NULL;

CREATE OR REPLACE TEMP TABLE ip6_country AS
SELECT ip, cc FROM (
  SELECT u.ip, g.cc,
         row_number() OVER (PARTITION BY u.ip ORDER BY g.start_ip DESC) AS rn
  FROM (
    SELECT DISTINCT g.ip AS ip FROM parsed_lines
    WHERE g.ip LIKE '%:%' AND TRY_CAST(g.ip AS INET) IS NOT NULL
  ) u
  JOIN geo_ranges_v6 g
    ON TRY_CAST(u.ip AS INET) BETWEEN g.start_ip AND g.end_ip
) WHERE rn = 1;
