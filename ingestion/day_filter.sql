-- ===========================================================================
-- SightMetrics – day-window filter for the Loki import (fetch_loki_logs.sh).
--
-- Problem: Loki's query window filters by INGESTION timestamp, but the day a
-- hit belongs to is decided by the timestamp INSIDE the log line (written by
-- nginx). Lines arriving in Loki shortly after local midnight still carry a
-- 23:59:59 timestamp of the previous day; without this filter they would show
-- up as a tiny extra daily row for day N-1 inside day N's batch – which the
-- sink does NOT replace (its range DELETE only covers day N), so it would
-- pile up next to the previous day's real row.
--
-- Solution: fetch_loki_logs.sh queries Loki with a safety margin
-- (LOKI_MARGIN_SECONDS) around the day window and this filter then keeps
-- exactly the lines whose LOCAL calendar day (tz) lies within
-- [range_from, range_to] – the line's own timestamp is authoritative.
-- Consecutive day fetches overlap by the margin, but each line lands in
-- exactly one day, so nothing is double-counted.
--
-- Expects: parsed_lines(rid, g) from log_formats/*.sql.
-- Parameters (SET VARIABLE): range_from / range_to (empty or unset = filter
--   disabled), tz, tsformat. Lines with unparseable timestamps are KEPT
--   (transform.sql drops them later via ts IS NULL) – rejecting format junk
--   is not this filter's job.
-- ===========================================================================

DELETE FROM parsed_lines
WHERE COALESCE(getvariable('range_from'), '') <> ''
  AND strftime(
        timezone(COALESCE(NULLIF(getvariable('tz'), ''), 'UTC'),
          try_strptime(g.tsraw,
            COALESCE(getvariable('tsformat'), '%d/%b/%Y:%H:%M:%S %z'))),
        '%Y-%m-%d')
      NOT BETWEEN getvariable('range_from') AND getvariable('range_to');
