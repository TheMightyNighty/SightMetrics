-- ===========================================================================
-- Log-Format: regex (Apache/nginx Klartext-Zeilen: combined, combined_vhost,
-- common, custom - siehe lib_logformat.sh).
-- Erzeugt TEMP TABLE parsed_lines(g) mit g.ip/tsraw/method/url/status/size/referrer/ua
-- (VARCHAR) aus genau 8 Regex-Capture-Gruppen je Zeile.
-- Parameter (SET VARIABLE): logpath, logregex, tsformat
-- ===========================================================================
SET VARIABLE logregex = COALESCE(
  getvariable('logregex'),
  '^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
);
CREATE OR REPLACE TEMP TABLE parsed_lines AS
SELECT regexp_extract(line,
    getvariable('logregex'),
    ['ip','tsraw','method','url','status','size','referrer','ua']) AS g
FROM read_csv(getvariable('logpath'),
     columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true);
