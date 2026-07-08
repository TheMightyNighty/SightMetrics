-- Pipeline test: checks the analysis logic (transform.sql) against the fixture
-- with known expected values. Outputs PASS/FAIL for each check.
.read 'transform.sql'

WITH checks(c, exp, act) AS (
  VALUES
    -- Overall metrics (fixture: 5 IPv4 hits + 1 IPv6/Edge hit; bot line doesn't count)
    ('pageviews_total',        6, (SELECT pageviews_total FROM meta_row)),
    ('visits_total',           4, (SELECT visits_total    FROM meta_row)),
    ('uniques_total',          3, (SELECT uniques_total   FROM meta_row)),
    ('bounces_total',          3, (SELECT bounces_total   FROM meta_row)),
    ('bytes_total',         7200, (SELECT bytes_total     FROM meta_row)),
    -- URL dimensions
    ('url_/a_pageviews',       4, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/a')),
    ('url_/b_pageviews',       1, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/b')),
    -- Entry/exit
    ('entry_/a_visits',        4, (SELECT v  FROM cube_rows WHERE dim='entry' AND dimkey='/a')),
    ('exit_/c.pdf_visits',     1, (SELECT v  FROM cube_rows WHERE dim='exit'  AND dimkey='/c.pdf')),
    -- Referrer & keyword (heuristic anchored: www.google.com counts, nichtgoogle.example doesn't)
    ('ref_search_v',           1, (SELECT v  FROM cube_rows WHERE dim='referrer_type' AND dimkey='search')),
    ('ref_direct_v',           3, (SELECT v  FROM cube_rows WHERE dim='referrer_type' AND dimkey='direct')),
    -- Schema v2: drill-down rows carry parent separately (no CHR(31) keys)
    ('parent_split_v2',        1, (SELECT v  FROM cube_rows WHERE dim='browser_version' AND parent='Edge' AND dimkey NOT LIKE '%'||chr(31)||'%')),
    ('no_chr31_keys_v2',       0, (SELECT count(*)::INT FROM cube_rows WHERE dimkey LIKE '%'||chr(31)||'%')),
    ('keyword_extrahiert',     1, (SELECT v  FROM cube_rows WHERE dim='keyword' AND dimkey='test begriff')),
    -- Browser / OS / device (Edge UA contains 'Chrome', but must count as Edge)
    ('browser_Chrome_visits',  3, (SELECT v  FROM cube_rows WHERE dim='browser' AND dimkey='Chrome')),
    ('browser_Edge_visits',    1, (SELECT v  FROM cube_rows WHERE dim='browser' AND dimkey='Edge')),
    ('os_windows_visits',      4, (SELECT v  FROM cube_rows WHERE dim='os'      AND dimkey='Windows')),
    ('device_desktop_visits',  4, (SELECT v  FROM cube_rows WHERE dim='device'  AND dimkey='Desktop')),
    -- HTTP method (all non-bot hits are GET)
    ('method_get_pv',          6, (SELECT pv FROM cube_rows WHERE dim='method'  AND dimkey='GET')),
    -- GeoIP (IPv6 has no ipint -> country '??', but doesn't crash the import)
    ('country_US_aus_GeoIP',   1, (SELECT count(*)::INT FROM cube_rows WHERE dim='country'  AND dimkey='US')),
    ('country_ipv6_unbekannt', 1, (SELECT v  FROM cube_rows WHERE dim='country'  AND dimkey='??')),
    -- Downloads & filtering
    ('download_pdf_erkannt',   1, (SELECT count(*)::INT FROM cube_rows WHERE dim='download' AND dimkey='/c.pdf')),
    ('asset_css_gefiltert',    0, (SELECT count(*)::INT FROM cube_rows WHERE dimkey LIKE '%style.css%')),
    -- Status-code panel: errors are visible (from hits_all, before the <400 filter)
    ('status_404_sichtbar_pv', 1, (SELECT pv FROM cube_rows WHERE dim='status'   AND dimkey='404')),
    ('status_200_pv',          6, (SELECT pv FROM cube_rows WHERE dim='status'   AND dimkey='200')),
    -- Bot filter: Googlebot line is completely excluded (no 'Andere' browser)
    ('bot_gefiltert',          0, (SELECT count(*)::INT FROM cube_rows WHERE dim='browser' AND dimkey='Andere'))
)
SELECT
  CASE WHEN COALESCE(act,-1) = exp THEN 'PASS' ELSE 'FAIL' END AS status,
  c AS pruefung, exp AS soll, COALESCE(act,-1) AS ist
FROM checks ORDER BY status DESC, c;
