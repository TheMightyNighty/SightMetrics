# ---------------------------------------------------------------------------
# Healthchecks.io-Anbindung ("Dead-Man's-Switch"): meldet, DASS ein Lauf
# stattgefunden hat (und ob er erfolgreich war) – ergaenzt notify.sh, das nur
# bei AKTIVEN Fehlern innerhalb eines Laufs alarmiert. Ohne Heartbeat merkt
# niemand, wenn der Scheduler (Cron/CronJob) den Lauf gar nicht erst startet.
#
# ENV: HEALTHCHECK_URL   z.B. https://hc-ping.com/<uuid> (leer = deaktiviert,
#      kompatibel zu selbstgehosteten healthchecks-Instanzen)
#      HEALTHCHECK_URL_FILE   Alternative: Pfad zu einer Datei mit der URL
#
# Nutzung (source'n, dann):
#   hc_ping "/start"                    # Lauf begonnen (optional, fuer Dauer-Tracking)
#   hc_ping ""                          # Lauf erfolgreich beendet
#   hc_ping "/fail" "Fehlertext..."      # Lauf fehlgeschlagen, Body = Diagnose (von
#                                        # healthchecks.io geloggt, siehe dortiges Log)
#
# Ping-Fehler (Netzwerk, Healthchecks nicht erreichbar) brechen den
# eigentlichen Import NICHT ab - nur eine Warnung auf stderr.
# ---------------------------------------------------------------------------
if [ -z "${HEALTHCHECK_URL:-}" ] && [ -f "${HEALTHCHECK_URL_FILE:-/run/secrets/healthcheck_url}" ]; then
  HEALTHCHECK_URL=$(cat "${HEALTHCHECK_URL_FILE:-/run/secrets/healthcheck_url}")
fi

hc_ping() {
  local suffix="$1" body="${2:-}"
  [ -z "${HEALTHCHECK_URL:-}" ] && return 0
  command -v curl >/dev/null || return 0
  if [ -n "$body" ]; then
    curl -fsS -m 10 --retry 2 --data-binary "$body" "${HEALTHCHECK_URL%/}${suffix}" -o /dev/null \
      || echo "WARN: Healthcheck-Ping (${suffix:-ok}) fehlgeschlagen." >&2
  else
    curl -fsS -m 10 --retry 2 "${HEALTHCHECK_URL%/}${suffix}" -o /dev/null \
      || echo "WARN: Healthcheck-Ping (${suffix:-ok}) fehlgeschlagen." >&2
  fi
}
