-- ===========================================================================
-- Geo source: MaxMind GeoLite2 Country (CSV, free account + license key
-- required, observe the EULA: https://www.maxmind.com/en/geolite2/eula).
-- Download: GeoLite2-Country-CSV.zip, needs two files from it:
--   GeoLite2-Country-Blocks-IPv4.csv     (geopath)
--   GeoLite2-Country-Locations-en.csv    (geolocpath)
-- Blocks format (with header): network,geoname_id,registered_country_geoname_id,
--   represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
-- Locations format (with header): geoname_id,locale_code,continent_code,
--   continent_name,country_iso_code,country_name,is_in_european_union
-- Parameters (SET VARIABLE): geopath, geolocpath
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW geo_ranges AS
WITH loc AS (
  SELECT geoname_id, country_iso_code
  FROM read_csv(getvariable('geolocpath'), header=true,
      columns={'geoname_id':'BIGINT','locale_code':'VARCHAR','continent_code':'VARCHAR',
               'continent_name':'VARCHAR','country_iso_code':'VARCHAR','country_name':'VARCHAR',
               'is_in_european_union':'VARCHAR'})
),
blk AS (
  SELECT network, COALESCE(geoname_id, registered_country_geoname_id) AS gid
  FROM read_csv(getvariable('geopath'), header=true,
      columns={'network':'VARCHAR','geoname_id':'BIGINT','registered_country_geoname_id':'BIGINT',
               'represented_country_geoname_id':'BIGINT','is_anonymous_proxy':'VARCHAR',
               'is_satellite_provider':'VARCHAR'})
  WHERE network NOT LIKE '%:%'
),
net AS (
  SELECT
    (split_part(split_part(network,'/',1),'.',1)::BIGINT*16777216
       + split_part(split_part(network,'/',1),'.',2)::BIGINT*65536
       + split_part(split_part(network,'/',1),'.',3)::BIGINT*256
       + split_part(split_part(network,'/',1),'.',4)::BIGINT) AS base,
    split_part(network,'/',2)::INTEGER AS prefix,
    gid
  FROM blk
)
SELECT net.base AS start,
       net.base + (CAST(1 AS BIGINT) << (32 - net.prefix)) - 1 AS "end",
       loc.country_iso_code AS cc
FROM net JOIN loc ON net.gid = loc.geoname_id;
