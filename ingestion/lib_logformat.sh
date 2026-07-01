# ---------------------------------------------------------------------------
# Gemeinsame Log-Format-Auswahl (source'd von load_cube.sh + fetch_loki_logs.sh).
# Setzt: SM_LOG_REGEX, SM_TS_FORMAT, LOG_FORMAT_SQL (welche log_formats/*.sql
# den Parser aufbaut, siehe dort).
#
# ENV: SM_LOG_FORMAT (combined [Standard] | combined_vhost | common | custom
#      | json_ecs)
#      custom:   SM_LOG_REGEX_CUSTOM (8 Capture-Groups) + SM_TS_FORMAT_CUSTOM
#      json_ecs: strukturierte JSON-Logs (ECS-aehnliches Schema), siehe
#                log_formats/json_ecs.sql fuer das erwartete Feld-Layout.
# ---------------------------------------------------------------------------
SM_LOG_FORMAT="${SM_LOG_FORMAT:-combined}"
LOG_FORMAT_SQL="$(pwd)/log_formats/regex.sql"
case "$SM_LOG_FORMAT" in
  combined)
    # Apache/nginx Combined Log Format:
    # IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"
    SM_LOG_REGEX='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
    SM_TS_FORMAT='%d/%b/%Y:%H:%M:%S %z'
    ;;
  combined_vhost)
    # nginx mit $host:$server_port-Präfix:
    # HOST:PORT IP - - [ts] "METHOD URL PROTO" STATUS SIZE "REFERRER" "UA"
    SM_LOG_REGEX='^\S+:\d+ (\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
    SM_TS_FORMAT='%d/%b/%Y:%H:%M:%S %z'
    ;;
  common)
    # Apache/nginx Common Log Format (ohne Referrer/UA):
    # IP - - [ts] "METHOD URL PROTO" STATUS SIZE
    # Gruppen 7+8 als leere Captures → referrer/ua bleiben ''
    SM_LOG_REGEX='^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+)()()'
    SM_TS_FORMAT='%d/%b/%Y:%H:%M:%S %z'
    ;;
  custom)
    SM_LOG_REGEX="${SM_LOG_REGEX_CUSTOM:?SM_LOG_FORMAT=custom erfordert SM_LOG_REGEX_CUSTOM (8 Capture-Groups: ip,ts,method,url,status,size,referrer,ua)}"
    SM_TS_FORMAT="${SM_TS_FORMAT_CUSTOM:?SM_LOG_FORMAT=custom erfordert SM_TS_FORMAT_CUSTOM (strptime-Format)}"
    ;;
  json_ecs)
    # Strukturierte JSON-Logs (eine Zeile pro Request), $time_iso8601-Timestamp.
    # Feld-Layout siehe log_formats/json_ecs.sql. SM_LOG_REGEX ungenutzt.
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
