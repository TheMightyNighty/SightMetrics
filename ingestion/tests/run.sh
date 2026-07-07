#!/usr/bin/env bash
# Pipeline tests (suite 1): transform logic, envsubst, purge validation.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> ingestion/ (so that '.read transform.sql' works)
fail=0

# ---- 1.1 DuckDB transform logic -----------------------------------------------
echo "== Pipeline: transform.sql gegen Fixture =="
OUT=$(./bin/duckdb <<'SQL'
SET VARIABLE logpath   = 'tests/fixture.log';
SET VARIABLE geopath   = 'tests/geo_mini.csv';
.read 'geo_sources/native.sql'
.read 'log_formats/regex.sql'
SET VARIABLE site_name = 'Test';
SET VARIABLE tagessalt = 'testsalt';
.read 'tests/pipeline_test.sql'
SQL
)
echo "$OUT"
if echo "$OUT" | grep -q 'FAIL'; then
  echo ">> PIPELINE-TEST: FEHLGESCHLAGEN"; fail=1
else
  echo ">> PIPELINE-TEST: OK"
fi

# ---- 1.2 Envsubst: SM_TABLE_* -----------------------------------------------
echo; echo "== Pipeline: SM_TABLE_* Envsubst =="
ENVSUBST_TMP=$(mktemp /tmp/sm_envsubst_XXXXXX.sql)
trap 'rm -f "$ENVSUBST_TMP"' EXIT
SM_TABLE_CUBE=mein_cube SM_TABLE_DAILY=mein_daily SM_TABLE_META=mein_meta \
  envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META}' \
  < sink_mysql.sql > "$ENVSUBST_TMP"
envsubst_ok=1
grep -q 'm\.mein_cube'  "$ENVSUBST_TMP" || { echo "FAIL m.mein_cube nicht gefunden";  envsubst_ok=0; }
grep -q 'm\.mein_daily' "$ENVSUBST_TMP" || { echo "FAIL m.mein_daily nicht gefunden"; envsubst_ok=0; }
grep -q 'm\.mein_meta'  "$ENVSUBST_TMP" || { echo "FAIL m.mein_meta nicht gefunden";  envsubst_ok=0; }
if [ "$envsubst_ok" -eq 1 ]; then
  echo "PASS Tabellennamen korrekt substituiert (mein_cube / mein_daily / mein_meta)"
else
  fail=1
fi

# ---- 1.3 Purge script: input validation --------------------------------------
echo; echo "== Pipeline: purge_cube.sh Eingabe-Validierung =="
purge_out=$(CUBE_DSN=dummy RETENTION_MONTHS=abc bash ./purge_cube.sh 2>&1) && purge_rc=0 || purge_rc=$?
if [ "$purge_rc" -ne 0 ] && echo "$purge_out" | grep -q 'positive ganze Zahl'; then
  echo "PASS ungültiger RETENTION_MONTHS wird abgelehnt (rc=${purge_rc})"
else
  echo "FAIL ungültiger RETENTION_MONTHS nicht korrekt abgelehnt"
  echo "  Ausgabe: $purge_out"
  fail=1
fi

# ---- 1.4 Log format: combined_vhost ------------------------------------------
echo; echo "== Pipeline: SM_LOG_FORMAT=combined_vhost =="
VHOST_LOG=$(mktemp /tmp/sm_vhost_XXXXXX.log)
# fixture.log with HOST:PORT prefix → same metrics expected
sed 's/^/meinhost.de:443 /' tests/fixture.log > "$VHOST_LOG"
VHOST_REGEX='^\S+:\d+ (\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+) "([^"]*)" "([^"]*)"'
VHOST_OUT=$(./bin/duckdb <<SQL
SET VARIABLE logpath   = '${VHOST_LOG}';
SET VARIABLE geopath   = 'tests/geo_mini.csv';
.read 'geo_sources/native.sql'
SET VARIABLE site_name = 'Test-VHost';
SET VARIABLE tagessalt = 'testsalt';
SET VARIABLE logregex  = '${VHOST_REGEX}';
SET VARIABLE tsformat  = '%d/%b/%Y:%H:%M:%S %z';
.read 'log_formats/regex.sql'
.read 'tests/pipeline_test.sql'
SQL
)
rm -f "$VHOST_LOG"
echo "$VHOST_OUT"
if echo "$VHOST_OUT" | grep -q 'FAIL'; then
  echo "FAIL combined_vhost: Ergebnis weicht ab"; fail=1
else
  echo "PASS combined_vhost: gleiche Kennzahlen wie combined"
fi

# ---- 1.5 Backup: configurability, rotation, deactivation ---------------------
echo; echo "== Pipeline: backup_cube.sh (Stub-mysqldump) =="
BK_TMP=$(mktemp -d /tmp/sm_bk_XXXXXX)
BK_BIN="${BK_TMP}/bin"; mkdir -p "$BK_BIN"
printf '#!/usr/bin/env bash\necho "-- stub dump $*"\n' > "${BK_BIN}/mysqldump"
chmod +x "${BK_BIN}/mysqldump"
BK_DSN="host=db port=3306 user=report_ro password=secret database=analytics"
backup_ok=1

# Disabled -> no-op, exit 0
out=$(BACKUP_ENABLED=0 CUBE_DSN="$BK_DSN" bash ./backup_cube.sh 2>&1) && rc=0 || rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q 'deaktiviert'; } \
  || { echo "FAIL backup deaktiviert nicht respektiert"; backup_ok=0; }

# Three runs with retention=2 -> only 2 dumps remain
for i in 1 2 3; do
  PATH="$BK_BIN:$PATH" CUBE_DSN="$BK_DSN" BACKUP_DIR="${BK_TMP}/out" STATE_DIR="${BK_TMP}/st" \
    BACKUP_COMPRESS=none BACKUP_RETENTION=2 bash ./backup_cube.sh >/dev/null 2>&1 || { echo "FAIL backup-Lauf $i"; backup_ok=0; }
  sleep 1
done
n=$(ls -1 "${BK_TMP}/out" 2>/dev/null | wc -l)
[ "$n" -eq 2 ] || { echo "FAIL Rotation: erwartet 2 Dumps, gefunden ${n}"; backup_ok=0; }
[ -f "${BK_TMP}/st/backup.last" ] || { echo "FAIL backup.last nicht geschrieben"; backup_ok=0; }

# Missing DSN -> error
out=$(BACKUP_DIR="${BK_TMP}/out2" CUBE_DSN="" CUBE_DSN_FILE=/nonexistent bash ./backup_cube.sh 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -qi 'DSN'; } \
  || { echo "FAIL fehlendes DSN nicht abgelehnt"; backup_ok=0; }
rm -rf "$BK_TMP"
if [ "$backup_ok" -eq 1 ]; then echo "PASS backup: Deaktivierung, Rotation (2), backup.last, DSN-Pflicht"; else fail=1; fi

# ---- 1.6 Notify: threshold logic ----------------------------------------------
echo; echo "== Pipeline: notify.sh Schwellen =="
notify_ok=1
# OK below threshold WARN -> nothing sent (exit 0, notice)
out=$(ALERT_MIN_LEVEL=WARN ALERT_EMAIL="" ALERT_WEBHOOK="" bash ./notify.sh OK "test" 2>&1)
echo "$out" | grep -q 'Schwelle' || { echo "FAIL notify: OK unter Schwelle nicht unterdrückt"; notify_ok=0; }
# CRIT without channel -> exit 0 + message printed
out=$(ALERT_EMAIL="" ALERT_WEBHOOK="" bash ./notify.sh CRIT "boom" 2>&1) && rc=0 || rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q 'Kein Kanal'; } \
  || { echo "FAIL notify: CRIT ohne Kanal unerwartet"; notify_ok=0; }
if [ "$notify_ok" -eq 1 ]; then echo "PASS notify: Schwellen-Unterdrückung + No-Channel-Hinweis"; else fail=1; fi

# ---- 1.7 Secrets rotation: file logic (without DB) ----------------------------
echo; echo "== Pipeline: rotate_cube_secret.sh (Datei, ROTATE_SKIP_DB) =="
rot_ok=1
RT_DIR=$(mktemp -d); RT_FILE="${RT_DIR}/cube_dsn.env"
echo 'CUBE_DSN=host=db port=3306 user=cube_rw password=altPW database=analytics' > "$RT_FILE"
chmod 640 "$RT_FILE"
CUBE_DSN_FILE="$RT_FILE" ROTATE_SKIP_DB=1 ROTATE_NEW_PASSWORD=neuPW123 bash ./rotate_cube_secret.sh >/dev/null 2>&1 \
  || { echo "FAIL rotate-Lauf"; rot_ok=0; }
grep -q '^CUBE_DSN=' "$RT_FILE" || { echo "FAIL CUBE_DSN=-Präfix nicht erhalten"; rot_ok=0; }
grep -q 'password=neuPW123' "$RT_FILE" || { echo "FAIL neues Passwort nicht geschrieben"; rot_ok=0; }
grep -q 'password=altPW' "$RT_FILE" && { echo "FAIL altes Passwort noch vorhanden"; rot_ok=0; }
grep -q 'user=cube_rw' "$RT_FILE" || { echo "FAIL übrige DSN-Felder verloren"; rot_ok=0; }
ls "${RT_FILE}.bak-"* >/dev/null 2>&1 || { echo "FAIL kein Backup angelegt"; rot_ok=0; }
perm=$(stat -c '%a' "$RT_FILE"); [ "$perm" = "640" ] || { echo "FAIL Dateirechte != 640 (war: $perm)"; rot_ok=0; }
rm -rf "$RT_DIR"
if [ "$rot_ok" -eq 1 ]; then echo "PASS rotation: Passwort getauscht, Präfix+Felder erhalten, Backup, Rechte 640"; else fail=1; fi

# ---- 1.8 Per-site lock in load_cube.sh ----------------------------------------
echo; echo "== Pipeline: load_cube.sh Per-Site-Lock =="
lock_ok=1
LK_DIR=$(mktemp -d)
( exec 8>"${LK_DIR}/site_777.lock"; flock -n 8 || exit 1   # hold the lock externally
  out=$(STATE_DIR="$LK_DIR" CUBE_DSN="dummy" bash ./load_cube.sh tests/fixture.log "LockTest" 777 2>&1) && rc=0 || rc=$?
  { [ "$rc" -eq 0 ] && echo "$out" | grep -q 'bereits importiert'; } || { echo "FAIL Lock nicht respektiert (rc=$rc): $out"; exit 2; }
) || lock_ok=0
rm -rf "$LK_DIR"
if [ "$lock_ok" -eq 1 ]; then echo "PASS per-site-lock: zweiter Lauf derselben Site wird übersprungen"; else fail=1; fi

# ---- 1.9 Day-boundary cut (day_cut.sql) ---------------------------------------
echo; echo "== Pipeline: day_cut.sql (Byte-genauer Cut am Tageswechsel) =="
cut_ok=1
CUT_LOG=$(mktemp /tmp/sm_cut_XXXXXX.log)
# 2 lines "yesterday" (10th), 2 lines "today" (11th) – cut at 2026-01-11 expected:
# consumed bytes = exactly the length of the first two lines.
head -n 2 tests/fixture.log > "$CUT_LOG"
sed 's|10/Jan/2026|11/Jan/2026|' tests/fixture.log | head -n 2 >> "$CUT_LOG"
DAY1_BYTES=$(head -n 2 tests/fixture.log | wc -c)

cut_probe() { # $1=cutoff  -> outputs "consumed remaining"
  ./bin/duckdb -noheader -list <<SQL
SET VARIABLE logpath = '${CUT_LOG}';
SET VARIABLE cutoff_date = '$1';
.read 'log_formats/regex.sql'
.read 'day_cut.sql'
SELECT (CASE WHEN getvariable('cut_rid') IS NULL THEN -1
        ELSE (SELECT COALESCE(SUM(nbytes),0) FROM raw_lines WHERE rid < getvariable('cut_rid')) END)
       || ' ' || (SELECT count(*) FROM parsed_lines);
SQL
}

out=$(cut_probe 2026-01-11)
[ "$out" = "${DAY1_BYTES} 2" ] \
  || { echo "FAIL cut@2026-01-11: erwartet '${DAY1_BYTES} 2', ist '${out}'"; cut_ok=0; }
out=$(cut_probe 2026-01-10)   # everything is >= cutoff -> consume nothing, import nothing
[ "$out" = "0 0" ] \
  || { echo "FAIL cut@2026-01-10: erwartet '0 0', ist '${out}'"; cut_ok=0; }
out=$(cut_probe 2026-01-12)   # everything is older -> no cut (-1 = caller uses file size)
[ "$out" = "-1 4" ] \
  || { echo "FAIL cut@2026-01-12: erwartet '-1 4', ist '${out}'"; cut_ok=0; }
rm -f "$CUT_LOG"
if [ "$cut_ok" -eq 1 ]; then echo "PASS day-cut: Byte-Offset exakt, Zurueckhalten & No-Cut korrekt"; else fail=1; fi

# ---- 1.10 Bot list (lib_bots.sh + botregex variable) ---------------------------
echo; echo "== Pipeline: Bot-Liste (device-detector-Mechanismus) =="
bot_ok=1
BOTL_DIR=$(mktemp -d)
BOTL="${BOTL_DIR}/bot_regex.list"
# The list REPLACES the heuristic (no mixed operation) -> Googlebot must be
# included in the test list, otherwise the Googlebot fixture line suddenly counts.
printf '# Kommentar\nAcmeHarvester/[0-9.]+\nGooglebot\n' > "$BOTL"
BOT_LOG="${BOTL_DIR}/log"
cp tests/fixture.log "$BOT_LOG"
# UA that the built-in heuristic does NOT recognize -> only the list filters it.
printf '9.9.9.9 - - [10/Jan/2026:14:00:00 +0000] "GET /a HTTP/1.1" 200 100 "-" "AcmeHarvester/2.1"\n' >> "$BOT_LOG"

bot_probe() { # $1 = additional SQL (BOT_SQL or empty) -> pageviews_total
  ./bin/duckdb -noheader -list <<SQL
SET VARIABLE logpath = '${BOT_LOG}';
SET VARIABLE geopath = 'tests/geo_mini.csv';
SET VARIABLE site_name = 'BotTest'; SET VARIABLE tagessalt = 's';
$1
.read 'geo_sources/native.sql'
.read 'log_formats/regex.sql'
.read 'transform.sql'
SELECT pageviews_total FROM meta_row;
SQL
}

SM_BOT_RE_PATH="$BOTL" source ./lib_bots.sh >/dev/null
[ -n "$BOT_SQL" ] || { echo "FAIL lib_bots: BOT_SQL leer trotz vorhandener Liste"; bot_ok=0; }
with_list=$(bot_probe "$BOT_SQL")
without_list=$(bot_probe "")
[ "$with_list" = "6" ] || { echo "FAIL mit Liste: erwartet 6 Pageviews (AcmeHarvester gefiltert), ist '${with_list}'"; bot_ok=0; }
[ "$without_list" = "7" ] || { echo "FAIL ohne Liste: erwartet 7 Pageviews (Heuristik kennt AcmeHarvester nicht), ist '${without_list}'"; bot_ok=0; }
# Missing list -> BOT_SQL empty (heuristic fallback in transform.sql).
no_list_sql=$(SM_BOT_RE_PATH="${BOTL_DIR}/nicht_da.list" bash -c 'cd "'"$(pwd)"'" && source ./lib_bots.sh >/dev/null; printf %s "$BOT_SQL"')
[ -z "$no_list_sql" ] || { echo "FAIL ohne Liste: BOT_SQL muss leer sein"; bot_ok=0; }
rm -rf "$BOTL_DIR"
if [ "$bot_ok" -eq 1 ]; then echo "PASS bot-liste: Listen-Muster filtert, Fallback-Heuristik unveraendert"; else fail=1; fi

exit "$fail"
