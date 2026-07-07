-- ===========================================================================
-- SightMetrics – day-boundary cut for the incremental log import.
--
-- Problem (runbook §8): the sink REPLACES all days of the batch. If a
-- batch contains only part of a day (typically: the nightly run at 02:00 sees
-- 00:00-02:00 of the current day), the next run would overwrite this day with
-- only the remaining lines – the early hours would be lost.
--
-- Solution: lines from 'cutoff_date' (UTC date, usually "today") are removed
-- from parsed_lines and their bytes are NOT counted as consumed. The
-- offset stays before the first truncated line; the next run then
-- reads the day in full. Requirement: chronologically written
-- logs (standard for access logs) and \n line endings (byte calculation).
--
-- Expects: raw_lines(rid, line, nbytes) + parsed_lines(rid, g) from
-- log_formats/*.sql. Parameters (SET VARIABLE): cutoff_date ('' = no cut),
-- tsformat. Result variable: cut_rid (NULL = nothing cut).
-- The caller (load_cube.sh) exports the consumed bytes via COPY.
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
