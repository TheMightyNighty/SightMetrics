-- ===========================================================================
-- Optional browser/OS lookup based on the device-detector lists
-- (ua/browsers.tsv + ua/oss.tsv, built by tools/fetch_ua_lists.sh).
-- Loaded by lib_ua.sh only when the lists exist; without them transform.sql
-- keeps its built-in LIKE heuristic.
--
-- Semantics like the device-detector engine: patterns are applied in file
-- order with the engine's boundary wrapper, the FIRST match wins. The version
-- template supports $1/$2 (capture groups of the original pattern; the
-- wrapper only adds non-capturing groups, so indexes are stable).
--
-- Builds TEMP TABLE ua_lookup(ua, browser, browser_ver, os, os_ver) for the
-- distinct user agents of the current batch (parsed_lines must exist).
-- Parameters (SET VARIABLE): ua_browsers_path, ua_oss_path
-- ===========================================================================

CREATE OR REPLACE TEMP TABLE _batch_uas AS
SELECT DISTINCT g.ua AS ua FROM parsed_lines
WHERE g.ua IS NOT NULL AND g.ua <> '' AND g.ua <> '-';

CREATE OR REPLACE TEMP MACRO dd_wrap(pat) AS
  '(?i)(?:^|[^A-Z0-9_-]|[^A-Z0-9-]_|sprd-|MZ-)(?:' || pat || ')';

-- Version template: replace $1/$2 with the extracted groups, trim leftovers.
CREATE OR REPLACE TEMP MACRO dd_version(ua, pat, tmpl) AS
  trim(
    replace(
      replace(COALESCE(tmpl, ''), '$1', COALESCE(regexp_extract(ua, dd_wrap(pat), 1), '')),
      '$2', COALESCE(regexp_extract(ua, dd_wrap(pat), 2), '')
    ), ' .');

CREATE OR REPLACE TEMP TABLE _ua_browser AS
SELECT ua, name, ver FROM (
  SELECT u.ua, b.name,
         dd_version(u.ua, b.regex, b.version) AS ver,
         row_number() OVER (PARTITION BY u.ua ORDER BY b.prio) AS rn
  FROM _batch_uas u
  JOIN read_csv(getvariable('ua_browsers_path'),
       columns={'prio':'INTEGER','regex':'VARCHAR','name':'VARCHAR','version':'VARCHAR'},
       delim='\t', header=false, quote='', escape='', ignore_errors=true) b
    ON b.regex NOT LIKE '#%' AND regexp_matches(u.ua, dd_wrap(b.regex))
) WHERE rn = 1;

CREATE OR REPLACE TEMP TABLE _ua_os AS
SELECT ua, name, ver FROM (
  SELECT u.ua, o.name,
         dd_version(u.ua, o.regex, o.version) AS ver,
         row_number() OVER (PARTITION BY u.ua ORDER BY o.prio) AS rn
  FROM _batch_uas u
  JOIN read_csv(getvariable('ua_oss_path'),
       columns={'prio':'INTEGER','regex':'VARCHAR','name':'VARCHAR','version':'VARCHAR'},
       delim='\t', header=false, quote='', escape='', ignore_errors=true) o
    ON o.regex NOT LIKE '#%' AND regexp_matches(u.ua, dd_wrap(o.regex))
) WHERE rn = 1;

-- Windows NT -> marketing version (the device-detector engine maps this in
-- PHP code, not in the yml; small stable table ported here).
CREATE OR REPLACE TEMP MACRO win_version(v) AS
  CASE WHEN v LIKE '10.0%' THEN '10/11'
       WHEN v LIKE '6.3%'  THEN '8.1'
       WHEN v LIKE '6.2%'  THEN '8'
       WHEN v LIKE '6.1%'  THEN '7'
       WHEN v LIKE '6.0%'  THEN 'Vista'
       WHEN v LIKE '5.1%' OR v LIKE '5.2%' THEN 'XP'
       ELSE v END;

CREATE OR REPLACE TEMP TABLE ua_lookup AS
SELECT u.ua,
       b.name AS browser,
       COALESCE(b.ver, '') AS browser_ver,
       o.name AS os,
       CASE WHEN o.name IS NULL THEN NULL
            WHEN o.name = 'Windows' AND COALESCE(o.ver,'') <> ''
              THEN trim(o.name || ' ' || win_version(o.ver))
            ELSE trim(o.name || ' ' || COALESCE(o.ver, '')) END AS os_ver
FROM _batch_uas u
LEFT JOIN _ua_browser b ON b.ua = u.ua
LEFT JOIN _ua_os o ON o.ua = u.ua;
