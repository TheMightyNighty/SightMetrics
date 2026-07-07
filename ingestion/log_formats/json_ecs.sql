-- ===========================================================================
-- Log-Format: json_ecs (strukturierte JSON-Logs, ECS-aehnliches Schema, eine
-- JSON-Zeile pro Request, z.B. nginx log_format ... escape=json).
--
-- Erwartetes Schema je Zeile (Auszug, siehe docs/ingestion-runbook.md §7):
--   {"@timestamp":"<ISO8601>",
--    "client":{"ip":"..."},
--    "http":{"request":{"method":"..."},
--             "response":{"status_code":"...","bytes":"..."}},
--    "app":{"url_path":"...","req":{"referer":"..."}},
--    "user_agent":{"original":"..."}}
--
-- Die App-Ebene muss "app" heissen, nicht "HTTP": ein zweiter Top-Level-Key,
-- der sich von "http" nur in Gross-/Kleinschreibung unterscheidet, kollidiert
-- mit DuckDBs case-insensitiver Spaltennamens-Aufloesung. Extraktion erfolgt
-- ueber json_extract_string() auf reinen JSON-Pfaden (kein struct-Zugriff,
-- kein read_ndjson-Auto-Typing): das vermeidet die Namenskollision und haelt
-- tsraw als reinen String, kompatibel mit der strptime/tsformat-Logik in
-- transform.sql (wie beim Regex-Pfad).
--
-- Erzeugt TEMP TABLE parsed_lines(g) im selben Schema wie log_formats/regex.sql.
-- Parameter (SET VARIABLE): logpath, tsformat (Standard siehe lib_logformat.sh)
-- ===========================================================================
-- raw_lines: siehe log_formats/regex.sql (Reihenfolge + Byte-Laenge fuer day_cut.sql).
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
