#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – import all sites (orchestrator).
#
# Reads sites.conf, calls load_cube.sh per site, writes a log and
# prints a summary at the end.  Exit code 1 if at least one site
# failed (for cron/systemd alerting).
#
# Usage:
#   ./run_all.sh [--parallel N] [--sites /path/sites.conf]
#
# Env vars:
#   CUBE_DSN     DuckDB MySQL DSN (or CUBE_DSN_FILE, see load_cube.sh)
#   STATE_DIR    offset state directory (default: ../state/)
#   PARALLEL     parallel jobs (default: 1)
#   SITES_CONF   path to sites.conf (default: ./sites.conf)
#   LOG_DIR      import log directory (default: ../logs/import-logs/)
#   HEALTHCHECK_URL / HEALTHCHECK_URL_FILE   heartbeat ping (healthchecks.io
#     or similar, optional, see lib_healthcheck.sh) – in addition to
#     notify.sh (active errors), this also reports a MISSING run (scheduler
#     broken, container won't start, ...).
#
# Cron example (daily at 02:00):
#   0 2 * * * /opt/sightmetrics/ingestion/run_all.sh >> /var/log/sightmetrics/cron.log 2>&1
#
# Systemd: see scheduling/sight_metrics_import.{service,timer}
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

# ---- Healthcheck heartbeat (healthchecks.io or similar, optional) ---------
# Trap covers ALL exit paths (including early config errors): reads the
# actual exit code of the shell on termination.
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

# ---- Parameters -------------------------------------------------------------
PARALLEL="${PARALLEL:-1}"
SITES_CONF="${SITES_CONF:-$(pwd)/sites.conf}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel) PARALLEL="$2"; shift 2 ;;
    --sites)    SITES_CONF="$2"; shift 2 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
done

# PARALLEL=auto → detect cores automatically.
if [ "$PARALLEL" = "auto" ]; then
  PARALLEL="$(nproc 2>/dev/null || echo 1)"
fi
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "Fehler: PARALLEL muss positive Ganzzahl oder 'auto' sein (ist: '${PARALLEL}')." >&2; exit 1; }

if [ ! -f "$SITES_CONF" ]; then
  echo "Fehler: $SITES_CONF nicht gefunden. Vorlage: sites.conf.example" >&2
  exit 1
fi

# ---- Concurrency protection: only one instance at a time ------------------
# Lockfile in STATE_DIR; flock -n fails immediately if the lock is held.
# Exit 0 → systemd/cron reports no error for a skipped run.
STATE_DIR="${STATE_DIR:-$(cd .. && pwd)/state}"
mkdir -p "$STATE_DIR"
LOCKFILE="${STATE_DIR}/run_all.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "$(date -u +%H:%M:%SZ) WARN: run_all.sh läuft bereits (${LOCKFILE}). Lauf übersprungen." >&2
  exit 0
fi

# ---- Log file ---------------------------------------------------------------
LOG_DIR="${LOG_DIR:-$(cd .. && pwd)/logs/import-logs}"
mkdir -p "$LOG_DIR"
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_LOG="${LOG_DIR}/run_${RUN_TS}.log"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$RUN_LOG"; }

log "=== SightMetrics Import gestartet (PID $$, PARALLEL=${PARALLEL}) ==="
log "sites.conf: ${SITES_CONF}"
log "state:      ${STATE_DIR:-../state/}"
log "log:        ${RUN_LOG}"

# ---- Load sites -------------------------------------------------------------
# Temporary file with cleaned-up lines (comments/blank lines removed)
SITES_TMP=$(mktemp)
grep -v '^\s*#' "$SITES_CONF" | grep -v '^\s*$' > "$SITES_TMP" || true

TOTAL=$(wc -l < "$SITES_TMP")
if [ "$TOTAL" -eq 0 ]; then
  log "Keine Sites in ${SITES_CONF} konfiguriert. Fertig."
  exit 0
fi
log "Sites gesamt: ${TOTAL}"

# ---- Import function (called per site, also via xargs) -------------------
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

# ---- Sequential or parallel -------------------------------------------------
FAIL=0
PASS=0

if [ "$PARALLEL" -le 1 ]; then
  while IFS=$'\t' read -r site_id logfile site_name; do
    result=$(import_site "$site_id" "$logfile" "$site_name" 2>&1) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
    log "$result"
  done < "$SITES_TMP"
else
  # xargs -P: each line = one job, results go to stdout
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

# A site job without an 'OK '/'FAIL ' result (e.g. killed externally by
# the OOM killer, docker stop, host reboot) counts above as neither PASS nor
# FAIL; the difference to TOTAL is counted as an error.
MISSING=$((TOTAL - PASS - FAIL))
if [ "$MISSING" -gt 0 ]; then
  log "WARN: ${MISSING} Site(s) ohne Ergebnis-Meldung (Job vermutlich abgebrochen/gekillt) -> als FEHLER gewertet."
  FAIL=$((FAIL + MISSING))
fi

# Prometheus textfile collector (node_exporter) -- see lib_prom.sh / runbook.
source "$(dirname "$0")/lib_prom.sh"
prom_run_metrics "$TOTAL" "$PASS" "$FAIL"

# ---- Summary ------------------------------------------------------------
log "=== Fertig: ${PASS} OK, ${FAIL} FEHLER von ${TOTAL} Sites ==="

# Inline alerting on errors: fits a disposable container (no systemd/OnFailure).
# notify.sh is a no-op as long as no channel (ALERT_EMAIL/ALERT_WEBHOOK) is set.
# The healthcheck ping (success/failure) is handled by the EXIT trap above (cleanup_and_ping).
if [ "$FAIL" -gt 0 ]; then
  bash "$(dirname "$0")/notify.sh" CRIT "Import: ${FAIL} von ${TOTAL} Sites fehlgeschlagen (Log: ${RUN_LOG})" || true
fi

[ "$FAIL" -eq 0 ]
