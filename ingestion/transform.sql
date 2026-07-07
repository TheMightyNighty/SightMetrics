-- ===========================================================================
-- SightMetrics – analysis logic (sink-neutral). Parse -> sessionization -> cube.
-- Creates the TEMP tables cube_rows / daily_rows / meta_row.
-- Used by cube_to_mysql.sql (import) AND tests/pipeline_test.sql.
-- Parameters (SET VARIABLE): logpath, site_name, tagessalt, tsformat,
--   tz (hour dimension), botfilter ('0' = off), download_re (download regex)
-- Geo: assumes the TEMP VIEW 'geo_ranges' (start,"end",cc) already
--      exists -> created by load_cube.sh/tests via geo_sources/<source>.sql
--      (SM_GEO_SOURCE: native, ip2location, dbip, maxmind).
-- Log parsing: assumes the TEMP TABLE 'parsed_lines(g)' (g.ip/tsraw/
--      method/url/status/size/referrer/ua, all VARCHAR) already exists -> created
--      by load_cube.sh/fetch_loki_logs.sh via log_formats/<format>.sql
--      (SM_LOG_FORMAT: combined, combined_vhost, common, custom,
--      json_ecs - see lib_logformat.sh).
-- ===========================================================================

-- tsformat: strptime format for the timestamp string g.tsraw (set by
-- log_formats/*.sql; default here only as a fallback if used directly without lib_logformat.sh).
SET VARIABLE tsformat = COALESCE(getvariable('tsformat'), '%d/%b/%Y:%H:%M:%S %z');
-- tz: timezone for the 'hour' dimension (visit-times panel). datum deliberately stays
-- UTC (stable day boundaries for offset/batch logic), only the hour is shown
-- localized. Set by load_cube.sh/fetch_loki_logs.sh via SM_TZ.
SET VARIABLE tz = COALESCE(NULLIF(getvariable('tz'), ''), 'UTC');
-- botfilter: '0' disables the UA-based bot/crawler exclusion (debug/comparison).
SET VARIABLE botfilter = COALESCE(NULLIF(getvariable('botfilter'), ''), '1');
-- botregex: bot detection pattern. Set by the caller if a
-- device-detector bot list is present (SM_BOT_RE_PATH, see tools/fetch_bot_list.sh
-- and runbook §3); otherwise the built-in heuristic applies (crawlers, CLI clients,
-- monitoring/scanners). Empty UAs deliberately do NOT count as a bot (format 'common').
SET VARIABLE botregex = COALESCE(NULLIF(getvariable('botregex'), ''),
  '(?i)bot|crawl|spider|slurp|curl|wget|python-requests|python/|go-http-client|okhttp|java/|libwww|httpclient|headless|phantomjs|lighthouse|pingdom|uptimerobot|statuscake|monitor|nagios|zabbix|masscan|nmap|zgrab|facebookexternalhit|feedfetcher|archive\.org');
-- download_re: regex (on lowercase URL) for download detection, overridable
-- via SM_DOWNLOAD_RE. Query string/fragment after the extension is allowed.
SET VARIABLE download_re = COALESCE(NULLIF(getvariable('download_re'), ''),
  '\.(pdf|zip|7z|gz|tgz|tar|rar|docx?|xlsx?|pptx?|od[tsp]|csv|rtf|ics|epub|mp[34])([?#]|$)');

-- ---- 1) Parse + human-readable dimensions ---------------------------------
-- hits_all: parsed lines WITHOUT bots/assets, but INCLUDING error status codes
-- (basis of the 'status' dimension). hits: of that, only status < 400 (basis of
-- all remaining analyses). try_strptime/TRY_CAST: an unparseable line (bot junk,
-- IPv6 for ipint, broken timestamps) only discards that line, not the whole import.
CREATE OR REPLACE TEMP TABLE hits_all AS
SELECT *, strftime(ts,'%Y-%m-%d') AS datum,
       extract('hour' FROM ts_local) AS stunde
FROM (
  SELECT
    timezone('UTC', tstz) AS ts,
    timezone(getvariable('tz'), tstz) AS ts_local,
    g.url AS url, TRY_CAST(g.status AS INTEGER) AS status, g.referrer AS referrer,
    g.method AS method, COALESCE(TRY_CAST(g.size AS BIGINT), 0) AS bytes,
    -- ipint only for IPv4 (GeoIP lookup); IPv6/other -> NULL -> country '??'.
    CASE WHEN regexp_matches(g.ip, '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')
         THEN (split_part(g.ip,'.',1)::BIGINT*16777216 + split_part(g.ip,'.',2)::BIGINT*65536
                 + split_part(g.ip,'.',3)::BIGINT*256 + split_part(g.ip,'.',4)::BIGINT)
    END AS ipint,
    md5(g.ip || '|' || g.ua || '|' || getvariable('tagessalt')) AS vkey,
    -- Bot/crawler detection: pattern from getvariable('botregex') (device-detector
    -- list or built-in heuristic, see variable block above).
    (getvariable('botfilter') <> '0' AND regexp_matches(g.ua, getvariable('botregex'))) AS is_bot,
    regexp_matches(lower(g.url), getvariable('download_re')) AS is_download,
    CASE WHEN g.ua LIKE '%Firefox%' THEN 'Firefox'
         WHEN g.ua LIKE '%Edg%' THEN 'Edge'
         WHEN g.ua LIKE '%OPR/%' OR g.ua LIKE '%Opera%' THEN 'Opera'
         WHEN g.ua LIKE '%Chrome%' AND g.ua LIKE '%Mobile%' THEN 'Chrome Mobile'
         WHEN g.ua LIKE '%Chrome%' THEN 'Chrome'
         WHEN g.ua LIKE '%iPhone%' THEN 'Mobile Safari'
         WHEN g.ua LIKE '%Safari%' THEN 'Safari' ELSE 'Andere' END AS browser,
    CASE WHEN g.ua LIKE '%Firefox%' THEN regexp_extract(g.ua,'Firefox/([0-9.]+)',1)
         WHEN g.ua LIKE '%Edg%' THEN regexp_extract(g.ua,'Edg[A-Za-z]*/([0-9.]+)',1)
         WHEN g.ua LIKE '%OPR/%' THEN regexp_extract(g.ua,'OPR/([0-9.]+)',1)
         WHEN g.ua LIKE '%Chrome%'  THEN regexp_extract(g.ua,'Chrome/([0-9.]+)',1)
         WHEN g.ua LIKE '%Version/%' THEN regexp_extract(g.ua,'Version/([0-9.]+)',1)
         ELSE '' END AS browser_ver,
    CASE WHEN g.ua LIKE '%Windows%' THEN 'Windows'
         WHEN g.ua LIKE '%Android%' THEN 'Android'
         WHEN g.ua LIKE '%iPhone%' THEN 'iOS'
         WHEN g.ua LIKE '%Macintosh%' THEN 'macOS'
         WHEN g.ua LIKE '%Linux%' THEN 'Linux' ELSE 'Andere' END AS os,
    CASE WHEN g.ua LIKE '%Windows NT 10.0%' THEN 'Windows 10/11'
         WHEN g.ua LIKE '%Windows%' THEN 'Windows (älter)'
         WHEN g.ua LIKE '%Android%' THEN 'Android ' || regexp_extract(g.ua,'Android ([0-9.]+)',1)
         WHEN g.ua LIKE '%iPhone OS%' THEN 'iOS ' || replace(regexp_extract(g.ua,'iPhone OS ([0-9_]+)',1),'_','.')
         WHEN g.ua LIKE '%Mac OS X%' THEN 'macOS ' || replace(regexp_extract(g.ua,'Mac OS X ([0-9_]+)',1),'_','.')
         WHEN g.ua LIKE '%Linux%' THEN 'Linux' ELSE 'Andere' END AS os_ver,
    CASE WHEN g.ua LIKE '%iPhone%' OR g.ua LIKE '%Mobile%' THEN 'Smartphone' ELSE 'Desktop' END AS device,
    CASE WHEN g.ua LIKE '%iPhone%' THEN 'Apple iPhone'
         WHEN g.ua LIKE '%Pixel%' THEN 'Google ' || regexp_extract(g.ua,'(Pixel [0-9]+)',1)
         WHEN g.ua LIKE '%Mobile%' THEN 'Smartphone (sonstige)'
         ELSE 'Desktop-PC' END AS device_model,
    regexp_replace(g.referrer,'^https?://([^/]+).*','\1') AS ref_host,
    CASE WHEN regexp_matches(g.referrer,'[?&]q=')
         THEN replace(regexp_extract(g.referrer,'[?&]q=([^&]+)',1),'+',' ') END AS keyword
  FROM (SELECT g, try_strptime(g.tsraw, getvariable('tsformat')) AS tstz FROM parsed_lines)
) WHERE ts IS NOT NULL AND status IS NOT NULL AND NOT is_bot
  AND url NOT SIMILAR TO '.*\.(css|js|png|jpg|jpeg|gif|svg|woff2?|ico|map)$';

-- Successful hits (basis for pageviews/visits/all dimensions except 'status').
CREATE OR REPLACE TEMP TABLE hits AS
SELECT * FROM hits_all WHERE status < 400;

-- ---- 2) Sessionization (one sort + one single pass) -----------------------
CREATE OR REPLACE TEMP TABLE sess AS
SELECT *, sum(new_session) OVER (PARTITION BY vkey ORDER BY ts) AS seq
FROM (
  SELECT *, CASE WHEN ts - lag(ts) OVER w > INTERVAL 30 MINUTE OR lag(ts) OVER w IS NULL
                 THEN 1 ELSE 0 END AS new_session
  FROM hits WINDOW w AS (PARTITION BY vkey ORDER BY ts)
);

CREATE OR REPLACE TEMP TABLE ip_country AS
SELECT ipint, cc FROM (
  SELECT s.ipint, geo.cc, row_number() OVER (PARTITION BY s.ipint ORDER BY (geo."end"-geo.start)) rn
  FROM (SELECT DISTINCT ipint FROM sess) s
  JOIN geo_ranges geo
    ON s.ipint BETWEEN geo.start AND geo."end"
) WHERE rn=1;

CREATE OR REPLACE TEMP TABLE visits AS
-- Referrer classification: anchored on the host (domain end), so
-- 'nichtgoogle.example' or similar isn't falsely counted as a search engine.
SELECT v.*, COALESCE(gc.cc,'??') AS country,
  CASE WHEN v.referrer IN ('','-') THEN 'Direkt'
       WHEN regexp_matches(v.ref_host,'(^|\.)(google|bing|duckduckgo|ecosia|startpage|qwant|yandex)\.[a-z.]+$')
            OR v.ref_host = 'search.brave.com' THEN 'Suchmaschine'
       WHEN v.ref_host IN ('t.co','x.com')
            OR regexp_matches(v.ref_host,'(^|\.)(twitter|facebook|instagram|linkedin|youtube|tiktok)\.com$')
            THEN 'Soziale Medien'
       ELSE 'Website' END AS ref_type,
  CASE WHEN v.referrer IN ('','-') THEN NULL
       WHEN regexp_matches(v.ref_host,'(^|\.)google\.[a-z.]+$') THEN 'Google'
       WHEN regexp_matches(v.ref_host,'(^|\.)bing\.com$') THEN 'Bing'
       WHEN regexp_matches(v.ref_host,'(^|\.)duckduckgo\.com$') THEN 'DuckDuckGo'
       WHEN regexp_matches(v.ref_host,'(^|\.)ecosia\.org$') THEN 'Ecosia'
       WHEN regexp_matches(v.ref_host,'(^|\.)startpage\.com$') THEN 'Startpage'
       WHEN v.ref_host IN ('t.co','x.com') OR regexp_matches(v.ref_host,'(^|\.)twitter\.com$') THEN 'Twitter'
       WHEN regexp_matches(v.ref_host,'(^|\.)facebook\.com$') THEN 'Facebook'
       ELSE v.ref_host END AS ref_name
FROM (
  SELECT vkey, seq, strftime(min(ts),'%Y-%m-%d') AS datum, count(*) AS pageviews,
         arg_min(url, ts) AS entry_url, arg_max(url, ts) AS exit_url,
         arg_min(ipint, ts) AS ipint, arg_min(browser, ts) AS browser,
         arg_min(browser, ts) || ' ' || arg_min(browser_ver, ts) AS browser_version,
         arg_min(os, ts) AS os, arg_min(os_ver, ts) AS os_version,
         arg_min(device, ts) AS device, arg_min(device_model, ts) AS device_model,
         arg_min(referrer, ts) AS referrer, arg_min(ref_host, ts) AS ref_host,
         arg_min(keyword, ts) AS keyword
  FROM sess GROUP BY vkey, seq
) v LEFT JOIN ip_country gc ON gc.ipint = v.ipint;

-- ---- 3) Result temp tables (sink-neutral) ----------------------------------
CREATE OR REPLACE TEMP TABLE daily_rows AS
  WITH pv AS (SELECT datum, count(*) pageviews, sum(bytes) bytes FROM sess GROUP BY datum),
       vi AS (SELECT datum, count(*) visits, count(DISTINCT vkey) uniques,
                     count(*) FILTER (WHERE pageviews=1) bounces FROM visits GROUP BY datum)
  SELECT CAST(COALESCE(pv.datum,vi.datum) AS DATE) AS datum,
         COALESCE(visits,0)::BIGINT AS visits, COALESCE(pageviews,0)::BIGINT AS pageviews,
         COALESCE(uniques,0)::BIGINT AS uniques, COALESCE(bounces,0)::BIGINT AS bounces,
         COALESCE(bytes,0)::BIGINT AS bytes
  FROM pv FULL JOIN vi USING (datum);

CREATE OR REPLACE TEMP TABLE cube_rows AS
  SELECT datum, dim, dimkey, pv::BIGINT AS pv, v::BIGINT AS v FROM (
    SELECT datum,'url' dim, url dimkey, count(*) pv, count(DISTINCT (vkey,seq)) v FROM sess GROUP BY datum,url
    -- 'status' from hits_all: also includes 4xx/5xx (the panel is meant to show errors);
    -- v here is "affected visitors" (DISTINCT vkey), since error hits have no session.
    UNION ALL SELECT datum,'status',CAST(status AS VARCHAR),count(*),count(DISTINCT vkey) FROM hits_all GROUP BY datum,status
    UNION ALL SELECT datum,'method',method,count(*),count(DISTINCT (vkey,seq)) FROM sess GROUP BY datum,method
    UNION ALL SELECT datum,'hour',lpad(CAST(stunde AS VARCHAR),2,'0'),count(*),count(DISTINCT (vkey,seq)) FROM sess GROUP BY datum,stunde
    UNION ALL SELECT datum,'download',url,count(*),count(DISTINCT (vkey,seq)) FROM sess WHERE is_download GROUP BY datum,url
    UNION ALL SELECT datum,'entry',entry_url,sum(pageviews),count(*) FROM visits GROUP BY datum,entry_url
    UNION ALL SELECT datum,'exit',exit_url,sum(pageviews),count(*) FROM visits GROUP BY datum,exit_url
    UNION ALL SELECT datum,'referrer_type',ref_type,sum(pageviews),count(*) FROM visits GROUP BY datum,ref_type
    UNION ALL SELECT datum,'referrer_name',ref_type||chr(31)||ref_name,sum(pageviews),count(*) FROM visits WHERE ref_name IS NOT NULL GROUP BY datum,ref_type,ref_name
    UNION ALL SELECT datum,'referrer_url',ref_name||chr(31)||referrer,sum(pageviews),count(*) FROM visits WHERE referrer NOT IN ('','-') AND ref_name IS NOT NULL GROUP BY datum,ref_name,referrer
    UNION ALL SELECT datum,'keyword',keyword,sum(pageviews),count(*) FROM visits WHERE keyword IS NOT NULL AND keyword<>'' GROUP BY datum,keyword
    UNION ALL SELECT datum,'country',country,sum(pageviews),count(*) FROM visits GROUP BY datum,country
    UNION ALL SELECT datum,'browser',browser,sum(pageviews),count(*) FROM visits GROUP BY datum,browser
    UNION ALL SELECT datum,'browser_version',browser||chr(31)||browser_version,sum(pageviews),count(*) FROM visits GROUP BY datum,browser,browser_version
    UNION ALL SELECT datum,'os',os,sum(pageviews),count(*) FROM visits GROUP BY datum,os
    UNION ALL SELECT datum,'os_version',os||chr(31)||os_version,sum(pageviews),count(*) FROM visits GROUP BY datum,os,os_version
    UNION ALL SELECT datum,'device',device,sum(pageviews),count(*) FROM visits GROUP BY datum,device
    UNION ALL SELECT datum,'device_model',device||chr(31)||device_model,sum(pageviews),count(*) FROM visits GROUP BY datum,device,device_model
  );

CREATE OR REPLACE TEMP TABLE meta_row AS
  SELECT getvariable('site_name') AS site,
         (SELECT min(datum) FROM sess) AS von, (SELECT max(datum) FROM sess) AS bis,
         (SELECT count(*) FROM visits)::BIGINT AS visits_total,
         (SELECT count(*) FROM sess)::BIGINT AS pageviews_total,
         (SELECT count(DISTINCT vkey) FROM visits)::BIGINT AS uniques_total,
         (SELECT count(*) FILTER (WHERE pageviews=1) FROM visits)::BIGINT AS bounces_total,
         (SELECT sum(bytes) FROM sess)::BIGINT AS bytes_total,
         strftime(now(),'%Y-%m-%d %H:%M') AS erzeugt;
