-- ===========================================================================
-- SightMetrics / Abschnitt 11: DuckDB rechnet, MariaDB serviert. MULTI-SITE.
-- Auswertungslogik in transform.sql (sink-neutral); hier der MariaDB-Sink.
-- Inkrementell sicher: nur Daten des aktuell verarbeiteten Datumsbereichs
-- werden ersetzt. DELETE laeuft ueber mysql_execute() mit rohem MariaDB-SQL,
-- da DuckDBs MySQL-Connector bei Bereichs-DELETEs ::DATE-Syntax generiert,
-- die MariaDB nicht versteht. Meta wird aus der vollstaendigen Daily-Tabelle
-- neu berechnet (korrekte Gesamtzahlen ueber alle historischen Tage).
-- Voraussetzung: Schema 'm' per ATTACH ... (TYPE mysql) (load_cube.sh).
-- Parameter (SET VARIABLE): logpath, geopath, site_name, tagessalt, site_id
-- Tabellennamen: ${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}
--   werden von load_cube.sh via envsubst ersetzt (ENV-Vars, Standard: cube/daily/meta).
-- ===========================================================================
.read 'transform.sql'

-- Schema (idempotent, multi-site)
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_CUBE}  (site_id INTEGER, datum DATE, dim VARCHAR, dimkey VARCHAR, pv BIGINT, v BIGINT);
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_DAILY} (site_id INTEGER, datum DATE, visits BIGINT, pageviews BIGINT, uniques BIGINT, bounces BIGINT, bytes BIGINT);
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_META}  (site_id INTEGER, site VARCHAR, von VARCHAR, bis VARCHAR,
                                    visits_total BIGINT, pageviews_total BIGINT, uniques_total BIGINT,
                                    bounces_total BIGINT, bytes_total BIGINT, erzeugt VARCHAR);

-- Datumsbereich des aktuellen Batches (VARCHAR 'YYYY-MM-DD' aus strftime).
-- COALESCE fuer den unwahrscheinlichen Fall eines leeren Batches nach dem Filter.
SET VARIABLE d_min = COALESCE((SELECT MIN(datum) FROM daily_rows), '1970-01-01');
SET VARIABLE d_max = COALESCE((SELECT MAX(datum) FROM daily_rows), '1970-01-01');
SET VARIABLE sid   = getvariable('site_id')::INTEGER::VARCHAR;

-- Einfaches Bereichs-DELETE ueber mysql_execute() (rohes MariaDB-SQL).
-- CHR(39) = einfaches Anführungszeichen; vermeidet DuckDB-Typ-Annotierungen (::DATE).
-- Beruehrt ausschliesslich Tage dieses Batches; andere Sites/Tage bleiben erhalten.
CALL mysql_execute('m',
  'DELETE FROM ${SM_TABLE_CUBE}  WHERE site_id = ' || getvariable('sid')
  || ' AND datum >= ' || CHR(39) || getvariable('d_min') || CHR(39)
  || ' AND datum <= ' || CHR(39) || getvariable('d_max') || CHR(39)
);
CALL mysql_execute('m',
  'DELETE FROM ${SM_TABLE_DAILY} WHERE site_id = ' || getvariable('sid')
  || ' AND datum >= ' || CHR(39) || getvariable('d_min') || CHR(39)
  || ' AND datum <= ' || CHR(39) || getvariable('d_max') || CHR(39)
);

INSERT INTO m.${SM_TABLE_DAILY} SELECT getvariable('site_id')::INTEGER, datum, visits, pageviews, uniques, bounces, bytes FROM daily_rows;
INSERT INTO m.${SM_TABLE_CUBE}  SELECT getvariable('site_id')::INTEGER, CAST(datum AS DATE), dim, dimkey, pv, v FROM cube_rows;

-- Meta: Neuberechnung aus der vollstaendigen Daily-Tabelle.
-- Uniques-Total ist additiv angenahert (Tageswerte summiert).
CALL mysql_execute('m', 'DELETE FROM ${SM_TABLE_META} WHERE site_id = ' || getvariable('sid'));
INSERT INTO m.${SM_TABLE_META}
  SELECT getvariable('site_id')::INTEGER,
         getvariable('site_name'),
         CAST(MIN(datum) AS VARCHAR), CAST(MAX(datum) AS VARCHAR),
         SUM(visits)::BIGINT, SUM(pageviews)::BIGINT, SUM(uniques)::BIGINT,
         SUM(bounces)::BIGINT, SUM(bytes)::BIGINT,
         strftime(now(), '%Y-%m-%d %H:%M')
  FROM m.${SM_TABLE_DAILY} WHERE site_id = getvariable('site_id')::INTEGER;

SELECT 'cube_rows_this_site' k, (SELECT count(*) FROM m.${SM_TABLE_CUBE} WHERE site_id = getvariable('site_id')::INTEGER) n
UNION ALL SELECT 'sites_total', (SELECT count(DISTINCT site_id) FROM m.${SM_TABLE_META});
