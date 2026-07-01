#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SightMetrics – Backup der Cube-DB (Rollback-Punkt, u. a. vor dem Purge).
#
# Erstellt einen mysqldump der Cube-Tabellen, komprimiert ihn und haelt nur
# die letzten N Dumps vor (Rotation). Dient als Rollback-Sicherung vor dem
# Retention-Purge und als allgemeines Backup.
#
# ALLES KONFIGURIERBAR ueber Env-Variablen (Defaults in Klammern):
#   BACKUP_ENABLED    Backup aktiv? 1/true = ja, 0/false = ueberspringen (1)
#   BACKUP_DIR        Zielverzeichnis fuer Dumps              (../backups)
#   BACKUP_RETENTION  Anzahl vorzuhaltender Dumps (Rotation)  (14); 0 = nie loeschen
#   BACKUP_TABLES     Zu sichernde Tabellen (Leerzeichen)     ("meta daily cube")
#                     Leer = ganze Datenbank
#   BACKUP_COMPRESS   Kompression: gzip | zstd | none         (gzip)
#   BACKUP_PREFIX     Dateinamen-Praefix                      (cube)
#   MYSQLDUMP         Pfad zum mysqldump-Binary               (mysqldump)
#   BACKUP_EXTRA_ARGS Zusaetzliche mysqldump-Argumente        ("")
#   BACKUP_DRY_RUN    Falls gesetzt: nur anzeigen, nichts tun ("")
#
# Zugangsdaten (eigene Backup-Credentials moeglich; sonst CUBE_DSN):
#   BACKUP_DSN / BACKUP_DSN_FILE   bevorzugt (read-only-User wie report_ro reicht)
#   CUBE_DSN   / CUBE_DSN_FILE     Fallback (wie load_cube.sh)
#   DSN-Format: host=... port=... user=... password=... database=...
#
#   STATE_DIR        Fuer Metriken (../state)
#
# Nutzung:  ./backup_cube.sh            (regulaeres Backup)
#           BACKUP_DRY_RUN=1 ./backup_cube.sh
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"

# ---- Konfiguration ---------------------------------------------------------
BACKUP_ENABLED="${BACKUP_ENABLED:-1}"
BACKUP_DIR="${BACKUP_DIR:-${REPO}/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-14}"
BACKUP_TABLES="${BACKUP_TABLES:-meta daily cube}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-gzip}"
BACKUP_PREFIX="${BACKUP_PREFIX:-cube}"
MYSQLDUMP="${MYSQLDUMP:-mysqldump}"
BACKUP_EXTRA_ARGS="${BACKUP_EXTRA_ARGS:-}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-}"
STATE_DIR="${STATE_DIR:-${REPO}/state}"

# An/aus konfigurierbar – sauberer No-op, wenn deaktiviert.
case "${BACKUP_ENABLED,,}" in
  0|false|no|off) echo ">> Backup deaktiviert (BACKUP_ENABLED=${BACKUP_ENABLED}). Uebersprungen."; exit 0 ;;
esac

if ! [[ "$BACKUP_RETENTION" =~ ^[0-9]+$ ]]; then
  echo "Fehler: BACKUP_RETENTION muss eine ganze Zahl >= 0 sein (ist: '${BACKUP_RETENTION}')." >&2
  exit 1
fi

# ---- DSN ermitteln (Backup-eigen oder Fallback CUBE_DSN) -------------------
if [ -z "${BACKUP_DSN:-}" ] && [ -n "${BACKUP_DSN_FILE:-}" ] && [ -f "${BACKUP_DSN_FILE}" ]; then
  BACKUP_DSN=$(cat "$BACKUP_DSN_FILE")
fi
if [ -z "${BACKUP_DSN:-}" ]; then
  if [ -z "${CUBE_DSN:-}" ] && [ -f "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}" ]; then
    CUBE_DSN=$(cat "${CUBE_DSN_FILE:-/run/secrets/cube_dsn}")
  fi
  BACKUP_DSN="${CUBE_DSN:-}"
fi
[ -n "$BACKUP_DSN" ] || { echo "Fehler: Kein DSN. Setze BACKUP_DSN/BACKUP_DSN_FILE oder CUBE_DSN/CUBE_DSN_FILE." >&2; exit 1; }

# ---- DSN in Felder zerlegen (host=.. port=.. user=.. password=.. database=..)
dsn_field() { sed -nE "s/.*(^|[[:space:]])$1=([^[:space:]]+).*/\2/p" <<<"$BACKUP_DSN"; }
DB_HOST=$(dsn_field host);     DB_PORT=$(dsn_field port)
DB_USER=$(dsn_field user);     DB_PASS=$(dsn_field password)
DB_NAME=$(dsn_field database)
DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"
[ -n "$DB_NAME" ] || { echo "Fehler: 'database=' fehlt im DSN." >&2; exit 1; }
[ -n "$DB_USER" ] || { echo "Fehler: 'user=' fehlt im DSN." >&2; exit 1; }

# ---- Kompression waehlen ---------------------------------------------------
case "$BACKUP_COMPRESS" in
  gzip) COMP_CMD="gzip -c";  EXT=".sql.gz" ;;
  zstd) COMP_CMD="zstd -q -c"; EXT=".sql.zst" ;;
  none) COMP_CMD="cat";      EXT=".sql" ;;
  *) echo "Fehler: BACKUP_COMPRESS muss gzip|zstd|none sein (ist: '${BACKUP_COMPRESS}')." >&2; exit 1 ;;
esac

TS=$(date +%Y%m%d_%H%M%S)
OUT="${BACKUP_DIR}/${BACKUP_PREFIX}_${TS}${EXT}"

echo ">> SightMetrics Backup"
echo ">> DB ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME} | Tabellen: ${BACKUP_TABLES:-<alle>}"
echo ">> Ziel: ${OUT} | Kompression: ${BACKUP_COMPRESS} | Retention: ${BACKUP_RETENTION}"

if [ -n "$BACKUP_DRY_RUN" ]; then
  echo ">> DRY RUN – kein Dump, keine Rotation."
  exit 0
fi

mkdir -p "$BACKUP_DIR"

# ---- mysqldump mit Defaults-Datei (Passwort nicht in der Prozessliste) -----
MYCNF=$(mktemp)
chmod 600 "$MYCNF"
trap 'rm -f "$MYCNF"' EXIT
{
  echo "[client]"
  echo "host=${DB_HOST}"
  echo "port=${DB_PORT}"
  echo "user=${DB_USER}"
  [ -n "$DB_PASS" ] && echo "password=${DB_PASS}"
} > "$MYCNF"

set +e
# shellcheck disable=SC2086
"$MYSQLDUMP" --defaults-extra-file="$MYCNF" \
  --single-transaction --no-tablespaces --skip-lock-tables \
  $BACKUP_EXTRA_ARGS \
  "$DB_NAME" $BACKUP_TABLES | $COMP_CMD > "$OUT"
rc=("${PIPESTATUS[@]}")   # atomar in EINEM Befehl sichern (sonst ueberschreibt
rc_dump="${rc[0]}"        # das Auslesen von PIPESTATUS[0] bereits PIPESTATUS[1])
rc_comp="${rc[1]}"
set -e

# Beide Pipe-Stufen pruefen: mysqldump UND die Kompression (gzip/zstd) koennen
# unabhaengig voneinander fehlschlagen (z. B. Platte voll waehrend gzip
# schreibt) - nur mysqldump zu pruefen haette ein stillschweigend kaputtes/
# abgeschnittenes Backup als Erfolg gemeldet.
if [ "$rc_dump" -ne 0 ] || [ "$rc_comp" -ne 0 ]; then
  echo "Fehler: Backup fehlgeschlagen (mysqldump rc=${rc_dump}, ${BACKUP_COMPRESS} rc=${rc_comp})." >&2
  rm -f "$OUT"
  exit "$(( rc_dump != 0 ? rc_dump : rc_comp ))"
fi

SIZE=$(wc -c < "$OUT")
echo ">> Backup geschrieben: ${OUT} ($((SIZE/1024)) KB)"

# ---- Rotation: nur die letzten N behalten ---------------------------------
DELETED=0
if [ "$BACKUP_RETENTION" -gt 0 ]; then
  mapfile -t OLD < <(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}_"*"${EXT}" 2>/dev/null | tail -n +"$((BACKUP_RETENTION + 1))")
  for f in "${OLD[@]}"; do
    rm -f "$f" && DELETED=$((DELETED + 1)) && echo ">> Rotation: entfernt ${f}"
  done
fi

# ---- Metriken --------------------------------------------------------------
mkdir -p "$STATE_DIR"
printf 'ts=%s action=backup file=%s bytes=%s rotated_out=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OUT" "$SIZE" "$DELETED" \
  >> "${STATE_DIR}/metrics.log"
printf 'ts=%s status=ok file=%s bytes=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OUT" "$SIZE" \
  > "${STATE_DIR}/backup.last"
echo ">> Fertig."
