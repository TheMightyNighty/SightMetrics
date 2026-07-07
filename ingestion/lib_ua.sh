# ---------------------------------------------------------------------------
# Browser/OS list selection (sourced by load_cube.sh + fetch_loki_logs.sh).
# Expects: caller is already in the ingestion/ directory (pwd).
#
# When the device-detector lists exist (built by tools/fetch_ua_lists.sh),
# UA_SQL loads ua_lookup.sql, which resolves browser/OS per user agent like
# Matomo; without the lists UA_SQL stays empty and transform.sql keeps its
# built-in LIKE heuristic.
#
# ENV: SM_UA_BROWSERS_PATH  (default: ua/browsers.tsv)
#      SM_UA_OSS_PATH       (default: ua/oss.tsv)
# ---------------------------------------------------------------------------
SM_UA_BROWSERS_PATH="${SM_UA_BROWSERS_PATH:-$(pwd)/ua/browsers.tsv}"
SM_UA_OSS_PATH="${SM_UA_OSS_PATH:-$(pwd)/ua/oss.tsv}"
UA_SQL=""
if [ -f "$SM_UA_BROWSERS_PATH" ] && [ -f "$SM_UA_OSS_PATH" ]; then
  UA_SQL="SET VARIABLE ua_browsers_path = '${SM_UA_BROWSERS_PATH//\'/\'\'}';
SET VARIABLE ua_oss_path = '${SM_UA_OSS_PATH//\'/\'\'}';
.read '$(pwd)/ua_lookup.sql'"
  echo ">> Browser/OS-Erkennung: device-detector-Listen (${SM_UA_BROWSERS_PATH%/*})"
else
  echo ">> Browser/OS-Erkennung: eingebaute Heuristik (keine Listen unter ua/; siehe tools/fetch_ua_lists.sh)"
fi
