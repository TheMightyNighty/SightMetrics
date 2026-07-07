-- Pipeline-Test: prüft die Auswertungslogik (transform.sql) gegen das Fixture
-- mit bekannten Soll-Werten. Gibt je Prüfung PASS/FAIL aus.
.read 'transform.sql'

WITH checks(c, exp, act) AS (
  VALUES
    -- Gesamtkennzahlen (Fixture: 5 IPv4-Hits + 1 IPv6/Edge-Hit; Bot-Zeile zaehlt nicht)
    ('pageviews_total',        6, (SELECT pageviews_total FROM meta_row)),
    ('visits_total',           4, (SELECT visits_total    FROM meta_row)),
    ('uniques_total',          3, (SELECT uniques_total   FROM meta_row)),
    ('bounces_total',          3, (SELECT bounces_total   FROM meta_row)),
    ('bytes_total',         7200, (SELECT bytes_total     FROM meta_row)),
    -- URL-Dimensionen
    ('url_/a_pageviews',       4, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/a')),
    ('url_/b_pageviews',       1, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/b')),
    -- Ein-/Ausstieg
    ('entry_/a_visits',        4, (SELECT v  FROM cube_rows WHERE dim='entry' AND dimkey='/a')),
    ('exit_/c.pdf_visits',     1, (SELECT v  FROM cube_rows WHERE dim='exit'  AND dimkey='/c.pdf')),
    -- Referrer & Keyword (Heuristik verankert: www.google.com zaehlt, nichtgoogle.example nicht)
    ('ref_suchmaschine_v',     1, (SELECT v  FROM cube_rows WHERE dim='referrer_type' AND dimkey='Suchmaschine')),
    ('ref_direkt_v',           3, (SELECT v  FROM cube_rows WHERE dim='referrer_type' AND dimkey='Direkt')),
    ('keyword_extrahiert',     1, (SELECT v  FROM cube_rows WHERE dim='keyword' AND dimkey='test begriff')),
    -- Browser / OS / Gerät (Edge-UA enthaelt 'Chrome', muss aber als Edge zaehlen)
    ('browser_Chrome_visits',  3, (SELECT v  FROM cube_rows WHERE dim='browser' AND dimkey='Chrome')),
    ('browser_Edge_visits',    1, (SELECT v  FROM cube_rows WHERE dim='browser' AND dimkey='Edge')),
    ('os_windows_visits',      4, (SELECT v  FROM cube_rows WHERE dim='os'      AND dimkey='Windows')),
    ('device_desktop_visits',  4, (SELECT v  FROM cube_rows WHERE dim='device'  AND dimkey='Desktop')),
    -- HTTP-Methode (alle Nicht-Bot-Hits sind GET)
    ('method_get_pv',          6, (SELECT pv FROM cube_rows WHERE dim='method'  AND dimkey='GET')),
    -- GeoIP (IPv6 hat kein ipint -> Land '??', crasht aber den Import nicht)
    ('country_US_aus_GeoIP',   1, (SELECT count(*)::INT FROM cube_rows WHERE dim='country'  AND dimkey='US')),
    ('country_ipv6_unbekannt', 1, (SELECT v  FROM cube_rows WHERE dim='country'  AND dimkey='??')),
    -- Downloads & Filterung
    ('download_pdf_erkannt',   1, (SELECT count(*)::INT FROM cube_rows WHERE dim='download' AND dimkey='/c.pdf')),
    ('asset_css_gefiltert',    0, (SELECT count(*)::INT FROM cube_rows WHERE dimkey LIKE '%style.css%')),
    -- Statuscode-Panel: Fehler sind sichtbar (aus hits_all, vor dem <400-Filter)
    ('status_404_sichtbar_pv', 1, (SELECT pv FROM cube_rows WHERE dim='status'   AND dimkey='404')),
    ('status_200_pv',          6, (SELECT pv FROM cube_rows WHERE dim='status'   AND dimkey='200')),
    -- Bot-Filter: Googlebot-Zeile ist komplett ausgeschlossen (kein 'Andere'-Browser)
    ('bot_gefiltert',          0, (SELECT count(*)::INT FROM cube_rows WHERE dim='browser' AND dimkey='Andere'))
)
SELECT
  CASE WHEN COALESCE(act,-1) = exp THEN 'PASS' ELSE 'FAIL' END AS status,
  c AS pruefung, exp AS soll, COALESCE(act,-1) AS ist
FROM checks ORDER BY status DESC, c;
