#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Matomo historical-data import (one-off, per customer site).
#
# Pulls historical reports from Matomo's Reporting API (JSON) and writes them
# into the same cube/daily/meta DB as the daily log import. Runs
# independently alongside load_cube.sh – the daily log import remains the
# continuous writer, this import only backfills the past.
#
# Aggregate-based: also scales for sites with millions of hits/day, since the
# API already returns numbers aggregated per day/dimension (no raw rows).
#
# Usage:
#   ./matomo_import.sh --url https://matomo.example.org \
#                      --matomo-idsite 7 \
#                      --site-id 3 --site-name "Musterbehörde" \
#                      --from 2020-01-01 --to 2024-12-31
#
# Token:
#   MATOMO_TOKEN        Reporting API token_auth (only view rights needed), OR
#   MATOMO_TOKEN_FILE   path to a file with the token (default:
#                       /run/secrets/matomo_token). Sent via POST.
#
# Cube DB (as in load_cube.sh):
#   CUBE_DSN            DuckDB MySQL DSN, OR
#   CUBE_DSN_FILE       path to the DSN file (default: /run/secrets/cube_dsn)
#   SM_TABLE_CUBE/DAILY/META   table names (default: cube/daily/meta)
#
# Tuning:
#   FILTER_LIMIT_HIGH   top-N/day for high-cardinality dims (url/keyword),
#                       default 1000. Low-cardinality dims always in full.
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
# DuckDB-Binary: $DUCKDB-Override, sonst lokal gepinnt (Host/Tests: ./bin/duckdb),
# sonst aus PATH (Container: /usr/local/bin/duckdb).
if [ -z "${DUCKDB:-}" ]; then
  if [ -x bin/duckdb ]; then DUCKDB="$(pwd)/bin/duckdb"; else DUCKDB=duckdb; fi
fi

# ---- Parameters -------------------------------------------------------------
MATOMO_URL=""; MATOMO_IDSITE=""; SITE_ID=""; SITE_NAME=""; DATE_FROM=""; DATE_TO=""
JSON_DIR=""; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)            MATOMO_URL="$2"; shift 2 ;;
    --matomo-idsite)  MATOMO_IDSITE="$2"; shift 2 ;;
    --site-id)        SITE_ID="$2"; shift 2 ;;
    --site-name)      SITE_NAME="$2"; shift 2 ;;
    --from)           DATE_FROM="$2"; shift 2 ;;
    --to)             DATE_TO="$2"; shift 2 ;;
    --json-dir)       JSON_DIR="$2"; shift 2 ;;   # keep downloaded JSONs
    --dry-run)        DRY_RUN=1; shift ;;          # only load JSON, no DB writes
    -h|--help)        sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
  esac
done
: "${MATOMO_URL:?--url fehlt}"; : "${MATOMO_IDSITE:?--matomo-idsite fehlt}"
: "${SITE_ID:?--site-id fehlt}"; : "${SITE_NAME:?--site-name fehlt}"
: "${DATE_FROM:?--from fehlt (YYYY-MM-DD)}"; : "${DATE_TO:?--to fehlt (YYYY-MM-DD)}"

# ---- Secrets -------------------------------------------------------------
if [ -z "${MATOMO_TOKEN:-}" ] && [ -f "${MATOMO_TOKEN_FILE:-/run/secrets/matomo_token}" ]; then
  MATOMO_TOKEN=$(cat "${MATOMO_TOKEN_FILE:-/run/secrets/matomo_token}")
fi
TOKEN="${MATOMO_TOKEN:?Fehler: MATOMO_TOKEN nicht gesetzt (oder MATOMO_TOKEN_FILE).}"

if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
if [ "$DRY_RUN" -eq 0 ]; then
  DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt (oder CUBE_DSN_FILE). (oder --dry-run)}"
fi

SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
SM_TABLE_META="${SM_TABLE_META:-meta}"
SM_TABLE_TOPN="${SM_TABLE_TOPN:-topn}"
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META SM_TABLE_TOPN
FILTER_LIMIT_HIGH="${FILTER_LIMIT_HIGH:-1000}"

API="${MATOMO_URL%/}/index.php"

# ---- Report catalog: dim-file=method[:flat][:high] -------------------------
# high = high cardinality -> top-N (FILTER_LIMIT_HIGH); otherwise filter_limit=-1.
# flat = &flat=1 for Actions reports (flat URL list instead of a tree).
REPORTS=(
  "daily=VisitsSummary.get"
  "url=Actions.getPageUrls:flat:high"
  "download=Actions.getDownloads:flat"
  "entry=Actions.getEntryPageUrls:flat:high"
  "exit=Actions.getExitPageUrls:flat:high"
  "country=UserCountry.getCountry"
  "browser=DevicesDetection.getBrowsers"
  "os=DevicesDetection.getOsFamilies"
  "device=DevicesDetection.getType"
  "reftype=Referrers.getReferrerType"
  "keyword=Referrers.getKeywords:high"
  "hour=VisitTime.getVisitInformationPerLocalTime"
)

# ---- Generate month chunks (YYYY-MM-DD,YYYY-MM-DD per month) --------------
# period=day + range returns per-day bucketed results in ONE call;
# monthly chunking keeps a single response manageable (instead of 5 years at once).
mapfile -t CHUNKS < <("$DUCKDB" -noheader -list -c "
  SELECT strftime(greatest(m, DATE '${DATE_FROM}'), '%Y-%m-%d') || ',' ||
         strftime(least(m + INTERVAL 1 MONTH - INTERVAL 1 DAY, DATE '${DATE_TO}'), '%Y-%m-%d')
  FROM range(date_trunc('month', DATE '${DATE_FROM}'),
             DATE '${DATE_TO}' + INTERVAL 1 DAY, INTERVAL 1 MONTH) t(m)
  ORDER BY m;")
echo ">> Matomo-Import: idSite=${MATOMO_IDSITE} -> SightMetrics site_id=${SITE_ID} (${SITE_NAME})"
echo ">> Zeitraum ${DATE_FROM}..${DATE_TO} in ${#CHUNKS[@]} Monats-Chunks, ${#REPORTS[@]} Reports/Chunk."

if [ -n "$JSON_DIR" ]; then
  mkdir -p "$JSON_DIR"; WORK="$JSON_DIR"
  echo ">> JSON-Dateien werden behalten unter: ${WORK}"
else
  WORK=$(mktemp -d /tmp/sm_matomo_XXXXXX)
  trap 'rm -rf "$WORK"' EXIT
fi

fetch() { # $1=method $2=outfile $3=daterange $4=flat(0/1) $5=limit
  local method="$1" out="$2" range="$3" flat="$4" limit="$5"
  local url="${API}?module=API&method=${method}&idSite=${MATOMO_IDSITE}&period=day&date=${range}&format=json&filter_limit=${limit}"
  [ "$flat" = "1" ] && url="${url}&flat=1"
  # Token in the POST body (Matomo hardening); empty/erroneous response -> '{}'.
  if ! curl -fsS "$url" --data-urlencode "token_auth=${TOKEN}" -o "$out" 2>/dev/null; then
    echo "   WARN: ${method} ${range} -> curl-Fehler (Netzwerk/Timeout/HTTP), uebersprungen." >&2
    echo "{}" > "$out"; return
  fi
  # Also degrade API errors ("result":"error") to '{}'.
  if grep -q '"result":"error"' "$out" 2>/dev/null; then
    echo "   WARN: ${method} ${range} -> API-Fehler, uebersprungen." >&2
    echo "{}" > "$out"
  fi
}

# ---- Chunk loop -------------------------------------------------------------
n=0
for range in "${CHUNKS[@]}"; do
  n=$((n+1))
  jdir="${WORK}/chunk_${n}"; mkdir -p "$jdir"
  echo ">> [${n}/${#CHUNKS[@]}] ${range}"
  for spec in "${REPORTS[@]}"; do
    dim="${spec%%=*}"; rest="${spec#*=}"
    method="${rest%%:*}"; opts=":${rest#*:}:"
    flat=0; limit=-1
    [[ "$opts" == *":flat:"* ]] && flat=1
    [[ "$opts" == *":high:"* ]] && limit="$FILTER_LIMIT_HIGH"
    fetch "$method" "${jdir}/${dim}.json" "$range" "$flat" "$limit"
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   (dry-run: nur JSON geladen, kein DB-Schreiben)"
    continue
  fi

  # Compute (matomo_to_cube.sql) + shared sink, one DuckDB run per chunk.
  SQL_TMP=$(mktemp "${WORK}/sql_XXXXXX.sql")
  cat matomo_to_cube.sql sink_mysql.sql \
    | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META} ${SM_TABLE_TOPN}' > "$SQL_TMP"
  # range_from/range_to = full chunk range -> the sink clears exactly these
  # days, even if Matomo returns no data for individual days (clean
  # replace instead of just MIN/MAX of the returned data).
  c_from="${range%%,*}"; c_to="${range##*,}"
  # Double single quotes for DuckDB string literals.
  "$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '${DSN//\'/\'\'}' AS m (TYPE mysql);
SET VARIABLE jsondir    = '${jdir}';
SET VARIABLE site_id    = '${SITE_ID}';
SET VARIABLE site_name  = '${SITE_NAME//\'/\'\'}';
SET VARIABLE range_from = '${c_from}';
SET VARIABLE range_to   = '${c_to}';
.read '${SQL_TMP}'
SQL
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo ">> Dry-run fertig. JSON unter ${WORK} (kein DB-Schreiben)."
else
  echo ">> Fertig. ${#CHUNKS[@]} Chunks importiert fuer site_id=${SITE_ID}."
fi
