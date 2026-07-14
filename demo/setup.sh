#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time setup of the disposable demo stack. Fetches/generates everything
# not in the repo (deliberately gitignored: large binary files, generated
# installations, license-restricted datasets) and sets up TYPO3 non-interactively.
#
# Afterwards: docker compose up -d   (unless already started by setup)
#
# No separate Apache/nginx needed – the demo web container uses the
# built-in PHP dev server (see docker-compose.yml, command of 'web').
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"

echo "== 1/4: demo/.env =="
if [ ! -f .env ]; then
  cp .env.example .env
  echo ">> demo/.env aus .env.example erstellt (Standard-Passwörter, nur für die Demo)."
else
  echo ">> vorhanden: demo/.env"
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

echo
echo "== 2/4: Beispiel-Log (logs/example_1k.log) =="
if [ ! -f "${REPO}/logs/example_1k.log" ]; then
  echo ">> Erzeuge Beispiel-Log über generate_logs.py..."
  mkdir -p "${REPO}/logs"
  python3 "${REPO}/ingestion/generate_logs.py" --clean -n 1000 --days 14 \
    -o "${REPO}/logs/example_1k.log"
else
  echo ">> vorhanden: logs/example_1k.log"
fi

echo
echo "== 3/4: Geo-IP-Datensatz (ingestion/geo/country-ipv4-num.csv) =="
GEO="${REPO}/ingestion/geo/country-ipv4-num.csv"
if [ ! -f "$GEO" ]; then
  echo ">> Erzeuge SYNTHETISCHE Demo-Geo-CSV (keine echten GeoIP-Daten – nur damit"
  echo "   das Dashboard eine Länderverteilung zeigt). Für den Produktivbetrieb"
  echo "   siehe docs/ingestion-runbook.md §3a (SM_GEO_SOURCE)."
  mkdir -p "${REPO}/ingestion/geo"
  python3 "${REPO}/demo/generate_demo_geo.py" -o "$GEO"
else
  echo ">> vorhanden: ${GEO}"
fi

echo
echo "== 4/4: TYPO3 installieren + Extension deployen =="
echo ">> Starte MariaDB..."
docker compose up -d db
echo -n ">> Warte auf MariaDB"
until [ "$(docker inspect -f '{{.State.Health.Status}}' sightmetrics-db 2>/dev/null)" = "healthy" ]; do
  echo -n "."; sleep 2
done
echo " OK"

# TYPO3 only counts as installed if both the files (app/vendor,
# app/public) AND the database schema are present - a fresh
# DB volume with existing files would otherwise be skipped and run
# with an empty schema (HTTP 500).
SCHEMA_EXISTS=$(docker compose exec -T db mariadb -uroot -p"${MARIADB_ROOT_PASSWORD:-root}" -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='t3' AND table_name='be_users';" 2>/dev/null || echo 0)

if [ -f app/vendor/bin/typo3 ] && [ -f app/public/index.php ] && [ "$SCHEMA_EXISTS" = "1" ]; then
  echo ">> TYPO3 bereits installiert (Dateien + DB-Schema vorhanden) – überspringe."
else
  echo ">> composer install (im web-Container, kein lokales PHP/Composer nötig)..."
  docker compose run --rm --no-deps -w /var/www/html web composer install --no-interaction

  echo ">> TYPO3-Setup (nicht-interaktiv)..."
  docker compose run --rm --no-deps web vendor/bin/typo3 setup \
    --driver=mysqli \
    --host=db --port=3306 \
    --dbname=t3 --username=t3 --password="${MARIADB_T3_PASSWORD:-t3}" \
    --admin-username=admin --admin-user-password='SightMetrics-Admin-2026!' \
    --admin-email=demo@example.org \
    --project-name="SightMetrics Demo" \
    --create-site="http://localhost:8091/" \
    --server-type=other \
    --no-interaction --force
fi

echo ">> Starte kompletten Stack..."
docker compose up -d

# Extension source is bind-mounted live (see docker-compose.yml,
# ../extension/sight_metrics -> packages/sight_metrics) - no sync/copy step
# needed. Just clear the cache so a fresh first install sees it immediately.
docker compose exec -T web php vendor/bin/typo3 cache:flush >/dev/null 2>&1 || true

cat <<EOF

>> Demo-Setup abgeschlossen.
   Backend:  http://localhost:8091/typo3/   (admin / SightMetrics-Admin-2026!)
   Nächster Schritt (Beispiel-Log importieren):
     cd ingestion && ./load_cube.sh ../logs/example_1k.log "Bürgeramt Mitte" 1
EOF
