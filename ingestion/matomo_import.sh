#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Matomo-Altdaten-Import (einmalig pro Kundensite).
#
# Zieht historische Reports aus Matomos Reporting-API (JSON) und schreibt sie
# in dieselbe Cube-/Daily-/Meta-DB wie der taegliche Log-Import. Laeuft
# unabhaengig neben load_cube.sh – der taegliche Log-Import bleibt der
# fortlaufende Schreiber, dieser Import fuellt nur die Vergangenheit auf.
#
# Aggregat-basiert: skaliert auch fuer Sites mit Millionen Hits/Tag, da die
# API bereits pro Tag/Dimension aggregierte Zahlen liefert (keine Rohzeilen).
#
# Nutzung:
#   ./matomo_import.sh --url https://matomo.example.org \
#                      --matomo-idsite 7 \
#                      --site-id 3 --site-name "Musterbehörde" \
#                      --from 2020-01-01 --to 2024-12-31
#
# Token:
#   MATOMO_TOKEN        Reporting-API token_auth (nur View-Rechte noetig), ODER
#   MATOMO_TOKEN_FILE   Pfad zu einer Datei mit dem Token (Default:
#                       /run/secrets/matomo_token). Wird per POST gesendet.
#
# Cube-DB (wie load_cube.sh):
#   CUBE_DSN            DuckDB-MySQL-DSN, ODER
#   CUBE_DSN_FILE       Pfad zur DSN-Datei (Default: /run/secrets/cube_dsn)
#   SM_TABLE_CUBE/DAILY/META   Tabellennamen (Default: cube/daily/meta)
#
# Tuning:
#   FILTER_LIMIT_HIGH   Top-N/Tag fuer High-Cardinality-Dims (url/keyword),
#                       Default 1000. Low-Cardinality-Dims immer vollstaendig.
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
DUCKDB="$(pwd)/bin/duckdb"

# ---- Parameter -------------------------------------------------------------
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
    --json-dir)       JSON_DIR="$2"; shift 2 ;;   # heruntergeladene JSONs behalten
    --dry-run)        DRY_RUN=1; shift ;;          # nur JSON laden, kein DB-Schreiben
    -h|--help)        sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
  esac
done
: "${MATOMO_URL:?--url fehlt}"; : "${MATOMO_IDSITE:?--matomo-idsite fehlt}"
: "${SITE_ID:?--site-id fehlt}"; : "${SITE_NAME:?--site-name fehlt}"
: "${DATE_FROM:?--from fehlt (YYYY-MM-DD)}"; : "${DATE_TO:?--to fehlt (YYYY-MM-DD)}"

# ---- Secrets ---------------------------------------------------------------
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
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META
FILTER_LIMIT_HIGH="${FILTER_LIMIT_HIGH:-1000}"

API="${MATOMO_URL%/}/index.php"

# ---- Report-Katalog: dim-datei=Methode[:flat][:high] ----------------------
# high = High-Cardinality -> Top-N (FILTER_LIMIT_HIGH); sonst filter_limit=-1.
# flat = &flat=1 fuer Actions-Reports (flache URL-Liste statt Baum).
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

# ---- Monats-Chunks erzeugen (YYYY-MM-DD,YYYY-MM-DD je Monat) ---------------
# period=day + Range liefert pro Tag gebucketete Ergebnisse in EINEM Call;
# Monats-Chunking haelt die einzelne Response handlich (statt 5 Jahre am Stueck).
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
  # Token im POST-Body (Matomo-Haertung); leere/fehlerhafte Antwort -> '{}'.
  if ! curl -fsS "$url" --data-urlencode "token_auth=${TOKEN}" -o "$out" 2>/dev/null; then
    echo "   WARN: ${method} ${range} -> curl-Fehler (Netzwerk/Timeout/HTTP), uebersprungen." >&2
    echo "{}" > "$out"; return
  fi
  # API-Fehler ("result":"error") ebenfalls zu '{}' degradieren.
  if grep -q '"result":"error"' "$out" 2>/dev/null; then
    echo "   WARN: ${method} ${range} -> API-Fehler, uebersprungen." >&2
    echo "{}" > "$out"
  fi
}

# ---- Chunk-Schleife --------------------------------------------------------
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

  # Compute (matomo_to_cube.sql) + gemeinsamer Sink, ein DuckDB-Lauf je Chunk.
  SQL_TMP=$(mktemp "${WORK}/sql_XXXXXX.sql")
  cat matomo_to_cube.sql sink_mysql.sql \
    | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}' > "$SQL_TMP"
  # range_from/range_to = voller Chunk-Bereich -> der Sink leert genau diese
  # Tage, auch wenn Matomo fuer einzelne Tage keine Daten liefert (sauberes
  # Ersetzen statt nur MIN/MAX der zurueckgegebenen Daten).
  c_from="${range%%,*}"; c_to="${range##*,}"
  "$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '${DSN}' AS m (TYPE mysql);
SET VARIABLE jsondir    = '${jdir}';
SET VARIABLE site_id    = '${SITE_ID}';
SET VARIABLE site_name  = '${SITE_NAME}';
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
