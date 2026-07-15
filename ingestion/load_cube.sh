#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics ingestion: log -> DuckDB cube -> MariaDB (incremental).
# Sole writer of the cube DB (section 11.1). Measures wall + CPU time.
#
# Usage:  ./load_cube.sh [LOGFILE] [SITE-NAME] [SITE-ID]
#
# Offset tracking: only processes new lines since the last run.
#   STATE_DIR         directory for .offset files  (default: ../state/)
#
# Secrets:
#   CUBE_DSN          DuckDB MySQL DSN  (host=... port=... user=... password=... database=...)
#   CUBE_DSN_FILE     path to a file containing the DSN  (Docker secrets pattern,
#                     default: /run/secrets/cube_dsn)
#
# Table names (default: cube / daily / meta / topn):
#   SM_TABLE_CUBE     name of the cube table
#   SM_TABLE_DAILY    name of the daily table
#   SM_TABLE_META     name of the meta table
#   SM_TABLE_TOPN     name of the top-N precompute table (docs/topn-precompute-spec.md)
#
# GeoIP (TODO for operators: file is NOT part of the repo, see
#        docs/ingestion-runbook.md -> section "GeoIP dataset"):
#   SM_GEO_SOURCE     native (default) | ip2location | dbip | maxmind
#                     determines which geo_sources/<source>.sql is loaded.
#   SM_GEO_PATH       path to the geo CSV (default: geo/country-ipv4-num.csv)
#   SM_GEO_LOC_PATH   only SM_GEO_SOURCE=maxmind: path to
#                     GeoLite2-Country-Locations-en.csv
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
# DuckDB-Binary: $DUCKDB-Override, sonst lokal gepinnt (Host/Tests: ./bin/duckdb),
# sonst aus PATH (Container: /usr/local/bin/duckdb).
if [ -z "${DUCKDB:-}" ]; then
  if [ -x bin/duckdb ]; then DUCKDB="$(pwd)/bin/duckdb"; else DUCKDB=duckdb; fi
fi
LOGFILE="${1:-${REPO}/logs/example_1k.log}"
SITENAME="${2:-Musterbehörde}"
SITEID="${3:-1}"

# ---- Offset tracking -------------------------------------------------------
STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"

# ---- Per-site lock: no parallel double import of the same site -----------
# Protects offset/meta consistency if two runs for the same site
# overlap (e.g. manual + scheduled run). Runs BEFORE geo/secrets/
# log-format validation, so a lock conflict aborts immediately and without
# using resources, instead of failing on missing prerequisites that
# aren't needed for this run anyway.
SITE_LOCK="${STATE_DIR}/site_${SITEID}.lock"
exec 9>"$SITE_LOCK"
if ! flock -n 9; then
  echo ">> Site ${SITEID} wird bereits importiert (Lock ${SITE_LOCK}). Übersprungen."
  exit 0
fi

# ---- Geo source -------------------------------------------------------------
source "$(pwd)/lib_geo.sh"

# ---- Secrets ---------------------------------------------------------------
if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt. Setze CUBE_DSN oder lege die Secret-Datei unter CUBE_DSN_FILE ab.}"

# ---- Table names ------------------------------------------------------------
SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
SM_TABLE_META="${SM_TABLE_META:-meta}"
SM_TABLE_TOPN="${SM_TABLE_TOPN:-topn}"
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META SM_TABLE_TOPN

# ---- Log format -------------------------------------------------------------
source "$(pwd)/lib_logformat.sh"

# ---- Bot list (device-detector, optional; otherwise built-in heuristic) ----
source "$(pwd)/lib_bots.sh"

# ---- Browser/OS lists (device-detector, optional) ---------------------------
source "$(pwd)/lib_ua.sh"

# State key: md5(site_id:absolute_log_path) → collision-free filename
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

# Write new lines to a temp file (tail -c +N is 1-based)
TMPLOG=$(mktemp /tmp/sm_inc_XXXXXX.log)
SQL_TMP=$(mktemp /tmp/sm_sql_XXXXXX.sql)
TIME_TMP=$(mktemp /tmp/sm_time_XXXXXX.txt)      # separate file per run: PARALLEL-safe
CONSUMED_TMP=$(mktemp /tmp/sm_consumed_XXXXXX.csv)
trap 'rm -f "$TMPLOG" "$SQL_TMP" "$TIME_TMP" "$CONSUMED_TMP"' EXIT
cat "$(pwd)/cube_to_mysql.sql" "$(pwd)/sink_mysql.sql" \
  | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META} ${SM_TABLE_TOPN}' > "$SQL_TMP"
tail -c "+$((OFFSET + 1))" "$LOGFILE" > "$TMPLOG"
NEW_BYTES=$(wc -c < "$TMPLOG")

if [ "$NEW_BYTES" -eq 0 ]; then
  echo ">> Keine neuen Daten seit letztem Lauf (Site ${SITEID}). Fertig."
  exit 0
fi
echo ">> Verarbeite $((NEW_BYTES / 1024 + 1)) KB neue Daten (~$(wc -l < "$TMPLOG") Zeilen)"

# ---- Day-boundary cut (see day_cut.sql / runbook §8) ------------------------
# Lines from the still-running day (UTC) are held back and only imported on
# the next run -- otherwise the sink's range DELETE on the following run
# would discard the hours of this day that were already imported earlier.
#   SM_COMPLETE_DAYS=0   disables the cut (e.g. for backfills/tests)
#   SM_CUTOFF_DATE       override the cutoff date (default: today, UTC)
CUTOFF_DATE=""
if [ "${SM_COMPLETE_DAYS:-1}" != "0" ]; then
  CUTOFF_DATE="${SM_CUTOFF_DATE:-$(TZ="${SM_TZ:-UTC}" date +%Y-%m-%d)}"
fi

# Double single quotes for DuckDB string literals -- an apostrophe in the
# site name/DSN/regex must not break the SQL.
sq() { printf '%s' "${1//\'/\'\'}"; }

# ---- Import -------------------------------------------------------------
echo ">> SightMetrics-Ingestion -> MariaDB (Cube-DB): ${LOGFILE}"
t0=$(date +%s.%N)
/usr/bin/time -v -o "$TIME_TMP" "$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '$(sq "$DSN")' AS m (TYPE mysql);
SET VARIABLE logpath   = '$(sq "$TMPLOG")';
SET VARIABLE geopath   = '$(sq "$GEO")';
SET VARIABLE geolocpath = '$(sq "$GEO_LOC")';
SET VARIABLE site_name = '$(sq "$SITENAME")';
SET VARIABLE site_id   = '${SITEID}';
SET VARIABLE tagessalt = '$(date +%Y%m%d)-sightmetrics';
SET VARIABLE logregex  = '$(sq "$SM_LOG_REGEX")';
SET VARIABLE tsformat  = '$(sq "$SM_TS_FORMAT")';
SET VARIABLE tz        = '$(sq "${SM_TZ:-UTC}")';
SET VARIABLE botfilter = '${SM_BOT_FILTER:-1}';
SET VARIABLE download_re = '$(sq "${SM_DOWNLOAD_RE:-}")';
SET VARIABLE cutoff_date = '${CUTOFF_DATE}';
${BOT_SQL}
.read '${GEO_SOURCE_SQL}'
.read '${LOG_FORMAT_SQL}'
.read 'day_cut.sql'
${GEO6_SQL}
${UA_SQL}
COPY (SELECT CASE WHEN getvariable('cut_rid') IS NULL THEN -1
             ELSE (SELECT COALESCE(SUM(nbytes), 0) FROM raw_lines
                   WHERE rid < getvariable('cut_rid')) END::BIGINT AS consumed)
TO '${CONSUMED_TMP}' (FORMAT csv, HEADER false);
.read '${SQL_TMP}'
SQL
t1=$(date +%s.%N)
WALL=$(awk "BEGIN{printf \"%.2f\", $t1-$t0}")
CPU=$(awk -F': ' '/User time/{u=$2}/System time/{s=$2} END{printf "%.2f", u+s}' "$TIME_TMP")
echo ">> Ingestion -> MariaDB fertig. Wall=${WALL}s CPU=${CPU}s"

# ---- Update offset (only after a successful import) ------------------------
# consumed = -1: no cut -> everything processed, offset = file size (byte-exact).
# Otherwise: advance offset only up to before the first held-back line.
CONSUMED=$(cat "$CONSUMED_TMP" 2>/dev/null || echo -1)
if [ "$CONSUMED" -ge 0 ] 2>/dev/null; then
  NEW_OFFSET=$((OFFSET + CONSUMED))
  [ "$NEW_OFFSET" -gt "$FILE_SIZE" ] && NEW_OFFSET="$FILE_SIZE"
  HELD=$((FILE_SIZE - NEW_OFFSET))
  echo ">> Tagesgrenzen-Cut: ${HELD} Byte (Zeilen ab ${CUTOFF_DATE}, UTC) zurueckgestellt bis der Tag abgeschlossen ist."
else
  NEW_OFFSET="$FILE_SIZE"
fi
echo "${NEW_OFFSET}:${CURRENT_INODE}" > "$STATE_FILE"
echo ">> Offset gespeichert: ${NEW_OFFSET}/${FILE_SIZE} Byte (Inode ${CURRENT_INODE}, Site ${SITEID})"

# ---- Write metrics (for monitoring / alerting) -----------------------------
# site_N.last: last run (overwrite) – status/timestamp of the last import.
# metrics.log: cumulative append of all runs.
METRICS_LAST="${STATE_DIR}/site_${SITEID}.last"
METRICS_LOG="${STATE_DIR}/metrics.log"
TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'ts=%s site_id=%s status=ok wall_s=%s cpu_s=%s new_bytes=%s offset=%s logfile=%s\n' \
  "$TS_NOW" "$SITEID" "$WALL" "$CPU" "$NEW_BYTES" "$NEW_OFFSET" "$LOGFILE" \
  | tee "$METRICS_LAST" >> "$METRICS_LOG"

# Prometheus textfile collector (node_exporter) -- see lib_prom.sh / runbook.
source "$(pwd)/lib_prom.sh"
prom_site_metrics "$SITEID" "$WALL" "$CPU" "$NEW_BYTES" "$NEW_OFFSET" "file"
