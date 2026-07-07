#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – alternative log path: lines from Grafana Loki instead of a
# log file. Fetches the lines new since the last run via a LogQL range query
# and processes them without an intermediate file: lines stay in process
# memory and are streamed directly into DuckDB via process substitution.
# Parsing, sessionization and aggregation use the same logic as the
# file-based import (transform.sql); the source is an HTTP API instead of a
# file with a byte offset.
#
# Requirement: Loki log lines contain the complete raw line
# (Apache/nginx combined or similar), e.g. because Promtail scrapes access.log 1:1.
# For structured/JSON Loki lines, use a LogQL pipeline (| line_format) beforehand
# to turn them into a line in an SM_LOG_FORMAT-compatible format.
#
# Usage:
#   ./fetch_loki_logs.sh --url http://loki:3100 \
#                        --query '{job="nginx",site="behoerde-a"}' \
#                        --site-id 1 --site-name "Behörde A"
#
# Incremental via timestamp (not byte offset/inode as with files):
#   State is in STATE_DIR/<hash>.loki_ts (last processed Loki
#   timestamp in nanoseconds). First run: see --lookback-hours.
#
# Options (or ENV vars of the same name with a LOKI_ prefix, e.g. LOKI_URL):
#   --url              Loki base URL, e.g. http://loki:3100          (required)
#   --query            LogQL stream selector                         (required)
#   --site-id / --site-name   as in load_cube.sh                     (required)
#   --namespace        convenience filter: mixed into --query as an
#                       additional label matcher "namespace=..."
#                       (e.g. Kubernetes/Promtail namespace), optional
#   --org-id           X-Scope-OrgID header (Loki multi-tenant), optional
#   --limit            batch size per Loki query (default: 5000)
#   --lookback-hours   only on the very first run: how far back (default: 24)
#   --safety-seconds   safety margin to "now" against late-arriving,
#                       retroactively pushed lines (default: 30)
#
# Takes over the same ENV vars as load_cube.sh: CUBE_DSN/CUBE_DSN_FILE,
#   SM_TABLE_*, SM_LOG_FORMAT/SM_LOG_REGEX_CUSTOM/SM_TS_FORMAT_CUSTOM,
#   SM_GEO_*, STATE_DIR. Uses the same per-site lock as load_cube.sh
#   (state/site_<id>.lock) – file-based and Loki import of the same site never
#   run in parallel.
#
# Heartbeat (healthchecks.io or similar, optional, see lib_healthcheck.sh):
#   HEALTHCHECK_URL / HEALTHCHECK_URL_FILE   ping on start/success/failure,
#     so that a MISSING run is also noticed (not just active errors).
#
# Requires: curl, jq (on the host/container running this script).
# The fetched lines are held in process memory, not streamed from the
# Loki response – plan RAM accordingly for very large batches (--limit x
# many pages).
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
DUCKDB="$(pwd)/bin/duckdb"

# ---- Parameters ---------------------------------------------------------------
LOKI_URL="${LOKI_URL:-}"; LOKI_QUERY="${LOKI_QUERY:-}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-}"
LOKI_ORG_ID="${LOKI_ORG_ID:-}"
LOKI_LIMIT="${LOKI_LIMIT:-5000}"
LOKI_LOOKBACK_HOURS="${LOKI_LOOKBACK_HOURS:-24}"
LOKI_SAFETY_SECONDS="${LOKI_SAFETY_SECONDS:-30}"
SITE_ID=""; SITE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)             LOKI_URL="$2"; shift 2 ;;
    --query)           LOKI_QUERY="$2"; shift 2 ;;
    --namespace)       LOKI_NAMESPACE="$2"; shift 2 ;;
    --org-id)          LOKI_ORG_ID="$2"; shift 2 ;;
    --limit)           LOKI_LIMIT="$2"; shift 2 ;;
    --lookback-hours)  LOKI_LOOKBACK_HOURS="$2"; shift 2 ;;
    --safety-seconds)  LOKI_SAFETY_SECONDS="$2"; shift 2 ;;
    --site-id)         SITE_ID="$2"; shift 2 ;;
    --site-name)       SITE_NAME="$2"; shift 2 ;;
    -h|--help)         sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
  esac
done
: "${LOKI_URL:?--url/LOKI_URL fehlt}"; : "${LOKI_QUERY:?--query/LOKI_QUERY fehlt}"
: "${SITE_ID:?--site-id fehlt}"; : "${SITE_NAME:?--site-name fehlt}"

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

# ---- Healthcheck heartbeat (healthchecks.io or similar, optional) ---------
# Trap covers all exit paths, including early errors like a missing CUBE_DSN
# or a missing geo file, and reads the exit code on termination.
source "$(pwd)/lib_healthcheck.sh"
cleanup_and_ping() {
  local rc=$?
  [ -n "${SQL_TMP:-}" ] && rm -f "$SQL_TMP"
  [ -n "${LOGFD:-}" ] && exec {LOGFD}<&- 2>/dev/null
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

# ---- Secrets -------------------------------------------------------------
if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt. Setze CUBE_DSN oder lege die Secret-Datei unter CUBE_DSN_FILE ab.}"

# ---- Table names ----------------------------------------------------------------
SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
SM_TABLE_META="${SM_TABLE_META:-meta}"
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META

STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"

# ---- Per-site lock (shared with load_cube.sh) -------------------------------
SITE_LOCK="${STATE_DIR}/site_${SITE_ID}.lock"
exec 9>"$SITE_LOCK"
if ! flock -n 9; then
  echo ">> Site ${SITE_ID} wird bereits importiert (Lock ${SITE_LOCK}). Übersprungen."
  exit 0
fi

# ---- Timestamp state (instead of byte offset/inode) ------------------------
STATE_KEY=$(printf '%s:%s' "$SITE_ID" "$LOKI_QUERY" | md5sum | cut -c1-16)
TS_FILE="${STATE_DIR}/${STATE_KEY}.loki_ts"

NOW_NS=$(($(date +%s%N) - LOKI_SAFETY_SECONDS * 1000000000))
if [ -f "$TS_FILE" ]; then
  START_NS=$(( $(cat "$TS_FILE") + 1 ))
else
  START_NS=$(( NOW_NS - LOKI_LOOKBACK_HOURS * 3600 * 1000000000 ))
  echo ">> Kein State gefunden -> erster Lauf, Lookback ${LOKI_LOOKBACK_HOURS}h."
fi
END_NS="$NOW_NS"

if [ "$START_NS" -ge "$END_NS" ]; then
  echo ">> Nichts zu tun (Fenster leer, Sicherheitsabstand ${LOKI_SAFETY_SECONDS}s)."
  exit 0
fi

# ---- Fetch from Loki (paginated), collect lines in memory -----------------
CURL_HEADERS=()
[ -n "$LOKI_ORG_ID" ] && CURL_HEADERS+=(-H "X-Scope-OrgID: ${LOKI_ORG_ID}")

echo ">> Hole neue Zeilen aus Loki: ${LOKI_QUERY}"
LINES=""
cursor="$START_NS"
# Loki treats the range as [start, end) - start inclusive, end exclusive.
# Query with end=END_NS+1, so the interval [START_NS, END_NS] is covered
# inclusively (otherwise a line with a timestamp of exactly END_NS would be
# fetched neither in this nor in the next run).
QUERY_END_NS=$((END_NS + 1))
total=0
max_ts=0
page=0
max_pages=1000   # safety guard against infinite loop in degenerate cases
while [ "$page" -lt "$max_pages" ]; do
  page=$((page + 1))
  RESP=$(curl -fsS -G "${LOKI_URL%/}/loki/api/v1/query_range" \
    "${CURL_HEADERS[@]}" \
    --data-urlencode "query=${LOKI_QUERY}" \
    --data-urlencode "start=${cursor}" \
    --data-urlencode "end=${QUERY_END_NS}" \
    --data-urlencode "limit=${LOKI_LIMIT}" \
    --data-urlencode "direction=forward")

  count=$(echo "$RESP" | jq '[.data.result[].values[]] | length')
  [ "$count" -eq 0 ] && break

  LINES+="$(echo "$RESP" | jq -r '.data.result[].values[][1]')"$'\n'
  page_max_ts=$(echo "$RESP" | jq -r '[.data.result[].values[][0] | tonumber] | max')
  [ "$page_max_ts" -gt "$max_ts" ] && max_ts="$page_max_ts"
  total=$((total + count))

  if [ "$count" -lt "$LOKI_LIMIT" ]; then
    break
  fi
  cursor=$((page_max_ts + 1))
  [ "$cursor" -gt "$END_NS" ] && break
done
# State upper bound: normally END_NS (window fully drained). If the
# max_pages guard is hit, the window was not fully fetched -
# advance state only up to the last processed timestamp (max_ts) then,
# so the next run continues there instead of skipping the remaining lines.
STATE_NS="$END_NS"
if [ "$page" -ge "$max_pages" ]; then
  echo ">> Warnung: max_pages (${max_pages}) erreicht – Fenster nicht vollstaendig abgeholt." >&2
  echo "   Setze State nur bis zum letzten abgeholten Zeitstempel (${max_ts}), nicht bis Fensterende." >&2
  STATE_NS="$max_ts"
fi

if [ "$total" -eq 0 ]; then
  echo ">> Keine neuen Zeilen im Fenster."
  echo "$STATE_NS" > "$TS_FILE"
  exit 0
fi
echo ">> ${total} neue Zeile(n) geholt -> direkt an DuckDB gestreamt (keine Zwischendatei)."

# ---- Process directly: lines via anonymous pipe to DuckDB -----------------
# 'exec {fd}< <(...)' keeps the pipe open (unlike a plain assignment) for
# the rest of the script, so DuckDB can still open /dev/fd/<fd> afterwards.
exec {LOGFD}< <(printf '%s' "$LINES")

SQL_TMP=$(mktemp /tmp/sm_sql_XXXXXX.sql)
cat "$(pwd)/cube_to_mysql.sql" "$(pwd)/sink_mysql.sql" \
  | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}' > "$SQL_TMP"

# Double single quotes for DuckDB string literals (as in load_cube.sh).
sq() { printf '%s' "${1//\'/\'\'}"; }

t0=$(date +%s.%N)
"$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '$(sq "$DSN")' AS m (TYPE mysql);
SET VARIABLE logpath    = '/dev/fd/${LOGFD}';
SET VARIABLE geopath    = '$(sq "$GEO")';
SET VARIABLE geolocpath = '$(sq "$GEO_LOC")';
SET VARIABLE site_name  = '$(sq "$SITE_NAME")';
SET VARIABLE site_id    = '${SITE_ID}';
SET VARIABLE tagessalt  = '$(date +%Y%m%d)-sightmetrics';
SET VARIABLE logregex   = '$(sq "$SM_LOG_REGEX")';
SET VARIABLE tsformat   = '$(sq "$SM_TS_FORMAT")';
SET VARIABLE tz         = '$(sq "${SM_TZ:-UTC}")';
SET VARIABLE botfilter  = '${SM_BOT_FILTER:-1}';
SET VARIABLE download_re = '$(sq "${SM_DOWNLOAD_RE:-}")';
${BOT_SQL}
.read '${GEO_SOURCE_SQL}'
.read '${LOG_FORMAT_SQL}'
.read '${SQL_TMP}'
SQL
t1=$(date +%s.%N)
WALL=$(awk "BEGIN{printf \"%.2f\", $t1-$t0}")
echo ">> Loki -> MariaDB fertig. Wall=${WALL}s (${total} Zeilen, Site ${SITE_ID})"

# ---- Metrics (same convention as load_cube.sh) -------------------------------
METRICS_LAST="${STATE_DIR}/site_${SITE_ID}.last"
METRICS_LOG="${STATE_DIR}/metrics.log"
TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'ts=%s site_id=%s status=ok wall_s=%s new_lines=%s source=loki query=%s\n' \
  "$TS_NOW" "$SITE_ID" "$WALL" "$total" "$LOKI_QUERY" \
  | tee "$METRICS_LAST" >> "$METRICS_LOG"

# ---- Only advance state after a successful import ---------------------------
echo "$STATE_NS" > "$TS_FILE"
echo ">> Loki-State aktualisiert (bis ${STATE_NS} ns)."
