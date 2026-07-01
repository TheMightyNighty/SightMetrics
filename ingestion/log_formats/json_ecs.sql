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
-- WICHTIG: "app" (NICHT "HTTP") fuer die App-Ebene - ein zweiter Top-Level-Key,
-- der sich von "http" nur in Gross-/Kleinschreibung unterscheidet, kollidiert
-- mit DuckDBs (undokumentierter) case-insensitiver Spaltennamens-Aufloesung.
-- Deshalb bewusst per json_extract_string() auf reinen JSON-Pfaden gearbeitet
-- (kein struct-Zugriff/kein read_ndjson-Auto-Typing) - das umgeht sowohl die
-- Namenskollision als auch ungewollte automatische Typ-/Zeitzonen-Konvertierung
-- von "@timestamp" und haelt tsraw als reinen String, exakt wie beim
-- Regex-Pfad (-> gleiche strptime/tsformat-Logik in transform.sql).
--
-- Erzeugt TEMP TABLE parsed_lines(g) im selben Schema wie log_formats/regex.sql.
-- Parameter (SET VARIABLE): logpath, tsformat (Standard siehe lib_logformat.sh)
-- ===========================================================================
CREATE OR REPLACE TEMP TABLE parsed_lines AS
SELECT struct_pack(
    ip       := json_extract_string(line, '$.client.ip'),
    tsraw    := json_extract_string(line, '$."@timestamp"'),
    method   := json_extract_string(line, '$.http.request.method'),
    url      := json_extract_string(line, '$.app.url_path'),
    status   := json_extract_string(line, '$.http.response.status_code'),
    size     := json_extract_string(line, '$.http.response.bytes'),
    referrer := json_extract_string(line, '$.app.req.referer'),
    ua       := json_extract_string(line, '$.user_agent.original')
) AS g
FROM read_csv(getvariable('logpath'),
     columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true);
