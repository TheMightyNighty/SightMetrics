#!/usr/bin/env bash
# Pipeline-Tests (Suite 1): Transform-Logik, Envsubst, Purge-Validierung.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> ingestion/ (damit '.read transform.sql' greift)
fail=0

# ---- 1.1 DuckDB Transform-Logik -----------------------------------------------
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

# ---- 1.2 Envsubst: SM_TABLE_* ------------------------------------------------
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

# ---- 1.3 Purge-Skript: Eingabe-Validierung -----------------------------------
echo; echo "== Pipeline: purge_cube.sh Eingabe-Validierung =="
purge_out=$(CUBE_DSN=dummy RETENTION_MONTHS=abc bash ./purge_cube.sh 2>&1) && purge_rc=0 || purge_rc=$?
if [ "$purge_rc" -ne 0 ] && echo "$purge_out" | grep -q 'positive ganze Zahl'; then
  echo "PASS ungültiger RETENTION_MONTHS wird abgelehnt (rc=${purge_rc})"
else
  echo "FAIL ungültiger RETENTION_MONTHS nicht korrekt abgelehnt"
  echo "  Ausgabe: $purge_out"
  fail=1
fi

# ---- 1.4 Log-Format: combined_vhost -----------------------------------------
echo; echo "== Pipeline: SM_LOG_FORMAT=combined_vhost =="
VHOST_LOG=$(mktemp /tmp/sm_vhost_XXXXXX.log)
# fixture.log mit HOST:PORT-Präfix → gleiche Kennzahlen erwartet
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

# ---- 1.5 Backup: Konfigurierbarkeit, Rotation, Deaktivierung -----------------
echo; echo "== Pipeline: backup_cube.sh (Stub-mysqldump) =="
BK_TMP=$(mktemp -d /tmp/sm_bk_XXXXXX)
BK_BIN="${BK_TMP}/bin"; mkdir -p "$BK_BIN"
printf '#!/usr/bin/env bash\necho "-- stub dump $*"\n' > "${BK_BIN}/mysqldump"
chmod +x "${BK_BIN}/mysqldump"
BK_DSN="host=db port=3306 user=report_ro password=secret database=analytics"
backup_ok=1

# Deaktiviert -> No-op, exit 0
out=$(BACKUP_ENABLED=0 CUBE_DSN="$BK_DSN" bash ./backup_cube.sh 2>&1) && rc=0 || rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q 'deaktiviert'; } \
  || { echo "FAIL backup deaktiviert nicht respektiert"; backup_ok=0; }

# Drei Läufe mit Retention=2 -> nur 2 Dumps bleiben
for i in 1 2 3; do
  PATH="$BK_BIN:$PATH" CUBE_DSN="$BK_DSN" BACKUP_DIR="${BK_TMP}/out" STATE_DIR="${BK_TMP}/st" \
    BACKUP_COMPRESS=none BACKUP_RETENTION=2 bash ./backup_cube.sh >/dev/null 2>&1 || { echo "FAIL backup-Lauf $i"; backup_ok=0; }
  sleep 1
done
n=$(ls -1 "${BK_TMP}/out" 2>/dev/null | wc -l)
[ "$n" -eq 2 ] || { echo "FAIL Rotation: erwartet 2 Dumps, gefunden ${n}"; backup_ok=0; }
[ -f "${BK_TMP}/st/backup.last" ] || { echo "FAIL backup.last nicht geschrieben"; backup_ok=0; }

# Fehlendes DSN -> Fehler
out=$(BACKUP_DIR="${BK_TMP}/out2" CUBE_DSN="" CUBE_DSN_FILE=/nonexistent bash ./backup_cube.sh 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -qi 'DSN'; } \
  || { echo "FAIL fehlendes DSN nicht abgelehnt"; backup_ok=0; }
rm -rf "$BK_TMP"
if [ "$backup_ok" -eq 1 ]; then echo "PASS backup: Deaktivierung, Rotation (2), backup.last, DSN-Pflicht"; else fail=1; fi

# ---- 1.6 Notify: Schwellen-Logik --------------------------------------------
echo; echo "== Pipeline: notify.sh Schwellen =="
notify_ok=1
# OK unter Schwelle WARN -> nichts gesendet (exit 0, Hinweis)
out=$(ALERT_MIN_LEVEL=WARN ALERT_EMAIL="" ALERT_WEBHOOK="" bash ./notify.sh OK "test" 2>&1)
echo "$out" | grep -q 'Schwelle' || { echo "FAIL notify: OK unter Schwelle nicht unterdrückt"; notify_ok=0; }
# CRIT ohne Kanal -> exit 0 + Meldung ausgegeben
out=$(ALERT_EMAIL="" ALERT_WEBHOOK="" bash ./notify.sh CRIT "boom" 2>&1) && rc=0 || rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q 'Kein Kanal'; } \
  || { echo "FAIL notify: CRIT ohne Kanal unerwartet"; notify_ok=0; }
if [ "$notify_ok" -eq 1 ]; then echo "PASS notify: Schwellen-Unterdrückung + No-Channel-Hinweis"; else fail=1; fi

# ---- 1.7 Secrets-Rotation: Datei-Logik (ohne DB) ----------------------------
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

# ---- 1.8 Per-Site-Lock in load_cube.sh --------------------------------------
echo; echo "== Pipeline: load_cube.sh Per-Site-Lock =="
lock_ok=1
LK_DIR=$(mktemp -d)
( exec 8>"${LK_DIR}/site_777.lock"; flock -n 8 || exit 1   # Lock von außen halten
  out=$(STATE_DIR="$LK_DIR" CUBE_DSN="dummy" bash ./load_cube.sh tests/fixture.log "LockTest" 777 2>&1) && rc=0 || rc=$?
  { [ "$rc" -eq 0 ] && echo "$out" | grep -q 'bereits importiert'; } || { echo "FAIL Lock nicht respektiert (rc=$rc): $out"; exit 2; }
) || lock_ok=0
rm -rf "$LK_DIR"
if [ "$lock_ok" -eq 1 ]; then echo "PASS per-site-lock: zweiter Lauf derselben Site wird übersprungen"; else fail=1; fi

exit "$fail"
