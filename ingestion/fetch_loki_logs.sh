#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – alternativer Log-Weg: Zeilen aus Grafana Loki statt aus einer
# Logdatei. Holt per LogQL-Range-Query die seit dem letzten Lauf neuen Zeilen
# und verarbeitet sie ohne Zwischendatei: Zeilen bleiben im Prozessspeicher
# und werden per Prozess-Substitution direkt in DuckDB gestreamt. Parsing,
# Sessionisierung und Aggregation nutzen dieselbe Logik wie der dateibasierte
# Import (transform.sql); die Quelle ist eine HTTP-API statt einer Datei mit
# Byte-Offset.
#
# Voraussetzung: Loki-Log-Zeilen enthalten die vollstaendige Rohzeile
# (Apache/nginx Combined o.ae.), z. B. weil Promtail access.log 1:1 scraped.
# Fuer strukturierte/JSON-Loki-Zeilen vorher per LogQL-Pipeline (| line_format)
# auf eine Zeile im SM_LOG_FORMAT-kompatiblen Format bringen.
#
# Nutzung:
#   ./fetch_loki_logs.sh --url http://loki:3100 \
#                        --query '{job="nginx",site="behoerde-a"}' \
#                        --site-id 1 --site-name "Behörde A"
#
# Inkrementell ueber Zeitstempel (nicht Byte-Offset/Inode wie bei Dateien):
#   State liegt in STATE_DIR/<hash>.loki_ts (letzter verarbeiteter Loki-
#   Zeitstempel in Nanosekunden). Erster Lauf: siehe --lookback-hours.
#
# Optionen (bzw. gleichnamige ENV-Variablen mit LOKI_-Prefix, z.B. LOKI_URL):
#   --url              Loki-Basis-URL, z.B. http://loki:3100        (Pflicht)
#   --query            LogQL-Stream-Selector                        (Pflicht)
#   --site-id / --site-name   wie bei load_cube.sh                   (Pflicht)
#   --namespace        Bequemlichkeits-Filter: wird als zusaetzlicher
#                       Label-Matcher "namespace=..." in --query eingemischt
#                       (z.B. Kubernetes/Promtail-Namespace), optional
#   --org-id           X-Scope-OrgID Header (Loki Multi-Tenant), optional
#   --limit            Batchgroesse pro Loki-Query (Standard: 5000)
#   --lookback-hours   Nur beim allerersten Lauf: wie weit zurueck (Standard: 24)
#   --safety-seconds   Sicherheitsabstand zu "jetzt" gegen spaet eintreffende,
#                       nachtraeglich gepushte Zeilen (Standard: 30)
#
# Uebernimmt dieselben ENV-Variablen wie load_cube.sh: CUBE_DSN/CUBE_DSN_FILE,
#   SM_TABLE_*, SM_LOG_FORMAT/SM_LOG_REGEX_CUSTOM/SM_TS_FORMAT_CUSTOM,
#   SM_GEO_*, STATE_DIR. Nutzt denselben Per-Site-Lock wie load_cube.sh
#   (state/site_<id>.lock) – Datei- und Loki-Import derselben Site laufen
#   nie parallel.
#
# Heartbeat (healthchecks.io o.ae., optional, siehe lib_healthcheck.sh):
#   HEALTHCHECK_URL / HEALTHCHECK_URL_FILE   Ping bei Start/Erfolg/Fehler,
#     damit auch ein AUSBLEIBENDER Lauf auffaellt (nicht nur aktive Fehler).
#
# Benoetigt: curl, jq (auf dem Host/Container, der dieses Skript ausfuehrt).
# Die geholten Zeilen werden im Prozessspeicher gehalten, nicht von der
# Loki-Antwort gestreamt – bei sehr grossen Batches (--limit x viele Seiten)
# entsprechend RAM einplanen.
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
DUCKDB="$(pwd)/bin/duckdb"

# ---- Parameter --------------------------------------------------------------
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

# ---- Namespace-Filter (Kubernetes/Promtail-Label "namespace") --------------
# Bequemlichkeitsoption zusaetzlich zu --query: wird als weiterer Label-
# Matcher in den Stream-Selector eingemischt, z.B.
#   --query '{job="nginx"}' --namespace behoerde-a  ->  {namespace="behoerde-a",job="nginx"}
# Bei komplexeren Faellen (kein Namespace-Label, mehrere Selektoren, o.ae.)
# den Namespace stattdessen direkt in --query/LOKI_QUERY schreiben.
if [ -n "$LOKI_NAMESPACE" ]; then
  case "$LOKI_QUERY" in
    \{*) LOKI_QUERY="{namespace=\"${LOKI_NAMESPACE}\",${LOKI_QUERY#\{}" ;;
    *)   echo "Fehler: --namespace erfordert einen Stream-Selector in { } als --query." >&2; exit 1 ;;
  esac
fi

command -v curl >/dev/null || { echo "Fehler: curl nicht gefunden." >&2; exit 1; }
command -v jq   >/dev/null || { echo "Fehler: jq nicht gefunden." >&2; exit 1; }

# ---- Healthcheck-Heartbeat (healthchecks.io o.ae., optional) ---------------
# Trap deckt alle Exit-Pfade ab, auch fruehe Fehler wie fehlendes CUBE_DSN
# oder eine fehlende Geo-Datei, und liest den Exit-Code beim Beenden aus.
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

# ---- Geo-Quelle + Log-Format (gemeinsam mit load_cube.sh) -------------------
source "$(pwd)/lib_geo.sh"
source "$(pwd)/lib_logformat.sh"

# ---- Secrets ----------------------------------------------------------------
if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt. Setze CUBE_DSN oder lege die Secret-Datei unter CUBE_DSN_FILE ab.}"

# ---- Tabellennamen ------------------------------------------------------------
SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
SM_TABLE_META="${SM_TABLE_META:-meta}"
export SM_TABLE_CUBE SM_TABLE_DAILY SM_TABLE_META

STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"

# ---- Per-Site-Lock (geteilt mit load_cube.sh) -------------------------------
SITE_LOCK="${STATE_DIR}/site_${SITE_ID}.lock"
exec 9>"$SITE_LOCK"
if ! flock -n 9; then
  echo ">> Site ${SITE_ID} wird bereits importiert (Lock ${SITE_LOCK}). Übersprungen."
  exit 0
fi

# ---- Zeitstempel-State (statt Byte-Offset/Inode) ----------------------------
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

# ---- Von Loki abholen (paginiert), Zeilen im Speicher sammeln --------------
CURL_HEADERS=()
[ -n "$LOKI_ORG_ID" ] && CURL_HEADERS+=(-H "X-Scope-OrgID: ${LOKI_ORG_ID}")

echo ">> Hole neue Zeilen aus Loki: ${LOKI_QUERY}"
LINES=""
cursor="$START_NS"
# Loki behandelt den Bereich als [start, end) - start inklusiv, end exklusiv.
# Abfrage mit end=END_NS+1, damit das Intervall [START_NS, END_NS] inklusive
# abgedeckt ist (sonst wuerde eine Zeile mit Zeitstempel exakt END_NS weder in
# diesem noch im naechsten Lauf abgeholt).
QUERY_END_NS=$((END_NS + 1))
total=0
max_ts=0
page=0
max_pages=1000   # Sicherheitsguard gegen Endlosschleife bei degenerierten Faellen
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
# State-Obergrenze: im Normalfall END_NS (Fenster vollstaendig geleert). Wird
# der max_pages-Guard erreicht, ist das Fenster nicht vollstaendig abgeholt -
# State dann nur bis zum zuletzt verarbeiteten Zeitstempel (max_ts) fortschreiben,
# damit der naechste Lauf dort weitermacht statt die restlichen Zeilen zu ueberspringen.
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

# ---- Direkt verarbeiten: Zeilen per anonymer Pipe an DuckDB ----------------
# 'exec {fd}< <(...)' haelt die Pipe (anders als eine blosse Zuweisung) ueber
# den Rest des Skripts offen, sodass DuckDB /dev/fd/<fd> danach noch oeffnen kann.
exec {LOGFD}< <(printf '%s' "$LINES")

SQL_TMP=$(mktemp /tmp/sm_sql_XXXXXX.sql)
cat "$(pwd)/cube_to_mysql.sql" "$(pwd)/sink_mysql.sql" \
  | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}' > "$SQL_TMP"

t0=$(date +%s.%N)
"$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '${DSN}' AS m (TYPE mysql);
SET VARIABLE logpath    = '/dev/fd/${LOGFD}';
SET VARIABLE geopath    = '${GEO}';
SET VARIABLE geolocpath = '${GEO_LOC}';
SET VARIABLE site_name  = '${SITE_NAME}';
SET VARIABLE site_id    = '${SITE_ID}';
SET VARIABLE tagessalt  = '$(date +%Y%m%d)-sightmetrics';
SET VARIABLE logregex   = '${SM_LOG_REGEX}';
SET VARIABLE tsformat   = '${SM_TS_FORMAT}';
.read '${GEO_SOURCE_SQL}'
.read '${LOG_FORMAT_SQL}'
.read '${SQL_TMP}'
SQL
t1=$(date +%s.%N)
WALL=$(awk "BEGIN{printf \"%.2f\", $t1-$t0}")
echo ">> Loki -> MariaDB fertig. Wall=${WALL}s (${total} Zeilen, Site ${SITE_ID})"

# ---- Metriken (gleiche Konvention wie load_cube.sh) -------------------------
METRICS_LAST="${STATE_DIR}/site_${SITE_ID}.last"
METRICS_LOG="${STATE_DIR}/metrics.log"
TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'ts=%s site_id=%s status=ok wall_s=%s new_lines=%s source=loki query=%s\n' \
  "$TS_NOW" "$SITE_ID" "$WALL" "$total" "$LOKI_QUERY" \
  | tee "$METRICS_LAST" >> "$METRICS_LOG"

# ---- State erst nach erfolgreichem Import fortschreiben ---------------------
echo "$STATE_NS" > "$TS_FILE"
echo ">> Loki-State aktualisiert (bis ${STATE_NS} ns)."
