# ---------------------------------------------------------------------------
# Shared log format selection (sourced by load_cube.sh + fetch_loki_logs.sh).
# Sets: SM_LOG_REGEX, SM_TS_FORMAT, LOG_FORMAT_SQL (which log_formats/*.sql
# builds the parser, see there).
#
# ENV: SM_LOG_FORMAT (combined [default] | combined_vhost | common | custom
#      | json_ecs)
#      custom:   SM_LOG_REGEX_CUSTOM (8 capture groups) + SM_TS_FORMAT_CUSTOM
#      json_ecs: structured JSON logs (ECS-like schema), see
#                log_formats/json_ecs.sql for the expected field layout.
# ---------------------------------------------------------------------------
SM_LOG_FORMAT="${SM_LOG_FORMAT:-combined}"
LOG_FORMAT_SQL="$(pwd)/log_formats/regex.sql"
case "$SM_LOG_FORMAT" in
  combined)
    # Apache/nginx combined log format:
    # IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"
    SM_LOG_REGEX='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
    SM_TS_FORMAT='%d/%b/%Y:%H:%M:%S %z'
    ;;
  combined_vhost)
    # nginx with $host:$server_port prefix:
    # HOST:PORT IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"
    SM_LOG_REGEX='^\S+:\d+ (\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
    SM_TS_FORMAT='%d/%b/%Y:%H:%M:%S %z'
    ;;
  common)
    # Apache/nginx common log format (without referrer/UA):
    # IP - - [ts] "METHOD URL PROTO" STATUS SIZE
    # Groups 7+8 as empty captures → referrer/ua stay ''
    SM_LOG_REGEX='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+)()()'
    SM_TS_FORMAT='%d/%b/%Y:%H:%M:%S %z'
    ;;
  custom)
    SM_LOG_REGEX="${SM_LOG_REGEX_CUSTOM:?SM_LOG_FORMAT=custom erfordert SM_LOG_REGEX_CUSTOM (8 Capture-Groups: ip,ts,method,url,status,size,referrer,ua)}"
    SM_TS_FORMAT="${SM_TS_FORMAT_CUSTOM:?SM_LOG_FORMAT=custom erfordert SM_TS_FORMAT_CUSTOM (strptime-Format)}"
    ;;
  json_ecs)
    # Structured JSON logs (one line per request), $time_iso8601 timestamp.
    # Field layout see log_formats/json_ecs.sql. SM_LOG_REGEX unused.
    SM_LOG_REGEX=''
    SM_TS_FORMAT='%Y-%m-%dT%H:%M:%S%z'
    LOG_FORMAT_SQL="$(pwd)/log_formats/json_ecs.sql"
    ;;
  *)
    echo "Fehler: unbekanntes SM_LOG_FORMAT='${SM_LOG_FORMAT}'." >&2
    echo "        Gültig: combined (Standard), combined_vhost, common, custom, json_ecs" >&2
    exit 1
    ;;
esac
echo ">> Log-Format: ${SM_LOG_FORMAT}"
