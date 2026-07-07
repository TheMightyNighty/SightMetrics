-- ===========================================================================
-- Log format: json_ecs (structured JSON logs, ECS-like schema, one
-- JSON line per request, e.g. nginx log_format ... escape=json).
--
-- Expected schema per line (excerpt, see docs/ingestion-runbook.md §7):
--   {"@timestamp":"<ISO8601>",
--    "client":{"ip":"..."},
--    "http":{"request":{"method":"..."},
--             "response":{"status_code":"...","bytes":"..."}},
--    "app":{"url_path":"...","req":{"referer":"..."}},
--    "user_agent":{"original":"..."}}
--
-- The app level must be called "app", not "HTTP": a second top-level key
-- that differs from "http" only in case collides with DuckDB's
-- case-insensitive column-name resolution. Extraction is done
-- via json_extract_string() on plain JSON paths (no struct access,
-- no read_ndjson auto-typing): this avoids the name collision and keeps
-- tsraw as a plain string, compatible with the strptime/tsformat logic in
-- transform.sql (as with the regex path).
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
    url      := json_extract_string(line, '$.app.url_path'),
    status   := json_extract_string(line, '$.http.response.status_code'),
    size     := json_extract_string(line, '$.http.response.bytes'),
    referrer := json_extract_string(line, '$.app.req.referer'),
    ua       := json_extract_string(line, '$.user_agent.original')
) AS g
FROM raw_lines;
