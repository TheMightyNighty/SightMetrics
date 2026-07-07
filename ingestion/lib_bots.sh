# ---------------------------------------------------------------------------
# Gemeinsame Bot-Listen-Auswahl (source'd von load_cube.sh + fetch_loki_logs.sh).
# Erwartet: Aufrufer steht im ingestion/-Verzeichnis (pwd).
#
# Liegt eine device-detector-Bot-Liste vor (eine Regex pro Zeile, erzeugt von
# tools/fetch_bot_list.sh), wird daraus EIN kombiniertes RE2-Muster gebaut und
# als SQL-Fragment BOT_SQL bereitgestellt (setzt die Variable 'botregex').
# Ohne Liste bleibt BOT_SQL leer -> transform.sql nutzt die eingebaute Heuristik.
#
# ENV: SM_BOT_RE_PATH  Pfad zur Liste (Standard: bots/bot_regex.list)
# ---------------------------------------------------------------------------
SM_BOT_RE_PATH="${SM_BOT_RE_PATH:-$(pwd)/bots/bot_regex.list}"
BOT_SQL=""
if [ -f "$SM_BOT_RE_PATH" ]; then
  # Kombination in SQL (string_agg) statt im Shell-Heredoc: kein Quoting-Problem
  # mit Sonderzeichen in den Mustern, und die Liste bleibt als Datei diffbar.
  BOT_SQL="SET VARIABLE botregex = (
    SELECT '(?i)(' || string_agg(line, ')|(') || ')'
    FROM read_csv('${SM_BOT_RE_PATH//\'/\'\'}',
         columns={'line':'VARCHAR'}, delim='\t', header=false, quote='', escape='', ignore_errors=true)
    WHERE trim(line) <> '' AND line NOT LIKE '#%');"
  echo ">> Bot-Filter: device-detector-Liste (${SM_BOT_RE_PATH})"
else
  echo ">> Bot-Filter: eingebaute Heuristik (keine Liste unter ${SM_BOT_RE_PATH}; siehe tools/fetch_bot_list.sh)"
fi
