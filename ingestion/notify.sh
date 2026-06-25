#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Alarmierung (E-Mail und/oder Webhook).
#
# Verschickt eine Meldung an die konfigurierten Kanaele. Wird benutzt von:
#   – run_all.sh (inline-Alarm bei fehlgeschlagenem Import)
#   – manuell:   ./notify.sh CRIT "Import fuer site=3 fehlgeschlagen"
#
# ALLES KONFIGURIERBAR ueber Env-Variablen:
#   ALERT_EMAIL       Empfaenger-Adresse(n), kommagetrennt   (leer = kein Mail)
#   ALERT_MAIL_FROM   Absender                               (sightmetrics@$(hostname))
#   ALERT_MAIL_BIN    mail-Binary                            (mail)
#   ALERT_WEBHOOK     Webhook-URL (Slack/Teams/generisch)    (leer = kein Webhook)
#   ALERT_WEBHOOK_FORMAT  slack | teams | json               (slack)
#   ALERT_MIN_LEVEL   Ab welchem Level alarmieren: OK|WARN|CRIT  (WARN)
#   ALERT_PREFIX      Betreff-/Text-Praefix                  ([SightMetrics])
#
# Aufruf:  ./notify.sh <LEVEL> <NACHRICHT...>
#          LEVEL = OK | WARN | CRIT | UNKNOWN  (oder Zahl 0/1/2/3)
# Exit:    0 = versendet/kein Kanal noetig, 1 = mind. ein Kanal fehlgeschlagen
# ---------------------------------------------------------------------------
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

ALERT_EMAIL="${ALERT_EMAIL:-}"
ALERT_MAIL_FROM="${ALERT_MAIL_FROM:-sightmetrics@$(hostname -f 2>/dev/null || hostname)}"
ALERT_MAIL_BIN="${ALERT_MAIL_BIN:-mail}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT:-slack}"
ALERT_MIN_LEVEL="${ALERT_MIN_LEVEL:-WARN}"
ALERT_PREFIX="${ALERT_PREFIX:-[SightMetrics]}"

# ---- Level normalisieren (Name oder Zahl) -> Zahl 0..3 ---------------------
to_num() {
  case "${1^^}" in
    OK|0)      echo 0 ;;
    WARN*|1)   echo 1 ;;
    CRIT*|2)   echo 2 ;;
    *)         echo 3 ;;   # UNKNOWN
  esac
}
name_of() { case "$1" in 0) echo OK ;; 1) echo WARNING ;; 2) echo CRITICAL ;; *) echo UNKNOWN ;; esac; }

LEVEL_RAW="${1:-UNKNOWN}"; shift || true
MSG="$*"
[ -n "$MSG" ] || MSG="(keine Nachricht)"

LVL=$(to_num "$LEVEL_RAW")
MIN=$(to_num "$ALERT_MIN_LEVEL")
LVL_NAME=$(name_of "$LVL")
HOST="$(hostname -f 2>/dev/null || hostname)"
SUBJECT="${ALERT_PREFIX} ${LVL_NAME} @ ${HOST}"
BODY="${LVL_NAME}: ${MSG} (Host: ${HOST}, $(date -u +%Y-%m-%dT%H:%M:%SZ))"

# Unterhalb der Schwelle (z. B. OK bei MIN=WARN) -> nichts senden.
if [ "$LVL" -lt "$MIN" ]; then
  echo ">> notify: Level ${LVL_NAME} < Schwelle ${ALERT_MIN_LEVEL} – nichts gesendet."
  exit 0
fi

rc=0

# ---- E-Mail ----------------------------------------------------------------
if [ -n "$ALERT_EMAIL" ]; then
  if command -v "$ALERT_MAIL_BIN" >/dev/null 2>&1; then
    if printf '%s\n' "$BODY" | "$ALERT_MAIL_BIN" -s "$SUBJECT" \
         ${ALERT_MAIL_FROM:+-r "$ALERT_MAIL_FROM"} "$ALERT_EMAIL"; then
      echo ">> notify: Mail an ${ALERT_EMAIL} gesendet."
    else
      echo "notify: Mailversand fehlgeschlagen." >&2; rc=1
    fi
  else
    echo "notify: Mail-Binary '${ALERT_MAIL_BIN}' nicht gefunden." >&2; rc=1
  fi
fi

# ---- Webhook ---------------------------------------------------------------
if [ -n "$ALERT_WEBHOOK" ]; then
  esc=$(printf '%s' "$BODY" | sed 's/\\/\\\\/g; s/"/\\"/g')
  case "$ALERT_WEBHOOK_FORMAT" in
    slack) payload="{\"text\":\"${SUBJECT}\n${esc}\"}" ;;
    teams) payload="{\"title\":\"${SUBJECT}\",\"text\":\"${esc}\"}" ;;
    json)  payload="{\"level\":\"${LVL_NAME}\",\"host\":\"${HOST}\",\"message\":\"${esc}\"}" ;;
    *)     echo "notify: ALERT_WEBHOOK_FORMAT unbekannt (${ALERT_WEBHOOK_FORMAT})." >&2; rc=1; payload="" ;;
  esac
  if [ -n "$payload" ]; then
    if curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK" >/dev/null; then
      echo ">> notify: Webhook (${ALERT_WEBHOOK_FORMAT}) gesendet."
    else
      echo "notify: Webhook-Versand fehlgeschlagen." >&2; rc=1
    fi
  fi
fi

if [ -z "$ALERT_EMAIL" ] && [ -z "$ALERT_WEBHOOK" ]; then
  echo ">> notify: Kein Kanal konfiguriert (ALERT_EMAIL/ALERT_WEBHOOK leer). Meldung: ${BODY}"
fi

exit "$rc"
