-- ===========================================================================
-- SightMetrics – Tagesgrenzen-Cut fuer den inkrementellen Log-Import.
--
-- Problem (Runbook §8): der Sink ERSETZT alle Tage des Batches. Enthaelt ein
-- Batch nur einen Teil eines Tages (typisch: nächtlicher Lauf um 02:00 sieht
-- 00:00–02:00 des aktuellen Tages), wuerde der naechste Lauf diesen Tag mit
-- nur den restlichen Zeilen ueberschreiben – die fruehen Stunden gingen verloren.
--
-- Loesung: Zeilen ab 'cutoff_date' (UTC-Datum, i. d. R. "heute") werden aus
-- parsed_lines entfernt und ihre Bytes NICHT als konsumiert gezaehlt. Der
-- Offset bleibt vor der ersten abgeschnittenen Zeile stehen; der naechste Lauf
-- liest den Tag dann vollstaendig. Voraussetzung: chronologisch geschriebene
-- Logs (Standard bei Access-Logs) und \n-Zeilenenden (Byte-Rechnung).
--
-- Erwartet: raw_lines(rid, line, nbytes) + parsed_lines(rid, g) aus
-- log_formats/*.sql. Parameter (SET VARIABLE): cutoff_date ('' = kein Cut),
-- tsformat. Ergebnis-Variable: cut_rid (NULL = nichts abgeschnitten).
-- Der Aufrufer (load_cube.sh) exportiert die konsumierten Bytes per COPY.
-- ===========================================================================

SET VARIABLE cut_rid = (
  SELECT MIN(rid) FROM parsed_lines
  WHERE COALESCE(getvariable('cutoff_date'), '') <> ''
    AND strftime(
          timezone('UTC', try_strptime(g.tsraw,
            COALESCE(getvariable('tsformat'), '%d/%b/%Y:%H:%M:%S %z'))),
          '%Y-%m-%d') >= getvariable('cutoff_date')
);

DELETE FROM parsed_lines
WHERE getvariable('cut_rid') IS NOT NULL AND rid >= getvariable('cut_rid');
