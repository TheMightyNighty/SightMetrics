-- ===========================================================================
-- SightMetrics – Gemeinsamer MariaDB-Sink (Abschnitt 11).
-- Erwartet die TEMP-Tabellen daily_rows / cube_rows (sink-neutral erzeugt) und
-- ein per ATTACH ... (TYPE mysql) gemountetes Schema 'm'.
-- Genutzt von:
--   * Log-Pfad:    cube_to_mysql.sql + transform.sql   (load_cube.sh)
--   * Matomo-Pfad: matomo_to_cube.sql                  (matomo_import.sh)
-- Beide Treiber haengen diese Datei via `cat ... | envsubst` an ihren
-- Compute-Teil an, daher werden ${SM_TABLE_*} hier korrekt ersetzt.
-- Inkrementell sicher: nur Tage des aktuellen Batches werden ersetzt.
-- Parameter (SET VARIABLE): site_id, site_name
-- ===========================================================================

-- Schema (idempotent, multi-site)
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_CUBE}  (site_id INTEGER, datum DATE, dim VARCHAR, dimkey VARCHAR, pv BIGINT, v BIGINT);
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_DAILY} (site_id INTEGER, datum DATE, visits BIGINT, pageviews BIGINT, uniques BIGINT, bounces BIGINT, bytes BIGINT);
CREATE TABLE IF NOT EXISTS m.${SM_TABLE_META}  (site_id INTEGER, site VARCHAR, von VARCHAR, bis VARCHAR,
                                    visits_total BIGINT, pageviews_total BIGINT, uniques_total BIGINT,
                                    bounces_total BIGINT, bytes_total BIGINT, erzeugt VARCHAR);

-- Datumsbereich des zu ersetzenden Batches (VARCHAR 'YYYY-MM-DD').
-- Vorrang hat ein explizit gesetzter Bereich range_from/range_to (Matomo-Pfad
-- setzt hier den vollen --from/--to-Chunk, damit auch Tage OHNE neue Daten
-- sauber geleert werden); sonst MIN/MAX der tatsaechlich erzeugten daily_rows
-- (Log-Pfad – range_* ist dort nicht gesetzt -> getvariable() = NULL).
SET VARIABLE d_min = COALESCE(getvariable('range_from'), (SELECT MIN(datum)::VARCHAR FROM daily_rows), '1970-01-01');
SET VARIABLE d_max = COALESCE(getvariable('range_to'),   (SELECT MAX(datum)::VARCHAR FROM daily_rows), '1970-01-01');
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
