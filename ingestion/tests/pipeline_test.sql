-- Pipeline-Test: prüft die Auswertungslogik (transform.sql) gegen das Fixture
-- mit bekannten Soll-Werten. Gibt je Prüfung PASS/FAIL aus.
.read 'transform.sql'

WITH checks(c, exp, act) AS (
  VALUES
    -- Gesamtkennzahlen
    ('pageviews_total',        5, (SELECT pageviews_total FROM meta_row)),
    ('visits_total',           3, (SELECT visits_total    FROM meta_row)),
    ('uniques_total',          2, (SELECT uniques_total   FROM meta_row)),
    ('bounces_total',          2, (SELECT bounces_total   FROM meta_row)),
    ('bytes_total',         6700, (SELECT bytes_total     FROM meta_row)),
    -- URL-Dimensionen
    ('url_/a_pageviews',       3, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/a')),
    ('url_/b_pageviews',       1, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/b')),
    -- Ein-/Ausstieg
    ('entry_/a_visits',        3, (SELECT v  FROM cube_rows WHERE dim='entry' AND dimkey='/a')),
    ('exit_/c.pdf_visits',     1, (SELECT v  FROM cube_rows WHERE dim='exit'  AND dimkey='/c.pdf')),
    -- Referrer & Keyword
    ('ref_suchmaschine_v',     1, (SELECT v  FROM cube_rows WHERE dim='referrer_type' AND dimkey='Suchmaschine')),
    ('ref_direkt_v',           2, (SELECT v  FROM cube_rows WHERE dim='referrer_type' AND dimkey='Direkt')),
    ('keyword_extrahiert',     1, (SELECT v  FROM cube_rows WHERE dim='keyword' AND dimkey='test begriff')),
    -- Browser / OS / Gerät
    ('browser_Chrome_visits',  3, (SELECT v  FROM cube_rows WHERE dim='browser' AND dimkey='Chrome')),
    ('os_windows_visits',      3, (SELECT v  FROM cube_rows WHERE dim='os'      AND dimkey='Windows')),
    ('device_desktop_visits',  3, (SELECT v  FROM cube_rows WHERE dim='device'  AND dimkey='Desktop')),
    -- HTTP-Methode (alle Hits sind GET)
    ('method_get_pv',          5, (SELECT pv FROM cube_rows WHERE dim='method'  AND dimkey='GET')),
    -- GeoIP
    ('country_US_aus_GeoIP',   1, (SELECT count(*)::INT FROM cube_rows WHERE dim='country'  AND dimkey='US')),
    -- Downloads & Filterung
    ('download_pdf_erkannt',   1, (SELECT count(*)::INT FROM cube_rows WHERE dim='download' AND dimkey='/c.pdf')),
    ('asset_css_gefiltert',    0, (SELECT count(*)::INT FROM cube_rows WHERE dimkey LIKE '%style.css%')),
    ('status_404_gefiltert',   0, (SELECT count(*)::INT FROM cube_rows WHERE dim='status'   AND dimkey='404'))
)
SELECT
  CASE WHEN COALESCE(act,-1) = exp THEN 'PASS' ELSE 'FAIL' END AS status,
  c AS pruefung, exp AS soll, COALESCE(act,-1) AS ist
FROM checks ORDER BY status DESC, c;
