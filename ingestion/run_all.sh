#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Alle Sites importieren (Orchestrator).
#
# Liest sites.conf, ruft load_cube.sh pro Site auf, schreibt ein Log und
# gibt am Ende eine Zusammenfassung aus.  Exit-Code 1 wenn mind. eine Site
# fehlschlug (für cron/systemd-Alerting).
#
# Nutzung:
#   ./run_all.sh [--parallel N] [--sites /pfad/sites.conf]
#
# Env-Variablen:
#   CUBE_DSN     DuckDB-MySQL-DSN (oder CUBE_DSN_FILE, siehe load_cube.sh)
#   STATE_DIR    Offset-State-Verzeichnis (Standard: ../state/)
#   PARALLEL     Parallele Jobs (Standard: 1)
#   SITES_CONF   Pfad zur sites.conf (Standard: ./sites.conf)
#   LOG_DIR      Import-Logverzeichnis (Standard: ../logs/import-logs/)
#   HEALTHCHECK_URL / HEALTHCHECK_URL_FILE   Heartbeat-Ping (healthchecks.io
#     o.ae., optional, siehe lib_healthcheck.sh) – meldet zusaetzlich zu
#     notify.sh (aktive Fehler) auch einen AUSBLEIBENDEN Lauf (Scheduler
#     defekt, Container startet nicht, ...).
#
# Cron-Beispiel (täglich 02:00 Uhr):
#   0 2 * * * /opt/sightmetrics/ingestion/run_all.sh >> /var/log/sightmetrics/cron.log 2>&1
#
# Systemd: siehe scheduling/sight_metrics_import.{service,timer}
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

# ---- Healthcheck-Heartbeat (healthchecks.io o.ae., optional) ---------------
# Trap deckt ALLE Exit-Pfade ab (auch fruehe Config-Fehler): liest den
# tatsaechlichen Exit-Code der Shell beim Beenden aus.
source "$(pwd)/lib_healthcheck.sh"
cleanup_and_ping() {
  local rc=$?
  [ -n "${SITES_TMP:-}" ] && rm -f "$SITES_TMP"
  if [ "$rc" -eq 0 ]; then
    hc_ping ""
  else
    hc_ping "/fail" "run_all.sh fehlgeschlagen (exit ${rc})$([ -n "${RUN_LOG:-}" ] && [ -f "${RUN_LOG:-}" ] && printf '\n\n%s' "$(tail -c 10000 "$RUN_LOG")")"
  fi
}
trap cleanup_and_ping EXIT
hc_ping "/start"

# ---- Parameter -------------------------------------------------------------
PARALLEL="${PARALLEL:-1}"
SITES_CONF="${SITES_CONF:-$(pwd)/sites.conf}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel) PARALLEL="$2"; shift 2 ;;
    --sites)    SITES_CONF="$2"; shift 2 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
done

# PARALLEL=auto → Kerne automatisch erkennen.
if [ "$PARALLEL" = "auto" ]; then
  PARALLEL="$(nproc 2>/dev/null || echo 1)"
fi
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "Fehler: PARALLEL muss positive Ganzzahl oder 'auto' sein (ist: '${PARALLEL}')." >&2; exit 1; }

if [ ! -f "$SITES_CONF" ]; then
  echo "Fehler: $SITES_CONF nicht gefunden. Vorlage: sites.conf.example" >&2
  exit 1
fi

# ---- Concurrency-Schutz: nur eine Instanz gleichzeitig --------------------
# Lockfile im STATE_DIR; flock -n schlägt sofort fehl wenn Lock belegt ist.
# Exit 0 → systemd/cron meldet keinen Fehler für übersprungenen Lauf.
STATE_DIR="${STATE_DIR:-$(cd .. && pwd)/state}"
mkdir -p "$STATE_DIR"
LOCKFILE="${STATE_DIR}/run_all.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "$(date -u +%H:%M:%SZ) WARN: run_all.sh läuft bereits (${LOCKFILE}). Lauf übersprungen." >&2
  exit 0
fi

# ---- Log-Datei -------------------------------------------------------------
LOG_DIR="${LOG_DIR:-$(cd .. && pwd)/logs/import-logs}"
mkdir -p "$LOG_DIR"
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_LOG="${LOG_DIR}/run_${RUN_TS}.log"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$RUN_LOG"; }

log "=== SightMetrics Import gestartet (PID $$, PARALLEL=${PARALLEL}) ==="
log "sites.conf: ${SITES_CONF}"
log "state:      ${STATE_DIR:-../state/}"
log "log:        ${RUN_LOG}"

# ---- Sites laden -----------------------------------------------------------
# Temporäre Datei mit bereinigten Zeilen (Kommentare/Leerzeilen entfernt)
SITES_TMP=$(mktemp)
grep -v '^\s*#' "$SITES_CONF" | grep -v '^\s*$' > "$SITES_TMP" || true

TOTAL=$(wc -l < "$SITES_TMP")
if [ "$TOTAL" -eq 0 ]; then
  log "Keine Sites in ${SITES_CONF} konfiguriert. Fertig."
  exit 0
fi
log "Sites gesamt: ${TOTAL}"

# ---- Import-Funktion (wird pro Site aufgerufen, auch via xargs) -----------
import_site() {
  local site_id="$1" logfile="$2" site_name="$3"
  local site_log="${LOG_DIR}/site_${site_id}_${RUN_TS}.log"
  local rc=0
  if bash "$(dirname "$0")/load_cube.sh" "$logfile" "$site_name" "$site_id" \
       >"$site_log" 2>&1; then
    echo "OK  site=${site_id} log=${site_log}"
  else
    rc=$?
    echo "FAIL site=${site_id} rc=${rc} log=${site_log}"
  fi
  return "$rc"
}
export -f import_site
export LOG_DIR RUN_TS

# ---- Sequenziell oder parallel --------------------------------------------
FAIL=0
PASS=0

if [ "$PARALLEL" -le 1 ]; then
  while IFS=$'\t' read -r site_id logfile site_name; do
    result=$(import_site "$site_id" "$logfile" "$site_name" 2>&1) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
    log "$result"
  done < "$SITES_TMP"
else
  # xargs -P: jede Zeile = ein Job, Ergebnisse nach stdout
  results=$(
    while IFS=$'\t' read -r site_id logfile site_name; do
      printf '%s\0%s\0%s\0' "$site_id" "$logfile" "$site_name"
    done < "$SITES_TMP" \
    | xargs -0 -n 3 -P "$PARALLEL" bash -c 'import_site "$1" "$2" "$3"' _
  ) || true
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "$line"
    [[ "$line" == FAIL* ]] && FAIL=$((FAIL+1)) || PASS=$((PASS+1))
  done <<< "$results"
fi

# Verlorene Jobs abfangen: liefert ein Site-Job kein 'OK '/'FAIL '-Ergebnis
# (z.B. extern gekillt: OOM-Killer, docker stop, Host-Reboot), zaehlt er
# oben weder als PASS noch als FAIL -> ohne diese Pruefung koennte
# PASS+FAIL < TOTAL sein und der Lauf trotzdem als Erfolg (Exit 0) durchgehen.
MISSING=$((TOTAL - PASS - FAIL))
if [ "$MISSING" -gt 0 ]; then
  log "WARN: ${MISSING} Site(s) ohne Ergebnis-Meldung (Job vermutlich abgebrochen/gekillt) -> als FEHLER gewertet."
  FAIL=$((FAIL + MISSING))
fi

# ---- Zusammenfassung -------------------------------------------------------
log "=== Fertig: ${PASS} OK, ${FAIL} FEHLER von ${TOTAL} Sites ==="

# Inline-Alarmierung bei Fehlern: passt zum Wegwerf-Container (kein systemd/OnFailure).
# notify.sh ist ein No-op, solange kein Kanal (ALERT_EMAIL/ALERT_WEBHOOK) gesetzt ist.
# Healthcheck-Ping (Erfolg/Fehler) uebernimmt der EXIT-Trap oben (cleanup_and_ping).
if [ "$FAIL" -gt 0 ]; then
  bash "$(dirname "$0")/notify.sh" CRIT "Import: ${FAIL} von ${TOTAL} Sites fehlgeschlagen (Log: ${RUN_LOG})" || true
fi

[ "$FAIL" -eq 0 ]
