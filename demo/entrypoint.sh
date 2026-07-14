#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Entrypoint für den sightmetrics-web Container.
# Installiert TYPO3 beim ersten Start (falls nötig) und startet danach den
# PHP-Server. Läuft INNERHALB des Containers – daher keine `docker compose`
# Wrapper, sondern direkte Aufrufe von mariadb/composer/typo3.
# ---------------------------------------------------------------------------
set -euo pipefail

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${MARIADB_DATABASE:-t3}"
DB_USER="${MARIADB_USER:-t3}"
DB_PASSWORD="${MARIADB_PASSWORD:-t3}"

PROJECT_NAME="${PROJECT_NAME:-SightMetrics Demo}"
LIVE_SITE_URL="${LIVE_SITE_URL:-http://localhost:8091/}"

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-SightMetrics-Admin-2026!}"


cd /var/www/html

# Extension per Symlink in packages/ verfügbar machen. Die Quelle wird an einen
# eigenständigen Pfad (/opt/sight_metrics) gemountet, weil ein Bind-Mount direkt
# nach packages/ (also innerhalb des ./app-Mounts) unter Docker Desktop/macOS
# ignoriert würde – siehe docker-compose.yaml. Der Symlink zeigt auf den Mount
# und wird bei jedem Start neu gesetzt (idempotent).
EXT_SRC="${EXT_SRC:-/opt/sight_metrics}"
if [ -d "$EXT_SRC" ]; then
  mkdir -p packages
  rm -rf packages/sight_metrics
  ln -s "$EXT_SRC" packages/sight_metrics
fi

echo -n ">> Warte auf MariaDB"
until mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; do
  echo -n "."; sleep 2
done
echo " OK"

# TYPO3 gilt nur als installiert, wenn sowohl die Dateien (vendor, public)
# ALS AUCH das Datenbank-Schema vorhanden sind – ein frisches DB-Volume mit
# bereits existierenden Dateien würde sonst übersprungen und mit leerem Schema
# laufen (HTTP 500).
SCHEMA_EXISTS=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='be_users';" 2>/dev/null || echo 0)

if [ -f vendor/bin/typo3 ] && [ -f public/index.php ] && [ "$SCHEMA_EXISTS" = "1" ]; then
  echo ">> TYPO3 bereits installiert (Dateien + DB-Schema vorhanden) – überspringe."
else
  echo ">> composer install..."
  composer install --no-interaction

  echo ">> TYPO3-Setup (nicht-interaktiv)..."
  vendor/bin/typo3 setup \
    --driver=mysqli \
    --host="$DB_HOST" --port="$DB_PORT" \
    --dbname="$DB_NAME" --username="$DB_USER" --password="$DB_PASSWORD" \
    --admin-username="$ADMIN_USERNAME" --admin-user-password="$ADMIN_PASSWORD" \
    --admin-email=demo@example.org \
    --project-name="$PROJECT_NAME" \
    --create-site="$LIVE_SITE_URL" \
    --server-type=other \
    --no-interaction --force
fi

# Extension-Quelle ist live gemountet (siehe docker-compose.yml,
# ../extension/sight_metrics -> packages/sight_metrics) – kein Sync/Copy nötig.
# Cache leeren, damit eine frische Erstinstallation sie sofort sieht.
php vendor/bin/typo3 cache:flush >/dev/null 2>&1 || true

echo ">> Starte PHP-Server auf 0.0.0.0:80"
exec php -S 0.0.0.0:80 -t public
