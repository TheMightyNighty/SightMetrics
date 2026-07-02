#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Secrets-Rotation für den Cube-DB-Zugang.
#
# Setzt das Passwort des DB-Users neu (ALTER USER) und schreibt die DSN-
# Secret-Datei ATOMAR neu. Da load_cube.sh/run_all.sh/purge_cube.sh/backup_cube.sh
# das DSN bei JEDEM Lauf frisch aus der Datei lesen, ist die Rotation praktisch
# unterbrechungsfrei (kein Neustart nötig). Vom alten DSN wird ein Backup behalten.
#
# Rotiert den Ingestion-User (Standard: der User aus dem aktuellen DSN, z. B. cube_rw).
# Den read-only-Reporting-User (report_ro) rotiert man separat und passt dann die
# TYPO3-Connection an (config/system/additional.php) – siehe Runbook §6.
#
# KONFIGURATION (Env):
#   CUBE_DSN_FILE          Ziel-/Quell-Secret-Datei (Pflicht)
#   CUBE_DSN               Alternative Quelle, wenn keine Datei (dann --skip-db sinnvoll)
#   ROTATE_NEW_PASSWORD    Neues Passwort (sonst zufällig via openssl generiert)
#   ROTATE_USER            DB-User der rotiert wird (Standard: user= aus DSN)
#   ROTATE_USER_HOST       Host-Teil des DB-Users für ALTER USER (Standard: %)
#   ROTATE_ADMIN_USER      Admin-User mit ALTER-Recht (Standard: root)
#   ROTATE_ADMIN_PASSWORD / ROTATE_ADMIN_PASSWORD_FILE   Admin-Passwort
#   MYSQL                  mysql-Client (Standard: mysql)
#   ROTATE_KEEP_BACKUPS    Anzahl alter DSN-Backups (Standard: 5)
#   ROTATE_SKIP_DB         1 = DB nicht ändern, nur Datei neu schreiben (Tests/Sonderfall)
#   ROTATE_DRY_RUN         1 = nur anzeigen, nichts ändern
#
# Nutzung:  CUBE_DSN_FILE=/etc/sightmetrics/cube_dsn.env ./rotate_cube_secret.sh
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

KEEP="${ROTATE_KEEP_BACKUPS:-5}"
MYSQL="${MYSQL:-mysql}"

# ---- Quelle: aktuelles DSN -------------------------------------------------
TARGET="${CUBE_DSN_FILE:-}"
if [ -z "${CUBE_DSN:-}" ] && [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
  # Dateiinhalt kann "CUBE_DSN=host=..." (env) ODER nur "host=..." sein.
  raw=$(cat "$TARGET")
  CUBE_DSN="${raw#CUBE_DSN=}"
fi
DSN="${CUBE_DSN:?Fehler: Kein aktuelles DSN (CUBE_DSN oder CUBE_DSN_FILE setzen).}"
[ -n "$TARGET" ] || { echo "Fehler: CUBE_DSN_FILE (Zieldatei) muss gesetzt sein." >&2; exit 1; }

# Hatte die Datei das "CUBE_DSN="-Präfix? Beim Neuschreiben beibehalten.
PREFIX=""
if [ -f "$TARGET" ] && grep -q '^CUBE_DSN=' "$TARGET" 2>/dev/null; then PREFIX="CUBE_DSN="; fi

dsn_field() { sed -nE "s/.*(^|[[:space:]])$1=([^[:space:]]+).*/\2/p" <<<"$DSN"; }
DB_HOST=$(dsn_field host); DB_PORT=$(dsn_field port)
DB_USER=$(dsn_field user); DB_NAME=$(dsn_field database)
DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"

ROTATE_USER="${ROTATE_USER:-$DB_USER}"
ROTATE_USER_HOST="${ROTATE_USER_HOST:-%}"
[ -n "$ROTATE_USER" ] || { echo "Fehler: kein DB-User ermittelbar (user= im DSN fehlt)." >&2; exit 1; }

# ---- Neues Passwort --------------------------------------------------------
NEWPW="${ROTATE_NEW_PASSWORD:-}"
if [ -z "$NEWPW" ]; then
  NEWPW=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | cut -c1-24)
  [ -n "$NEWPW" ] || { echo "Fehler: konnte kein Passwort generieren (openssl?)." >&2; exit 1; }
fi

# ---- Neues DSN bauen (password=-Feld ersetzen) -----------------------------
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

# ---- DB-Passwort setzen ----------------------------------------------------
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

  # ---- Verifizieren (mit neuem Passwort verbinden), vor dem Ueberschreiben
  # der Secret-Datei: schlaegt die Verifikation fehl, bleibt die alte Datei
  # unangetastet und das Skript bricht mit Exit 1 ab.
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

# ---- Secret-Datei atomar ersetzen (mit Backup) -----------------------------
# Wird nur erreicht, wenn die Verifikation oben erfolgreich war (oder
# ROTATE_SKIP_DB gesetzt ist).
if [ -f "$TARGET" ]; then
  BK="${TARGET}.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$TARGET" "$BK"
  echo ">> Backup der alten Secret-Datei: ${BK}"
fi
TMP=$(mktemp "${TARGET}.XXXXXX")
# Rechte/Owner der Zieldatei übernehmen, falls vorhanden.
if [ -f "$TARGET" ]; then chmod --reference="$TARGET" "$TMP" 2>/dev/null || chmod 640 "$TMP"; else chmod 640 "$TMP"; fi
printf '%s%s\n' "$PREFIX" "$NEW_DSN" > "$TMP"
mv -f "$TMP" "$TARGET"
echo ">> Secret-Datei aktualisiert (atomar): ${TARGET}"

# ---- Alte Backups rotieren -------------------------------------------------
if [[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 0 ]; then
  mapfile -t OLD < <(ls -1t "${TARGET}.bak-"* 2>/dev/null | tail -n +"$((KEEP + 1))")
  for f in "${OLD[@]}"; do rm -f "$f" && echo ">> Altes Backup entfernt: ${f}"; done
fi
echo ">> Rotation abgeschlossen."
