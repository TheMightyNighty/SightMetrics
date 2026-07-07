# ---------------------------------------------------------------------------
# Healthchecks.io integration (dead man's switch): reports that a run has
# taken place and whether it succeeded. Complements notify.sh, which only
# alerts on active errors within a run, not when the scheduler doesn't
# start the run at all.
#
# ENV: HEALTHCHECK_URL   e.g. https://hc-ping.com/<uuid> (empty = disabled,
#      compatible with self-hosted healthchecks instances)
#      HEALTHCHECK_URL_FILE   alternative: path to a file with the URL
#
# Usage (source it, then):
#   hc_ping "/start"                 run started (optional, for duration tracking)
#   hc_ping ""                       run finished successfully
#   hc_ping "/fail" "error text..."  run failed, body = diagnostics
#
# Ping errors (network, healthchecks unreachable) don't abort the import,
# just a warning on stderr.
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
