-- ===========================================================================
-- SightMetrics – Auswertungslogik (sink-neutral). Parse -> Sessionisierung -> Cube.
-- Erzeugt die TEMP-Tabellen cube_rows / daily_rows / meta_row.
-- Genutzt von cube_to_mysql.sql (Import) UND tests/pipeline_test.sql.
-- Parameter (SET VARIABLE): logpath, site_name, tagessalt
-- Geo: setzt voraus, dass die TEMP VIEW 'geo_ranges' (start,"end",cc) bereits
--      existiert -> wird von load_cube.sh/tests via geo_sources/<quelle>.sql
--      angelegt (SM_GEO_SOURCE: native, ip2location, dbip, maxmind).
-- ===========================================================================

-- ---- Log-Format-Defaults (überschreibbar via SET VARIABLE in load_cube.sh) ----
-- logregex:  Regex mit genau 8 Capture-Groups (ip,tsraw,method,url,status,size,referrer,ua).
--            Fehlende optionale Gruppen (z.B. referrer/ua beim Common-Format) liefern ''.
-- tsformat:  strptime-Format für das Timestamp-Capture (Gruppe 2).
SET VARIABLE logregex = COALESCE(
  getvariable('logregex'),
  '^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
);
SET VARIABLE tsformat = COALESCE(getvariable('tsformat'), '%d/%b/%Y:%H:%M:%S %z');

-- ---- 1) Parse + lesbare Dimensionen ---------------------------------------
CREATE OR REPLACE TEMP TABLE hits AS
WITH raw AS (
  SELECT line FROM read_csv(getvariable('logpath'),
       columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true)
),
m AS (
  SELECT regexp_extract(line,
      getvariable('logregex'),
      ['ip','tsraw','method','url','status','size','referrer','ua']) AS g
  FROM raw
)
SELECT * FROM (
  SELECT
    timezone('UTC', strptime(g.tsraw, getvariable('tsformat'))) AS ts,
    g.url AS url, CAST(g.status AS INTEGER) AS status, g.referrer AS referrer,
    g.method AS method, CAST(g.size AS BIGINT) AS bytes,
    (split_part(g.ip,'.',1)::BIGINT*16777216 + split_part(g.ip,'.',2)::BIGINT*65536
       + split_part(g.ip,'.',3)::BIGINT*256 + split_part(g.ip,'.',4)::BIGINT) AS ipint,
    md5(g.ip || '|' || g.ua || '|' || getvariable('tagessalt')) AS vkey,
    g.url LIKE '%.pdf' AS is_download,
    CASE WHEN g.ua LIKE '%Firefox%' THEN 'Firefox'
         WHEN g.ua LIKE '%Chrome%' AND g.ua LIKE '%Mobile%' THEN 'Chrome Mobile'
         WHEN g.ua LIKE '%Chrome%' THEN 'Chrome'
         WHEN g.ua LIKE '%iPhone%' THEN 'Mobile Safari'
         WHEN g.ua LIKE '%Safari%' THEN 'Safari' ELSE 'Andere' END AS browser,
    CASE WHEN g.ua LIKE '%Firefox%' THEN regexp_extract(g.ua,'Firefox/([0-9.]+)',1)
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
  FROM m
) WHERE ts IS NOT NULL AND status < 400
  AND url NOT SIMILAR TO '.*\.(css|js|png|jpg|jpeg|gif|svg|woff2?|ico|map)$';

-- ---- 2) Sessionisierung (ein Sort + ein Single-Pass) ----------------------
CREATE OR REPLACE TEMP TABLE sess AS
SELECT *, strftime(ts,'%Y-%m-%d') AS datum, extract('hour' FROM ts) AS stunde,
       sum(new_session) OVER (PARTITION BY vkey ORDER BY ts) AS seq
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
SELECT v.*, COALESCE(gc.cc,'??') AS country,
  CASE WHEN v.referrer IN ('','-') THEN 'Direkt'
       WHEN v.ref_host LIKE '%google%' OR v.ref_host LIKE '%bing%' OR v.ref_host LIKE '%duckduckgo%' THEN 'Suchmaschine'
       WHEN v.ref_host LIKE '%t.co%' OR v.ref_host LIKE '%twitter%' OR v.ref_host LIKE '%facebook%' THEN 'Soziale Medien'
       ELSE 'Website' END AS ref_type,
  CASE WHEN v.ref_host LIKE '%google%' THEN 'Google'
       WHEN v.ref_host LIKE '%bing%' THEN 'Bing'
       WHEN v.ref_host LIKE '%duckduckgo%' THEN 'DuckDuckGo'
       WHEN v.ref_host LIKE '%t.co%' OR v.ref_host LIKE '%twitter%' THEN 'Twitter'
       WHEN v.ref_host LIKE '%facebook%' THEN 'Facebook'
       WHEN v.referrer IN ('','-') THEN NULL ELSE v.ref_host END AS ref_name
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

-- ---- 3) Ergebnis-Temp-Tabellen (sink-neutral) -----------------------------
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
    UNION ALL SELECT datum,'status',CAST(status AS VARCHAR),count(*),count(DISTINCT (vkey,seq)) FROM sess GROUP BY datum,status
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
