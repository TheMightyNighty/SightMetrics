-- ===========================================================================
-- Log format: json_ecs (structured JSON logs, ECS-like schema, one
-- JSON line per request, e.g. nginx log_format ... escape=json).
--
-- Expected schema per line (excerpt, see docs/ingestion-runbook.md §7):
--   {"@timestamp":"<ISO8601>",
--    "client":{"ip":"..."},
--    "http":{"request":{"method":"..."},
--             "response":{"status_code":"...","bytes":"..."}},
--    "HTTP":{"url_path":"...","req":{"referer":"..."}},
--    "user_agent":{"original":"..."}}
--
-- The "HTTP" and "http" keys differ only in case (see the nginx log_format in
-- demo/nginx-log-format.conf). DuckDB resolves column names case-insensitively,
-- so read_ndjson auto-typing would collapse the two into one colliding column.
-- We therefore extract via json_extract_string() on explicit JSON paths (no
-- struct access, no read_ndjson auto-typing): this keeps the case-distinct keys
-- separate and keeps tsraw as a plain string, compatible with the
-- strptime/tsformat logic in transform.sql (as with the regex path).
--
-- Lines that are NOT valid JSON are SKIPPED (json_valid filter below): log
-- streams often carry error-log lines in a different plain-text format in
-- between (e.g. nginx error.log scraped into the same Loki stream without its
-- own label). json_extract_string() would abort the whole import on the first
-- such line ("Malformed JSON ..."); skipping matches the regex path, where a
-- non-matching line is dropped, not fatal. Valid-JSON lines with a different
-- schema yield NULL fields and are dropped later by transform.sql (ts IS NULL).
--
-- Creates TEMP TABLE parsed_lines(g) in the same schema as log_formats/regex.sql.
-- Parameters (SET VARIABLE): logpath, tsformat (default see lib_logformat.sh)
-- ===========================================================================
-- raw_lines: see log_formats/regex.sql (order + byte length for day_cut.sql).
CREATE OR REPLACE TEMP TABLE raw_lines AS
SELECT row_number() OVER () AS rid, line, strlen(line) + 1 AS nbytes
FROM read_csv(getvariable('logpath'),
     columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true);

CREATE OR REPLACE TEMP TABLE parsed_lines AS
SELECT rid, struct_pack(
    ip       := json_extract_string(line, '$.client.ip'),
    tsraw    := json_extract_string(line, '$."@timestamp"'),
    method   := json_extract_string(line, '$.http.request.method'),
    url      := json_extract_string(line, '$.HTTP.url_path'),
    status   := json_extract_string(line, '$.http.response.status_code'),
    size     := json_extract_string(line, '$.http.response.bytes'),
    referrer := json_extract_string(line, '$.HTTP.req.referer'),
    ua       := json_extract_string(line, '$.user_agent.original')
) AS g
FROM raw_lines
-- Skip non-JSON lines (mixed streams, see header). raw_lines keeps ALL lines,
-- so the byte accounting of day_cut.sql stays exact (skipped bytes count as
-- consumed - junk is never re-read).
WHERE json_valid(line);
