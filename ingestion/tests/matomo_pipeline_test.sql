-- Matomo pipeline test: checks matomo_to_cube.sql against a small, real,
-- frozen fixture (ingestion/tests/matomo_fixture/, provenance + regeneration
-- steps in its README.md -- real Matomo 5.12.0 Reporting API responses for a
-- 5-request/3-visitor seed log, not hand-written). Outputs PASS/FAIL per check,
-- same pattern as pipeline_test.sql (the log-path equivalent).
.read 'matomo_to_cube.sql'

WITH checks(c, exp, act) AS (
  VALUES
    -- daily_rows (VisitsSummary.get)
    ('daily_visits',              3, (SELECT visits    FROM daily_rows WHERE datum = DATE '2026-06-01')),
    ('daily_pageviews',           5, (SELECT pageviews FROM daily_rows WHERE datum = DATE '2026-06-01')),
    ('daily_uniques',             3, (SELECT uniques   FROM daily_rows WHERE datum = DATE '2026-06-01')),
    ('daily_bounces',             1, (SELECT bounces   FROM daily_rows WHERE datum = DATE '2026-06-01')),
    ('daily_bytes_not_tracked',   0, (SELECT bytes     FROM daily_rows WHERE datum = DATE '2026-06-01')),
    -- url (Actions.getPageUrls, flat) -- pv <- nb_hits, v <- nb_visits
    ('url_/a_pv',                 3, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/a')),
    ('url_/b_pv',                 1, (SELECT pv FROM cube_rows WHERE dim='url' AND dimkey='/b')),
    -- download (Actions.getDownloads) -- dimkey is the bare host+path Matomo
    -- reports (no scheme), matches the log path's dimkey convention.
    ('download_pdf_pv',           1, (SELECT pv FROM cube_rows WHERE dim='download' AND dimkey='fixture.example.org/c.pdf')),
    -- entry/exit (pv/v field mapping differs per dim, see matomo_to_cube.sql)
    ('entry_/a_pv',                5, (SELECT pv FROM cube_rows WHERE dim='entry' AND dimkey='/a')),
    ('entry_/a_v',                 3, (SELECT v  FROM cube_rows WHERE dim='entry' AND dimkey='/a')),
    ('exit_/a_v',                  2, (SELECT v  FROM cube_rows WHERE dim='exit'  AND dimkey='/a')),
    ('exit_/b_v',                  1, (SELECT v  FROM cube_rows WHERE dim='exit'  AND dimkey='/b')),
    -- country: cube dimkey must be the uppercase ISO-2 CODE, not Matomo's
    -- display-name label ("United States") -- see matomo_to_cube.sql.
    ('country_US_v',               2, (SELECT v FROM cube_rows WHERE dim='country' AND dimkey='US')),
    ('country_AU_v',                1, (SELECT v FROM cube_rows WHERE dim='country' AND dimkey='AU')),
    ('country_no_display_names',   0, (SELECT count(*)::INT FROM cube_rows WHERE dim='country' AND dimkey NOT SIMILAR TO '[A-Z]{2}')),
    -- browser / os / device
    ('browser_Chrome_v',           2, (SELECT v FROM cube_rows WHERE dim='browser' AND dimkey='Chrome')),
    ('browser_Edge_v',              1, (SELECT v FROM cube_rows WHERE dim='browser' AND dimkey='Microsoft Edge')),
    ('os_Windows_v',                3, (SELECT v FROM cube_rows WHERE dim='os' AND dimkey='Windows')),
    ('device_Desktop_v',            3, (SELECT v FROM cube_rows WHERE dim='device' AND dimkey='Desktop')),
    ('device_zero_visit_types_dropped', 0, (SELECT count(*)::INT FROM cube_rows WHERE dim='device' AND dimkey<>'Desktop')),
    -- referrer_type: Matomo's own labels ("Direct Entry", "Search Engines")
    -- must map to the contract's neutral keys (direct/search/social/website).
    ('reftype_direct_v',            2, (SELECT v FROM cube_rows WHERE dim='referrer_type' AND dimkey='direct')),
    ('reftype_search_v',            1, (SELECT v FROM cube_rows WHERE dim='referrer_type' AND dimkey='search')),
    ('reftype_no_matomo_labels',    0, (SELECT count(*)::INT FROM cube_rows WHERE dim='referrer_type' AND dimkey IN ('Direct Entry','Search Engines'))),
    -- keyword (Referrers.getKeywords)
    ('keyword_extracted_v',         1, (SELECT v FROM cube_rows WHERE dim='keyword' AND dimkey='fixture test')),
    -- hour: Matomo's numeric label normalized to zero-padded '00'..'23'
    ('hour_10_v',                   1, (SELECT v FROM cube_rows WHERE dim='hour' AND dimkey='10')),
    ('hour_14_v',                   1, (SELECT v FROM cube_rows WHERE dim='hour' AND dimkey='14')),
    ('hour_zero_rows_dropped',      0, (SELECT count(*)::INT FROM cube_rows WHERE dim='hour' AND dimkey='00')),
    -- deliberate v1 gaps (docs/matomo-import.md "Known gaps") stay empty
    ('status_not_tracked_by_matomo', 0, (SELECT count(*)::INT FROM cube_rows WHERE dim='status')),
    ('method_not_tracked_by_matomo', 0, (SELECT count(*)::INT FROM cube_rows WHERE dim='method')),
    ('browser_version_not_split',    0, (SELECT count(*)::INT FROM cube_rows WHERE dim='browser_version')),
    -- schema v2: Matomo path only ever writes root dims -> parent always NULL
    ('all_rows_parent_null',         0, (SELECT count(*)::INT FROM cube_rows WHERE parent IS NOT NULL))
)
SELECT
  CASE WHEN COALESCE(act,-1) = exp THEN 'PASS' ELSE 'FAIL' END AS status,
  c AS check_name, exp AS expected, COALESCE(act,-1) AS actual
FROM checks ORDER BY status DESC, c;
