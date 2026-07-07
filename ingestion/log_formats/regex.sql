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
-- raw_lines: Original-Zeilen mit Reihenfolge (rid) und Byte-Laenge (+1 fuer \n).
-- Wird von day_cut.sql gebraucht, um den Batch byte-genau an der Tagesgrenze
-- abzuschneiden. Nur EIN Lese-Durchgang ueber logpath (kompatibel mit /dev/fd-Streams).
CREATE OR REPLACE TEMP TABLE raw_lines AS
SELECT row_number() OVER () AS rid, line, strlen(line) + 1 AS nbytes
FROM read_csv(getvariable('logpath'),
     columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true);

CREATE OR REPLACE TEMP TABLE parsed_lines AS
SELECT rid, regexp_extract(line,
    getvariable('logregex'),
    ['ip','tsraw','method','url','status','size','referrer','ua']) AS g
FROM raw_lines;
