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

# ---- Offset-Tracking -------------------------------------------------------
STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"

# ---- Per-Site-Lock: kein paralleler Doppelimport derselben Site -----------
# Schützt die Offset-/Meta-Konsistenz, falls sich zwei Läufe für dieselbe Site
# überschneiden (z. B. manuell + geplanter Lauf). Laeuft VOR Geo/Secrets/
# Log-Format-Validierung, damit ein Lock-Konflikt sofort und ressourcenfrei
# abbricht, statt an fehlenden Voraussetzungen zu scheitern, die fuer diesen
# Lauf gar nicht mehr gebraucht werden.
SITE_LOCK="${STATE_DIR}/site_${SITEID}.lock"
exec 9>"$SITE_LOCK"
if ! flock -n 9; then
  echo ">> Site ${SITEID} wird bereits importiert (Lock ${SITE_LOCK}). Übersprungen."
  exit 0
fi

# ---- Geo-Quelle -------------------------------------------------------------
source "$(pwd)/lib_geo.sh"

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
source "$(pwd)/lib_logformat.sh"

# ---- Bot-Liste (device-detector, optional; sonst eingebaute Heuristik) ------
source "$(pwd)/lib_bots.sh"

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
TIME_TMP=$(mktemp /tmp/sm_time_XXXXXX.txt)      # eigene Datei je Lauf: PARALLEL-sicher
CONSUMED_TMP=$(mktemp /tmp/sm_consumed_XXXXXX.csv)
trap 'rm -f "$TMPLOG" "$SQL_TMP" "$TIME_TMP" "$CONSUMED_TMP"' EXIT
cat "$(pwd)/cube_to_mysql.sql" "$(pwd)/sink_mysql.sql" \
  | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}' > "$SQL_TMP"
tail -c "+$((OFFSET + 1))" "$LOGFILE" > "$TMPLOG"
NEW_BYTES=$(wc -c < "$TMPLOG")

if [ "$NEW_BYTES" -eq 0 ]; then
  echo ">> Keine neuen Daten seit letztem Lauf (Site ${SITEID}). Fertig."
  exit 0
fi
echo ">> Verarbeite $((NEW_BYTES / 1024 + 1)) KB neue Daten (~$(wc -l < "$TMPLOG") Zeilen)"

# ---- Tagesgrenzen-Cut (siehe day_cut.sql / Runbook §8) ----------------------
# Zeilen des noch laufenden Tages (UTC) werden zurueckgehalten und erst beim
# naechsten Lauf importiert -- sonst wuerde das Bereichs-DELETE des Sinks beim
# Folgelauf die frueh importierten Stunden dieses Tages verwerfen.
#   SM_COMPLETE_DAYS=0   deaktiviert den Cut (z. B. fuer Backfills/Tests)
#   SM_CUTOFF_DATE       Cut-Datum ueberschreiben (Standard: heute, UTC)
CUTOFF_DATE=""
if [ "${SM_COMPLETE_DAYS:-1}" != "0" ]; then
  CUTOFF_DATE="${SM_CUTOFF_DATE:-$(date -u +%Y-%m-%d)}"
fi

# Einfache Anfuehrungszeichen fuer DuckDB-Stringliterale verdoppeln -- ein
# Apostroph im Site-Namen/DSN/Regex darf das SQL nicht brechen.
sq() { printf '%s' "${1//\'/\'\'}"; }

# ---- Import ----------------------------------------------------------------
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

# ---- Offset aktualisieren (nur nach erfolgreichem Import) ------------------
# consumed = -1: kein Cut -> alles verarbeitet, Offset = Dateigroesse (byte-exakt).
# Sonst: Offset nur bis vor die erste zurueckgehaltene Zeile vorruecken.
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

# ---- Metriken schreiben (für Monitoring / Alerting) -----------------------
# site_N.last: letzter Lauf (Overwrite) – Status/Zeitstempel des letzten Imports.
# metrics.log: kumulatives Append aller Läufe.
METRICS_LAST="${STATE_DIR}/site_${SITEID}.last"
METRICS_LOG="${STATE_DIR}/metrics.log"
TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'ts=%s site_id=%s status=ok wall_s=%s cpu_s=%s new_bytes=%s offset=%s logfile=%s\n' \
  "$TS_NOW" "$SITEID" "$WALL" "$CPU" "$NEW_BYTES" "$NEW_OFFSET" "$LOGFILE" \
  | tee "$METRICS_LAST" >> "$METRICS_LOG"
