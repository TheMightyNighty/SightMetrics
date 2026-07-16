#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – alternative log path: lines from Grafana Loki instead of a
# log file. Processes DAY BY DAY (one local calendar day per pass): per day
# the window 00:00:00 -> 23:59:59 (next local midnight, exclusive) is fetched
# into a temp file, aggregated by DuckDB and written to MariaDB before the
# next day starts. This keeps memory bounded with 1-2 GB of logs per day
# (file on disk instead of everything in RAM), and each day yields exactly
# one daily row (sessionization/uniques need the full day at once).
#
# Only COMPLETE past days are processed (up to yesterday, local time); the
# running day is incomplete and skipped. Intended schedule: one run per day
# (e.g. shortly after midnight) imports yesterday. The last complete day
# (yesterday) is ALWAYS (re)imported and REPLACED in MariaDB, even if the
# state says it is already done – so the script may also run again during
# the day and simply refreshes yesterday's data (the sink range-DELETEs
# exactly the imported day before inserting, see sink_mysql.sql).
#
# Requirement: Loki log lines contain the complete raw line
# (Apache/nginx combined or similar OR JSON/ECS). SM_LOG_FORMAT selects the
# parser (combined [default] | combined_vhost | common | custom | json_ecs).
#
# Usage:
#   SM_LOG_FORMAT=json_ecs ./fetch_loki_logs.sh \
#       --url http://loki:3100 --query '{job="nginx"}' \
#       --site-id 1 --site-name "Behörde A" \
#       --lookback-days 7 --timezone Europe/Berlin
#
# Incremental via the last imported day:
#   State is in STATE_DIR/<hash>.loki_day (last imported local date
#   YYYY-MM-DD). Days before yesterday that are covered by the state are
#   skipped; yesterday itself is always re-imported (see above).
#   First run: see --lookback-days.
#
# Options (or ENV vars, see parentheses):
#   --url              Loki base URL, e.g. http://loki:3100  (LOKI_URL, required)
#   --query            LogQL stream selector                 (LOKI_QUERY, required)
#   --site-id / --site-name   as in load_cube.sh             (required)
#   --lookback-days    first run: how many FULL days back, ending at the last
#                       complete day (yesterday). Example: on Jul 2nd 03:00,
#                       --lookback-days 1 imports Jul 1st 00:00->23:59.
#                       (LOKI_LOOKBACK_DAYS, default 1)
#   --timezone/--tz    timezone for day boundaries + datum/stunde, DST-aware
#                       (23-/25-hour days); an unknown zone is rejected instead
#                       of silently treated as UTC. (SM_TZ, default Europe/Berlin)
#   --margin-seconds   safety margin around the Loki query window. Loki filters
#                       by INGESTION time, which lags the timestamp inside the
#                       line by a few seconds (nginx/promtail buffering) - so
#                       each day is fetched with +/- margin and day_filter.sql
#                       then buckets strictly by the LINE's timestamp; anything
#                       outside the day is discarded. Schedule the daily run at
#                       least margin seconds after midnight, so the stragglers
#                       have arrived. (LOKI_MARGIN_SECONDS, default 60)
#   --namespace        convenience filter: additional label matcher
#                       "namespace=..." mixed into --query (LOKI_NAMESPACE), optional
#   --org-id           X-Scope-OrgID header (Loki multi-tenant), optional
#   --limit            batch size per Loki query (LOKI_LIMIT, default 5000)
#
# Additional ENV:
#   SM_TMPDIR             directory for the per-day temp files + DuckDB spill
#                         (default /tmp; a discardable volume in the demo container).
#   DUCKDB_MEMORY_LIMIT   DuckDB memory limit (default 2GB); beyond it DuckDB
#                         spills to SM_TMPDIR/duckdb instead of OOMing.
#   As load_cube.sh: CUBE_DSN/CUBE_DSN_FILE, SM_TABLE_*, SM_LOG_FORMAT/
#     SM_LOG_REGEX_CUSTOM/SM_TS_FORMAT_CUSTOM, SM_GEO_*, SM_BOT_*, STATE_DIR.
#
# Heartbeat (healthchecks.io or similar, optional, see lib_healthcheck.sh):
#   HEALTHCHECK_URL / HEALTHCHECK_URL_FILE
#
# Requires: curl, jq, GNU date, md5sum, duckdb – all part of the ingestion image.
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

# ---- Parameters ---------------------------------------------------------------
LOKI_URL="${LOKI_URL:-}"; LOKI_QUERY="${LOKI_QUERY:-}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-}"
LOKI_ORG_ID="${LOKI_ORG_ID:-}"
LOKI_LIMIT="${LOKI_LIMIT:-5000}"
LOKI_LOOKBACK_DAYS="${LOKI_LOOKBACK_DAYS:-1}"
LOKI_MARGIN_SECONDS="${LOKI_MARGIN_SECONDS:-60}"
SM_TZ="${SM_TZ:-Europe/Berlin}"
SM_TMPDIR="${SM_TMPDIR:-/tmp}"
DUCKDB_MEMORY_LIMIT="${DUCKDB_MEMORY_LIMIT:-2GB}"
SITE_ID=""; SITE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)             LOKI_URL="$2"; shift 2 ;;
    --query)           LOKI_QUERY="$2"; shift 2 ;;
    --namespace)       LOKI_NAMESPACE="$2"; shift 2 ;;
    --org-id)          LOKI_ORG_ID="$2"; shift 2 ;;
    --limit)           LOKI_LIMIT="$2"; shift 2 ;;
    --lookback-days)   LOKI_LOOKBACK_DAYS="$2"; shift 2 ;;
    --margin-seconds)  LOKI_MARGIN_SECONDS="$2"; shift 2 ;;
    --timezone|--tz)   SM_TZ="$2"; shift 2 ;;
    --site-id)         SITE_ID="$2"; shift 2 ;;
    --site-name)       SITE_NAME="$2"; shift 2 ;;
    -h|--help)         sed -n '2,71p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
  esac
done
: "${LOKI_URL:?--url/LOKI_URL fehlt}"; : "${LOKI_QUERY:?--query/LOKI_QUERY fehlt}"
: "${SITE_ID:?--site-id fehlt}"; : "${SITE_NAME:?--site-name fehlt}"
case "$LOKI_LOOKBACK_DAYS" in ''|*[!0-9]*) echo "Fehler: --lookback-days muss eine positive Ganzzahl sein." >&2; exit 1 ;; esac
[ "$LOKI_LOOKBACK_DAYS" -ge 1 ] || { echo "Fehler: --lookback-days muss >= 1 sein." >&2; exit 1; }
case "$LOKI_MARGIN_SECONDS" in ''|*[!0-9]*) echo "Fehler: --margin-seconds muss eine Ganzzahl >= 0 sein." >&2; exit 1 ;; esac

# ---- Namespace filter (Kubernetes/Promtail label "namespace") -------------
# Convenience option in addition to --query: mixed in as an additional
# label matcher in the stream selector, e.g.
#   --query '{job="nginx"}' --namespace behoerde-a  ->  {namespace="behoerde-a",job="nginx"}
# For more complex cases (no namespace label, multiple selectors, etc.)
# write the namespace directly into --query/LOKI_QUERY instead.
if [ -n "$LOKI_NAMESPACE" ]; then
  case "$LOKI_QUERY" in
    \{*) LOKI_QUERY="{namespace=\"${LOKI_NAMESPACE}\",${LOKI_QUERY#\{}" ;;
    *)   echo "Fehler: --namespace erfordert einen Stream-Selector in { } als --query." >&2; exit 1 ;;
  esac
fi

command -v curl >/dev/null || { echo "Fehler: curl nicht gefunden." >&2; exit 1; }
command -v jq   >/dev/null || { echo "Fehler: jq nicht gefunden." >&2; exit 1; }

# ---- GNU date + timezone check ----------------------------------------------
# Day arithmetic needs GNU 'date -d' (part of the ingestion image; BSD/macOS
# date would fail with confusing errors otherwise).
date -d "2026-01-01 +1 day" +%F >/dev/null 2>&1 \
  || { echo "Fehler: GNU date (date -d) benötigt – im Ingestion-Container vorhanden." >&2; exit 1; }
# GNU date silently accepts an unknown TZ as UTC -> check explicitly against
# the zoneinfo DB so a typo does not silently produce UTC days.
if [ "$SM_TZ" != "UTC" ] && [ ! -e "/usr/share/zoneinfo/$SM_TZ" ]; then
  echo "Fehler: Zeitzone '$SM_TZ' nicht gefunden (siehe /usr/share/zoneinfo)." >&2
  exit 1
fi

# ---- Healthcheck heartbeat (healthchecks.io or similar, optional) ---------
# Trap covers all exit paths, including early errors like a missing CUBE_DSN
# or a missing geo file, and reads the exit code on termination.
source "$(pwd)/lib_healthcheck.sh"
cleanup_and_ping() {
  local rc=$?
  [ -n "${SQL_TMP:-}" ] && rm -f "$SQL_TMP"
  [ -n "${LOG_FILE:-}" ] && rm -f "$LOG_FILE"
  if [ "$rc" -eq 0 ]; then
    hc_ping ""
  else
    hc_ping "/fail" "fetch_loki_logs.sh fehlgeschlagen (exit ${rc}), Site ${SITE_ID:-?}, Query ${LOKI_QUERY:-?}"
  fi
}
trap cleanup_and_ping EXIT
hc_ping "/start"

# ---- Geo source + log format (shared with load_cube.sh) --------------------
source "$(pwd)/lib_geo.sh"
source "$(pwd)/lib_logformat.sh"
source "$(pwd)/lib_bots.sh"
source "$(pwd)/lib_ua.sh"

# ---- Secrets -------------------------------------------------------------
if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt. Setze CUBE_DSN oder lege die Secret-Datei unter CUBE_DSN_FILE ab.}"

# ---- Table names ----------------------------------------------------------------
SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
SM_TABLE_META="${SM_TABLE_META:-meta}"
SM_TABLE_TOPN="${SM_TABLE_TOPN:-topn}"
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META SM_TABLE_TOPN

STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"
mkdir -p "$SM_TMPDIR" "${SM_TMPDIR}/duckdb"

# ---- Per-site lock (shared with load_cube.sh) -------------------------------
SITE_LOCK="${STATE_DIR}/site_${SITE_ID}.lock"
exec 9>"$SITE_LOCK"
if ! flock -n 9; then
  echo ">> Site ${SITE_ID} wird bereits importiert (Lock ${SITE_LOCK}). Übersprungen."
  exit 0
fi

# ---- Determine day range (local calendar days in SM_TZ) ---------------------
# Only complete past days: up to and including yesterday (local time).
TODAY=$(TZ="$SM_TZ" date +%F)
LAST_COMPLETE=$(TZ="$SM_TZ" date -d "$TODAY -1 day" +%F)

STATE_KEY=$(printf '%s:%s' "$SITE_ID" "$LOKI_QUERY" | md5sum | cut -c1-16)
DAY_FILE="${STATE_DIR}/${STATE_KEY}.loki_day"
# State of the former timestamp-based (ns) implementation; superseded by the
# day state -> remove so no stale file lingers in STATE_DIR.
rm -f "${STATE_DIR}/${STATE_KEY}.loki_ts"

if [ -f "$DAY_FILE" ] && [ -s "$DAY_FILE" ]; then
  LAST_DONE=$(cat "$DAY_FILE")
  START_DAY=$(TZ="$SM_TZ" date -d "$LAST_DONE +1 day" +%F)
  # Yesterday is always re-imported (and replaced in MariaDB) even if the
  # state already covers it -> an intraday re-run refreshes the last
  # complete day instead of being a no-op.
  # (String comparison on YYYY-MM-DD is lexicographic == chronological.)
  if [[ "$START_DAY" > "$LAST_COMPLETE" ]]; then
    START_DAY="$LAST_COMPLETE"
    echo ">> State: ${LAST_DONE} bereits importiert -> Vortag ${START_DAY} wird erneut importiert und überschrieben (TZ ${SM_TZ})."
  else
    echo ">> State: zuletzt verarbeitet ${LAST_DONE} -> starte bei ${START_DAY} (TZ ${SM_TZ})."
  fi
else
  START_DAY=$(TZ="$SM_TZ" date -d "$LAST_COMPLETE -$((LOKI_LOOKBACK_DAYS - 1)) day" +%F)
  echo ">> Kein State -> Lookback ${LOKI_LOOKBACK_DAYS} Tag(e), starte bei ${START_DAY} (TZ ${SM_TZ})."
fi

# ---- Prepare sink SQL once (substitute table names) --------------------------
SQL_TMP=$(mktemp "${SM_TMPDIR}/sm_sql_XXXXXX.sql")
cat "$(pwd)/cube_to_mysql.sql" "$(pwd)/sink_mysql.sql" \
  | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META} ${SM_TABLE_TOPN}' > "$SQL_TMP"

CURL_HEADERS=()
[ -n "$LOKI_ORG_ID" ] && CURL_HEADERS+=(-H "X-Scope-OrgID: ${LOKI_ORG_ID}")

METRICS_LAST="${STATE_DIR}/site_${SITE_ID}.last"
METRICS_LOG="${STATE_DIR}/metrics.log"

# Double single quotes for DuckDB string literals (as in load_cube.sh).
sq() { printf '%s' "${1//\'/\'\'}"; }

# ---- Process day by day ------------------------------------------------------
D="$START_DAY"
days_done=0
lines_total=0
WALL=0
while [[ ! "$D" > "$LAST_COMPLETE" ]]; do
  D_NEXT=$(TZ="$SM_TZ" date -d "$D +1 day" +%F)
  # Local midnight -> Unix epoch (DST-safe: 00:00 never falls into the
  # spring-forward gap; two midnights are 23/24/25 hours apart).
  START_NS=$(( $(TZ="$SM_TZ" date -d "$D 00:00:00" +%s) * 1000000000 ))
  END_NS=$((   $(TZ="$SM_TZ" date -d "$D_NEXT 00:00:00" +%s) * 1000000000 ))
  DAY_HOURS=$(( (END_NS - START_NS) / 3600000000000 ))
  # Loki filters by INGESTION time, which lags the timestamp inside the line
  # (nginx/promtail buffering): stragglers of day D arrive shortly after
  # midnight, and lines ingested right at 00:00 may still carry 23:59:59 of
  # D-1. Fetch with +/- margin; day_filter.sql below then buckets strictly by
  # the line's own timestamp, so each line lands in exactly one day even
  # though consecutive fetch windows overlap.
  FETCH_START_NS=$(( START_NS - LOKI_MARGIN_SECONDS * 1000000000 ))
  FETCH_END_NS=$((   END_NS   + LOKI_MARGIN_SECONDS * 1000000000 ))
  LOG_FILE="${SM_TMPDIR}/sm_loki_${SITE_ID}_${D}.jsonl"
  : > "$LOG_FILE"

  echo ">> Tag ${D} (${DAY_HOURS}h): hole aus Loki [${D} 00:00 .. ${D_NEXT} 00:00) ±${LOKI_MARGIN_SECONDS}s ${SM_TZ} ..."

  # Loki paginates; the range is [start, end) - start inclusive, end exclusive.
  # Stream the lines straight into the temp file (NOT into shell memory)
  # -> RAM stays constant regardless of the day's size.
  cursor="$FETCH_START_NS"; total=0; page=0; max_ts=0
  max_pages=200000    # guard: 200k pages x limit covers very large days
  while [ "$page" -lt "$max_pages" ]; do
    page=$((page + 1))
    RESP=$(curl -fsS -G "${LOKI_URL%/}/loki/api/v1/query_range" \
      "${CURL_HEADERS[@]}" \
      --data-urlencode "query=${LOKI_QUERY}" \
      --data-urlencode "start=${cursor}" \
      --data-urlencode "end=${FETCH_END_NS}" \
      --data-urlencode "limit=${LOKI_LIMIT}" \
      --data-urlencode "direction=forward")

    count=$(echo "$RESP" | jq '[.data.result[].values[]] | length')
    [ "$count" -eq 0 ] && break
    echo "$RESP" | jq -r '.data.result[].values[] | .[1]' >> "$LOG_FILE"
    page_max_ts=$(echo "$RESP" | jq -r '[.data.result[].values[][0] | tonumber] | max')
    [ "$page_max_ts" -gt "$max_ts" ] && max_ts="$page_max_ts"
    total=$((total + count))
    [ "$count" -lt "$LOKI_LIMIT" ] && break
    cursor=$((page_max_ts + 1))
    [ "$cursor" -ge "$FETCH_END_NS" ] && break
  done
  if [ "$page" -ge "$max_pages" ]; then
    echo "Fehler: max_pages (${max_pages}) an Tag ${D} erreicht – Tag nicht vollständig geholt, Abbruch." >&2
    exit 1
  fi
  echo ">> Tag ${D}: ${total} Zeile(n) geholt ($(du -h "$LOG_FILE" 2>/dev/null | cut -f1))."

  # One DuckDB run per day: aggregate + write to MariaDB. range_from/range_to=D
  # make the sink replace EXACTLY this day (empty days are cleared, too).
  # tagessalt derives from the imported day (not "today"), so a re-import of
  # the same day produces identical visitor keys (stable uniques). memory_limit
  # + spill to SM_TMPDIR/duckdb -> no OOM on 1-2 GB day chunks.
  TS_TAG="${D//-/}"
  t0=$(date +%s.%N)
  "$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
SET memory_limit='${DUCKDB_MEMORY_LIMIT}';
SET temp_directory='${SM_TMPDIR}/duckdb';
SET preserve_insertion_order=false;
ATTACH '$(sq "$DSN")' AS m (TYPE mysql);
SET VARIABLE logpath    = '$(sq "$LOG_FILE")';
SET VARIABLE geopath    = '$(sq "$GEO")';
SET VARIABLE geolocpath = '$(sq "$GEO_LOC")';
SET VARIABLE site_name  = '$(sq "$SITE_NAME")';
SET VARIABLE site_id    = '${SITE_ID}';
SET VARIABLE tagessalt  = '${TS_TAG}-sightmetrics';
SET VARIABLE logregex   = '$(sq "$SM_LOG_REGEX")';
SET VARIABLE tsformat   = '$(sq "$SM_TS_FORMAT")';
SET VARIABLE tz         = '$(sq "$SM_TZ")';
SET VARIABLE botfilter  = '${SM_BOT_FILTER:-1}';
SET VARIABLE download_re = '$(sq "${SM_DOWNLOAD_RE:-}")';
SET VARIABLE range_from = '${D}';
SET VARIABLE range_to   = '${D}';
${BOT_SQL}
.read '${GEO_SOURCE_SQL}'
.read '${LOG_FORMAT_SQL}'
.read 'day_filter.sql'
${GEO6_SQL}
${UA_SQL}
.read '${SQL_TMP}'
SQL
  t1=$(date +%s.%N)
  WALL=$(awk "BEGIN{printf \"%.2f\", $t1-$t0}")
  echo ">> Tag ${D} -> MariaDB fertig. Wall=${WALL}s (${total} Zeilen, Site ${SITE_ID})"

  # Metrics (same convention as load_cube.sh)
  TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'ts=%s site_id=%s status=ok wall_s=%s new_lines=%s source=loki day=%s tz=%s query=%s\n' \
    "$TS_NOW" "$SITE_ID" "$WALL" "$total" "$D" "$SM_TZ" "$LOKI_QUERY" \
    | tee "$METRICS_LAST" >> "$METRICS_LOG"

  # Advance state only AFTER the day succeeded; drop the temp file right away.
  echo "$D" > "$DAY_FILE"
  rm -f "$LOG_FILE"; LOG_FILE=""
  days_done=$((days_done + 1))
  lines_total=$((lines_total + total))
  D="$D_NEXT"
done

# Prometheus textfile collector (node_exporter) -- see lib_prom.sh / runbook.
source "$(pwd)/lib_prom.sh"
prom_site_metrics "$SITE_ID" "$WALL" "" "" "" "loki"

rm -f "$SQL_TMP"; SQL_TMP=""
echo ">> Fertig: ${days_done} Tag(e), ${lines_total} Zeile(n) verarbeitet, State bis $(cat "$DAY_FILE") (TZ ${SM_TZ})."
