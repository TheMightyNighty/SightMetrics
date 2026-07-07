-- ===========================================================================
-- Log format: regex (Apache/nginx plain-text lines: combined, combined_vhost,
-- common, custom - see lib_logformat.sh).
-- Creates TEMP TABLE parsed_lines(g) with g.ip/tsraw/method/url/status/size/referrer/ua
-- (VARCHAR) from exactly 8 regex capture groups per line.
-- Parameters (SET VARIABLE): logpath, logregex, tsformat
-- ===========================================================================
SET VARIABLE logregex = COALESCE(
  getvariable('logregex'),
  '^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
);
-- raw_lines: original lines with order (rid) and byte length (+1 for \n).
-- Needed by day_cut.sql to cut the batch byte-exactly at the day boundary.
-- Only ONE read pass over logpath (compatible with /dev/fd streams).
CREATE OR REPLACE TEMP TABLE raw_lines AS
SELECT row_number() OVER () AS rid, line, strlen(line) + 1 AS nbytes
FROM read_csv(getvariable('logpath'),
     columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true);

CREATE OR REPLACE TEMP TABLE parsed_lines AS
SELECT rid, regexp_extract(line,
    getvariable('logregex'),
    ['ip','tsraw','method','url','status','size','referrer','ua']) AS g
FROM raw_lines;
