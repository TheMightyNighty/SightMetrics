-- ===========================================================================
-- SightMetrics - privacy step: IP anonymization + query-string removal.
--
-- Runs directly after the parser (log_formats/*.sql) and before day_cut.sql /
-- day_filter.sql, geo_sources/v6_ranges.sql and transform.sql, so no later
-- step - geo lookup, visitor key, cube - ever sees a full IP or a query
-- string. The raw data only remains in raw_lines (the log text), which is
-- never written to the sink.
--
-- 1) IP: IPv4 -> last octet zeroed (a.b.c.0), IPv6 -> /48 prefix,
--    IPv4-mapped IPv6 (::ffff:a.b.c.d) masked like IPv4 so it stays
--    resolvable for the geo lookup; non-IP values ('-') are left untouched.
--    Geo accuracy is unaffected (ranges are coarser than /24 resp. /48);
--    'uniques' can drop marginally, since the visitor key (md5 of
--    ip|ua|daily salt) now merges visitors sharing a /24 and the same UA.
--
-- 2) URL: everything from the first '?' or '#' is dropped - query parameters
--    routinely carry personal data. SM_URL_KEEP_PARAMS (variable
--    url_keep_params, comma-separated) keeps named parameters, for TYPO3
--    installations without slug URLs where the page identity lives in '?id='.
--    The referrer is deliberately NOT stripped: the 'keyword' dimension is
--    derived from its '?q=' parameter.
--
-- Expects: parsed_lines(rid, g) from log_formats/*.sql.
-- Parameters (SET VARIABLE): url_keep_params (default '' = drop everything)
-- ===========================================================================
SET VARIABLE url_keep_params = COALESCE(getvariable('url_keep_params'), '');

-- url_keep_params -> regex matching exactly the parameters to keep, built once
-- instead of per row. Everything outside [A-Za-z0-9_.-] is stripped from the
-- list, so no parameter name can smuggle regex metacharacters into the
-- pattern. Empty list -> empty pattern = keep nothing.
SET VARIABLE url_keep_re = (
  SELECT CASE WHEN alt = '' THEN '' ELSE '(?:^|&)((?:' || alt || ')=[^&]*)' END
  FROM (SELECT regexp_replace(
                 regexp_replace(
                   regexp_replace(getvariable('url_keep_params'), '[^A-Za-z0-9_,.-]', '', 'g'),
                   ',+', '|', 'g'),
                 '^\||\|$', '', 'g') AS alt));

-- IPv4 -> a.b.c.0, IPv6 -> /48, IPv4-mapped IPv6 -> ::ffff:a.b.c.0.
-- The IPv6 branch cuts the textual form before '::' to three groups; already
-- compressed addresses ('2001:db8::1', '::1') fall out of the same expression.
CREATE OR REPLACE TEMP MACRO sm_anon_ip(ip) AS
  CASE
    WHEN ip IS NULL THEN NULL
    WHEN regexp_matches(ip, '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')
      THEN regexp_replace(ip, '\.\d{1,3}$', '.0')
    WHEN regexp_matches(ip, '^(?i)::ffff:\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')
      THEN regexp_replace(ip, '\.\d{1,3}$', '.0')
    WHEN contains(ip, ':')
      THEN array_to_string(str_split(split_part(ip, '::', 1), ':')[1:3], ':') || '::'
    ELSE ip
  END;

-- The query string reduced to the parameters url_keep_re names, in their
-- original order ('' when nothing is kept).
CREATE OR REPLACE TEMP MACRO sm_kept_query(url, keep_re) AS
  CASE WHEN keep_re = '' THEN ''
       ELSE array_to_string(
              regexp_extract_all(regexp_extract(url, '\?([^#]*)', 1), keep_re, 1), '&')
  END;

-- URL without query string/fragment, plus the kept parameters.
CREATE OR REPLACE TEMP MACRO sm_strip_url(url, keep_re) AS
  CASE
    WHEN url IS NULL THEN NULL
    WHEN NOT contains(url, '?') THEN split_part(url, '#', 1)
    ELSE split_part(split_part(url, '?', 1), '#', 1)
         || CASE WHEN sm_kept_query(url, keep_re) = '' THEN ''
                 ELSE '?' || sm_kept_query(url, keep_re) END
  END;

-- In-place rewrite; parsed_lines keeps its rid order and struct layout.
UPDATE parsed_lines SET g = struct_pack(
    ip       := sm_anon_ip(g.ip),
    tsraw    := g.tsraw,
    method   := g.method,
    url      := sm_strip_url(g.url, getvariable('url_keep_re')),
    status   := g.status,
    size     := g.size,
    referrer := g.referrer,
    ua       := g.ua);
