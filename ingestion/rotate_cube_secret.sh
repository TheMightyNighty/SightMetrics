#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – secrets rotation for the cube DB access.
#
# Resets the DB user's password (ALTER USER) and rewrites the DSN
# secret file ATOMICALLY. Since load_cube.sh/run_all.sh/purge_cube.sh/backup_cube.sh
# read the DSN fresh from the file on EVERY run, the rotation is practically
# uninterrupted (no restart needed). A backup of the old DSN is kept.
#
# Rotates the ingestion user (default: the user from the current DSN, e.g. cube_rw).
# The read-only reporting user (report_ro) is rotated separately, then adjust the
# TYPO3 connection (config/system/additional.php) – see runbook §6.
#
# CONFIGURATION (env):
#   CUBE_DSN_FILE          target/source secret file (required)
#   CUBE_DSN               alternative source if no file (then --skip-db makes sense)
#   ROTATE_NEW_PASSWORD    new password (otherwise generated randomly via openssl)
#   ROTATE_USER            DB user being rotated (default: user= from DSN)
#   ROTATE_USER_HOST       host part of the DB user for ALTER USER (default: %)
#   ROTATE_ADMIN_USER      admin user with ALTER privilege (default: root)
#   ROTATE_ADMIN_PASSWORD / ROTATE_ADMIN_PASSWORD_FILE   admin password
#   MYSQL                  mysql client (default: mysql)
#   ROTATE_KEEP_BACKUPS    number of old DSN backups (default: 5)
#   ROTATE_SKIP_DB         1 = don't change DB, only rewrite the file (tests/special case)
#   ROTATE_DRY_RUN         1 = only show, change nothing
#
# Usage:  CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env ./rotate_cube_secret.sh
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

KEEP="${ROTATE_KEEP_BACKUPS:-5}"
MYSQL="${MYSQL:-mysql}"

# ---- Source: current DSN ----------------------------------------------------
TARGET="${CUBE_DSN_FILE:-}"
if [ -z "${CUBE_DSN:-}" ] && [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
  # File content can be "CUBE_DSN=host=..." (env) OR just "host=...".
  raw=$(cat "$TARGET")
  CUBE_DSN="${raw#CUBE_DSN=}"
fi
DSN="${CUBE_DSN:?Fehler: Kein aktuelles DSN (CUBE_DSN oder CUBE_DSN_FILE setzen).}"
[ -n "$TARGET" ] || { echo "Fehler: CUBE_DSN_FILE (Zieldatei) muss gesetzt sein." >&2; exit 1; }

# Did the file have the "CUBE_DSN=" prefix? Keep it when rewriting.
PREFIX=""
if [ -f "$TARGET" ] && grep -q '^CUBE_DSN=' "$TARGET" 2>/dev/null; then PREFIX="CUBE_DSN="; fi

dsn_field() { sed -nE "s/.*(^|[[:space:]])$1=([^[:space:]]+).*/\2/p" <<<"$DSN"; }
DB_HOST=$(dsn_field host); DB_PORT=$(dsn_field port)
DB_USER=$(dsn_field user); DB_NAME=$(dsn_field database)
DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"

ROTATE_USER="${ROTATE_USER:-$DB_USER}"
ROTATE_USER_HOST="${ROTATE_USER_HOST:-%}"
[ -n "$ROTATE_USER" ] || { echo "Fehler: kein DB-User ermittelbar (user= im DSN fehlt)." >&2; exit 1; }

# ---- New password ------------------------------------------------------------
NEWPW="${ROTATE_NEW_PASSWORD:-}"
if [ -z "$NEWPW" ]; then
  NEWPW=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | cut -c1-24)
  [ -n "$NEWPW" ] || { echo "Fehler: konnte kein Passwort generieren (openssl?)." >&2; exit 1; }
fi

# ---- Build new DSN (replace password= field) --------------------------------
if grep -q 'password=' <<<"$DSN"; then
  NEW_DSN=$(sed -E "s/(^|[[:space:]])password=[^[:space:]]+/\1password=${NEWPW}/" <<<"$DSN")
else
  NEW_DSN="${DSN} password=${NEWPW}"
fi

MASK="password=****"
echo ">> Rotation: User '${ROTATE_USER}'@'${ROTATE_USER_HOST}' auf ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo ">> Ziel-Secret: ${TARGET}  (Backups: ${KEEP})"
echo ">> Neues DSN: $(sed -E 's/password=[^[:space:]]+/'"$MASK"'/' <<<"$NEW_DSN")"

if [ -n "${ROTATE_DRY_RUN:-}" ]; then
  echo ">> DRY RUN – keine DB-Änderung, keine Datei geschrieben."
  exit 0
fi

# ---- Set DB password --------------------------------------------------------
if [ -z "${ROTATE_SKIP_DB:-}" ]; then
  ADMIN_USER="${ROTATE_ADMIN_USER:-root}"
  ADMIN_PW="${ROTATE_ADMIN_PASSWORD:-}"
  if [ -z "$ADMIN_PW" ] && [ -n "${ROTATE_ADMIN_PASSWORD_FILE:-}" ] && [ -f "$ROTATE_ADMIN_PASSWORD_FILE" ]; then
    ADMIN_PW=$(cat "$ROTATE_ADMIN_PASSWORD_FILE")
  fi
  ADMCNF=$(mktemp); chmod 600 "$ADMCNF"
  trap 'rm -f "$ADMCNF"' EXIT
  {
    echo "[client]"; echo "host=${DB_HOST}"; echo "port=${DB_PORT}"; echo "user=${ADMIN_USER}"
    [ -n "$ADMIN_PW" ] && echo "password=${ADMIN_PW}"
  } > "$ADMCNF"

  echo ">> Setze DB-Passwort (ALTER USER)…"
  printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s'; FLUSH PRIVILEGES;\n" \
    "$ROTATE_USER" "$ROTATE_USER_HOST" "$NEWPW" \
    | "$MYSQL" --defaults-extra-file="$ADMCNF"
  echo ">> DB-Passwort gesetzt."

  # ---- Verify (connect with the new password), before overwriting
  # the secret file: if verification fails, the old file remains
  # untouched and the script aborts with exit 1.
  echo ">> Verifiziere neues Passwort…"
  VCNF=$(mktemp); chmod 600 "$VCNF"
  { echo "[client]"; echo "host=${DB_HOST}"; echo "port=${DB_PORT}"; echo "user=${ROTATE_USER}"; echo "password=${NEWPW}"; } > "$VCNF"
  if echo 'SELECT 1;' | "$MYSQL" --defaults-extra-file="$VCNF" >/dev/null 2>&1; then
    echo ">> Verifikation OK: Login mit neuem Passwort erfolgreich."
  else
    rm -f "$VCNF"
    echo "Fehler: Verifikation fehlgeschlagen - Secret-Datei wird NICHT geaendert." >&2
    echo "        DB-Passwort wurde bereits per ALTER USER gesetzt (s.o.), aber der" >&2
    echo "        Login damit schlaegt fehl - Zugang/ROTATE_USER_HOST/Grants pruefen." >&2
    exit 1
  fi
  rm -f "$VCNF"
else
  echo ">> ROTATE_SKIP_DB=1 – DB nicht geändert, nur Datei wird neu geschrieben."
fi

# ---- Replace secret file atomically (with backup) --------------------------
# Only reached if the verification above succeeded (or
# ROTATE_SKIP_DB is set).
if [ -f "$TARGET" ]; then
  BK="${TARGET}.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$TARGET" "$BK"
  echo ">> Backup der alten Secret-Datei: ${BK}"
fi
TMP=$(mktemp "${TARGET}.XXXXXX")
# Take over permissions/owner of the target file, if it exists.
if [ -f "$TARGET" ]; then chmod --reference="$TARGET" "$TMP" 2>/dev/null || chmod 640 "$TMP"; else chmod 640 "$TMP"; fi
printf '%s%s\n' "$PREFIX" "$NEW_DSN" > "$TMP"
mv -f "$TMP" "$TARGET"
echo ">> Secret-Datei aktualisiert (atomar): ${TARGET}"

# ---- Rotate old backups -------------------------------------------------
if [[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 0 ]; then
  mapfile -t OLD < <(ls -1t "${TARGET}.bak-"* 2>/dev/null | tail -n +"$((KEEP + 1))")
  for f in "${OLD[@]}"; do rm -f "$f" && echo ">> Altes Backup entfernt: ${f}"; done
fi
echo ">> Rotation abgeschlossen."
