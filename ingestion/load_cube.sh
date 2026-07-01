#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics-Ingestion: Log -> DuckDB-Cube -> MariaDB (inkrementell).
# Einziger Schreiber der Cube-DB (Abschnitt 11.1). Misst Wall + CPU.
#
# Nutzung:  ./load_cube.sh [LOGDATEI] [SITE-NAME] [SITE-ID]
#
# Offset-Tracking: verarbeitet nur neue Zeilen seit dem letzten Lauf.
#   STATE_DIR         Verzeichnis fuer .offset-Dateien  (Standard: ../state/)
#
# Secrets:
#   CUBE_DSN          DuckDB-MySQL-DSN  (host=... port=... user=... password=... database=...)
#   CUBE_DSN_FILE     Pfad zu einer Datei mit dem DSN  (Docker-Secrets-Pattern,
#                     Standard: /run/secrets/cube_dsn)
#
# Tabellennamen (Standard: cube / daily / meta):
#   SM_TABLE_CUBE     Name der Cube-Tabelle
#   SM_TABLE_DAILY    Name der Daily-Tabelle
#   SM_TABLE_META     Name der Meta-Tabelle
#
# GeoIP (TODO für Betreiber: Datei ist NICHT Teil des Repos, siehe
#        docs/ingestion-runbook.md -> Abschnitt "GeoIP-Datensatz"):
#   SM_GEO_SOURCE     native (Standard) | ip2location | dbip | maxmind
#                     legt fest, welches geo_sources/<quelle>.sql geladen wird.
#   SM_GEO_PATH       Pfad zur Geo-CSV (Standard: geo/country-ipv4-num.csv)
#   SM_GEO_LOC_PATH   nur SM_GEO_SOURCE=maxmind: Pfad zu
#                     GeoLite2-Country-Locations-en.csv
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
DUCKDB="$(pwd)/bin/duckdb"
LOGFILE="${1:-${REPO}/logs/example_1k.log}"
SITENAME="${2:-Musterbehörde}"
SITEID="${3:-1}"

# ---- Geo-Quelle -------------------------------------------------------------
SM_GEO_SOURCE="${SM_GEO_SOURCE:-native}"
case "$SM_GEO_SOURCE" in
  native|ip2location|dbip|maxmind) ;;
  *)
    echo "Fehler: unbekanntes SM_GEO_SOURCE='${SM_GEO_SOURCE}'." >&2
    echo "        Gültig: native (Standard), ip2location, dbip, maxmind" >&2
    exit 1
    ;;
esac
GEO_SOURCE_SQL="$(pwd)/geo_sources/${SM_GEO_SOURCE}.sql"
GEO="${SM_GEO_PATH:-$(pwd)/geo/country-ipv4-num.csv}"
GEO_LOC="${SM_GEO_LOC_PATH:-$(pwd)/geo/GeoLite2-Country-Locations-en.csv}"
if [ ! -f "$GEO" ]; then
  echo "Fehler: Geo-Datensatz fehlt unter '${GEO}'." >&2
  echo "        TODO: Datei selbst beschaffen und ablegen (siehe" >&2
  echo "        docs/ingestion-runbook.md -> Abschnitt 'GeoIP-Datensatz')." >&2
  exit 1
fi
if [ "$SM_GEO_SOURCE" = "maxmind" ] && [ ! -f "$GEO_LOC" ]; then
  echo "Fehler: MaxMind-Locations-Datei fehlt unter '${GEO_LOC}'." >&2
  echo "        TODO: GeoLite2-Country-Locations-en.csv ablegen (siehe" >&2
  echo "        docs/ingestion-runbook.md -> Abschnitt 'GeoIP-Datensatz')." >&2
  exit 1
fi
echo ">> Geo-Quelle: ${SM_GEO_SOURCE} (${GEO})"

# ---- Secrets ---------------------------------------------------------------
if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt. Setze CUBE_DSN oder lege die Secret-Datei unter CUBE_DSN_FILE ab.}"

# ---- Tabellennamen ---------------------------------------------------------
SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
SM_TABLE_META="${SM_TABLE_META:-meta}"
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META

# ---- Log-Format ------------------------------------------------------------
# SM_LOG_FORMAT: combined (Standard), combined_vhost, common, custom
#   custom: SM_LOG_REGEX_CUSTOM (Regex, 8 Capture-Groups) + SM_TS_FORMAT_CUSTOM (strptime)
SM_LOG_FORMAT="${SM_LOG_FORMAT:-combined}"
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
  *)
    echo "Fehler: unbekanntes SM_LOG_FORMAT='${SM_LOG_FORMAT}'." >&2
    echo "        Gültig: combined (Standard), combined_vhost, common, custom" >&2
    exit 1
    ;;
esac
echo ">> Log-Format: ${SM_LOG_FORMAT}"

# ---- Offset-Tracking -------------------------------------------------------
STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"

# ---- Per-Site-Lock: kein paralleler Doppelimport derselben Site -----------
# Schützt die Offset-/Meta-Konsistenz, falls sich zwei Läufe für dieselbe Site
# überschneiden (z. B. manuell + geplanter Lauf).
SITE_LOCK="${STATE_DIR}/site_${SITEID}.lock"
exec 9>"$SITE_LOCK"
if ! flock -n 9; then
  echo ">> Site ${SITEID} wird bereits importiert (Lock ${SITE_LOCK}). Übersprungen."
  exit 0
fi

# State-Key: md5(site_id:absoluter_log-Pfad) → kollisionsfreier Dateiname
STATE_KEY=$(printf '%s:%s' "$SITEID" "$(realpath "$LOGFILE")" | md5sum | cut -c1-16)
STATE_FILE="${STATE_DIR}/${STATE_KEY}.offset"

OFFSET=0
FILE_SIZE=$(wc -c < "$LOGFILE")
CURRENT_INODE=$(stat -c %i "$LOGFILE")

if [ -f "$STATE_FILE" ]; then
  STORED_OFFSET=$(cut -d: -f1 "$STATE_FILE")
  STORED_INODE=$(cut -d: -f2  "$STATE_FILE")
  if [ "$STORED_INODE" = "$CURRENT_INODE" ] && [ "$STORED_OFFSET" -le "$FILE_SIZE" ]; then
    OFFSET="$STORED_OFFSET"
    echo ">> Offset-Tracking: ab Byte ${OFFSET}/${FILE_SIZE} (Site ${SITEID})"
  else
    echo ">> Offset-Tracking: Log-Rotation erkannt (Inode/Größe geändert) → Vollimport (Site ${SITEID})"
  fi
else
  echo ">> Offset-Tracking: kein State gefunden → Vollimport (Site ${SITEID})"
fi

# Neue Zeilen in Temp-Datei schreiben (tail -c +N ist 1-basiert)
TMPLOG=$(mktemp /tmp/sm_inc_XXXXXX.log)
SQL_TMP=$(mktemp /tmp/sm_sql_XXXXXX.sql)
trap 'rm -f "$TMPLOG" "$SQL_TMP"' EXIT
cat "$(pwd)/cube_to_mysql.sql" "$(pwd)/sink_mysql.sql" \
  | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}' > "$SQL_TMP"
tail -c "+$((OFFSET + 1))" "$LOGFILE" > "$TMPLOG"
NEW_BYTES=$(wc -c < "$TMPLOG")

if [ "$NEW_BYTES" -eq 0 ]; then
  echo ">> Keine neuen Daten seit letztem Lauf (Site ${SITEID}). Fertig."
  exit 0
fi
echo ">> Verarbeite $((NEW_BYTES / 1024 + 1)) KB neue Daten (~$(wc -l < "$TMPLOG") Zeilen)"

# ---- Import ----------------------------------------------------------------
echo ">> SightMetrics-Ingestion -> MariaDB (Cube-DB): ${LOGFILE}"
t0=$(date +%s.%N)
/usr/bin/time -v -o /tmp/weg3_my.time "$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '${DSN}' AS m (TYPE mysql);
SET VARIABLE logpath   = '${TMPLOG}';
SET VARIABLE geopath   = '${GEO}';
SET VARIABLE geolocpath = '${GEO_LOC}';
SET VARIABLE site_name = '${SITENAME}';
SET VARIABLE site_id   = '${SITEID}';
SET VARIABLE tagessalt = '$(date +%Y%m%d)-sightmetrics';
SET VARIABLE logregex  = '${SM_LOG_REGEX}';
SET VARIABLE tsformat  = '${SM_TS_FORMAT}';
.read '${GEO_SOURCE_SQL}'
.read '${SQL_TMP}'
SQL
t1=$(date +%s.%N)
WALL=$(awk "BEGIN{printf \"%.2f\", $t1-$t0}")
CPU=$(awk -F': ' '/User time/{u=$2}/System time/{s=$2} END{printf "%.2f", u+s}' /tmp/weg3_my.time)
echo ">> Ingestion -> MariaDB fertig. Wall=${WALL}s CPU=${CPU}s"
printf '%s %s\n' "$WALL" "$CPU" > /tmp/weg3_my_metrics.txt

# ---- Offset aktualisieren (nur nach erfolgreichem Import) ------------------
echo "${FILE_SIZE}:${CURRENT_INODE}" > "$STATE_FILE"
echo ">> Offset gespeichert: ${FILE_SIZE} Byte (Inode ${CURRENT_INODE}, Site ${SITEID})"

# ---- Metriken schreiben (für Monitoring / Alerting) -----------------------
# site_N.last: letzter Lauf (Overwrite) – Status/Zeitstempel des letzten Imports.
# metrics.log: kumulatives Append aller Läufe.
METRICS_LAST="${STATE_DIR}/site_${SITEID}.last"
METRICS_LOG="${STATE_DIR}/metrics.log"
TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'ts=%s site_id=%s status=ok wall_s=%s cpu_s=%s new_bytes=%s offset=%s logfile=%s\n' \
  "$TS_NOW" "$SITEID" "$WALL" "$CPU" "$NEW_BYTES" "$FILE_SIZE" "$LOGFILE" \
  | tee "$METRICS_LAST" >> "$METRICS_LOG"
