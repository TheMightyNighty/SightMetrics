#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Retention/Purge: loescht Cube-Daten aelter als N Monate.
# Meta wird NICHT gepurgt; sie wird beim naechsten load_cube.sh-Lauf
# automatisch aus den verbleibenden Daily-Daten neu berechnet.
#
# Nutzung:  ./purge_cube.sh
#
# Secrets:
#   CUBE_DSN          DuckDB-MySQL-DSN  (wie load_cube.sh)
#   CUBE_DSN_FILE     Pfad zur DSN-Datei (Standard: /run/secrets/cube_dsn)
#
# Konfiguration:
#   RETENTION_MONTHS  Haltezeit in Monaten (Standard: 12)
#   SM_TABLE_CUBE     Tabellenname cube   (Standard: cube)
#   SM_TABLE_DAILY    Tabellenname daily  (Standard: daily)
#   PURGE_DRY_RUN     Falls gesetzt: nur zaehlen, nicht loeschen
#   STATE_DIR         Fuer Metriken (Standard: ../state/)
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
DUCKDB="$(pwd)/bin/duckdb"

# ---- Konfiguration ---------------------------------------------------------
RETENTION_MONTHS="${RETENTION_MONTHS:-12}"
SM_TABLE_CUBE="${SM_TABLE_CUBE:-cube}"
SM_TABLE_DAILY="${SM_TABLE_DAILY:-daily}"
PURGE_DRY_RUN="${PURGE_DRY_RUN:-}"

if ! [[ "$RETENTION_MONTHS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Fehler: RETENTION_MONTHS muss eine positive ganze Zahl sein (ist: '${RETENTION_MONTHS}')." >&2
  exit 1
fi

# ---- Secrets ---------------------------------------------------------------
if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
  CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
fi
DSN="${CUBE_DSN:?Fehler: CUBE_DSN nicht gesetzt. Setze CUBE_DSN oder lege die Secret-Datei unter CUBE_DSN_FILE ab.}"

# ---- Cutoff-Datum ----------------------------------------------------------
CUTOFF=$(date -d "-${RETENTION_MONTHS} months" +%Y-%m-%d)
echo ">> SightMetrics Purge: Daten vor ${CUTOFF} (RETENTION_MONTHS=${RETENTION_MONTHS})"
echo ">> Tabellen: ${SM_TABLE_CUBE}, ${SM_TABLE_DAILY}"
[ -n "$PURGE_DRY_RUN" ] && echo ">> DRY RUN – nur Zählung, kein Löschen."

# ---- Vorher zählen ---------------------------------------------------------
"$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '${DSN}' AS m (TYPE mysql);
SELECT '${SM_TABLE_CUBE}_to_purge'  AS k, COUNT(*) AS n FROM m.${SM_TABLE_CUBE}  WHERE datum < '${CUTOFF}'
UNION ALL
SELECT '${SM_TABLE_DAILY}_to_purge' AS k, COUNT(*) AS n FROM m.${SM_TABLE_DAILY} WHERE datum < '${CUTOFF}';
SQL

# ---- Loeschen (ausser bei DRY_RUN) -----------------------------------------
if [ -z "$PURGE_DRY_RUN" ]; then
  "$DUCKDB" <<SQL
INSTALL mysql; LOAD mysql;
ATTACH '${DSN}' AS m (TYPE mysql);
CALL mysql_execute('m', 'DELETE FROM ${SM_TABLE_CUBE}  WHERE datum < ' || CHR(39) || '${CUTOFF}' || CHR(39));
CALL mysql_execute('m', 'DELETE FROM ${SM_TABLE_DAILY} WHERE datum < ' || CHR(39) || '${CUTOFF}' || CHR(39));
SQL
  echo ">> Purge abgeschlossen. Meta wird beim naechsten Import aktualisiert."
fi

# ---- Metriken --------------------------------------------------------------
STATE_DIR="${STATE_DIR:-${REPO}/state}"
mkdir -p "$STATE_DIR"
printf 'ts=%s action=purge retention_months=%s cutoff=%s dry_run=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RETENTION_MONTHS" "$CUTOFF" "${PURGE_DRY_RUN:-false}" \
  >> "${STATE_DIR}/metrics.log"
