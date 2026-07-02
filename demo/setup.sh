#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Einmaliges Setup des Wegwerf-Demo-Stacks. Holt/erzeugt alles, was nicht im
# Repo liegt (bewusst gitignored: große Binärdateien, generierte Installationen,
# lizenzpflichtige Datensätze) und richtet TYPO3 nicht-interaktiv ein.
#
# Danach: docker compose up -d   (falls nicht schon vom Setup gestartet)
#
# Kein separater Apache/nginx nötig – der Demo-web-Container nutzt den
# eingebauten PHP-Dev-Server (siehe docker-compose.yml, Kommando von 'web').
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"

echo "== 1/5: demo/.env =="
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
echo "== 2/5: DuckDB-CLI-Binary (ingestion/bin/duckdb) =="
DUCKDB_BIN="${REPO}/ingestion/bin/duckdb"
if [ ! -f "$DUCKDB_BIN" ]; then
  echo ">> Lade DuckDB CLI v1.5.4 (linux-amd64) von GitHub Releases..."
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' RETURN
  curl -fsSL -o "${TMP}/duckdb.zip" \
    "https://github.com/duckdb/duckdb/releases/download/v1.5.4/duckdb_cli-linux-amd64.zip"
  mkdir -p "${REPO}/ingestion/bin"
  unzip -o -q "${TMP}/duckdb.zip" -d "${REPO}/ingestion/bin"
  chmod +x "$DUCKDB_BIN"
  rm -rf "$TMP"
  trap - RETURN
else
  echo ">> vorhanden: ${DUCKDB_BIN}"
fi

echo
echo "== 3/5: Beispiel-Log (logs/example_1k.log) =="
if [ ! -f "${REPO}/logs/example_1k.log" ]; then
  echo ">> Erzeuge Beispiel-Log über generate_logs.py..."
  mkdir -p "${REPO}/logs"
  python3 "${REPO}/ingestion/generate_logs.py" --clean -n 1000 --days 14 \
    -o "${REPO}/logs/example_1k.log"
else
  echo ">> vorhanden: logs/example_1k.log"
fi

echo
echo "== 4/5: Geo-IP-Datensatz (ingestion/geo/country-ipv4-num.csv) =="
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
echo "== 5/5: TYPO3 installieren + Extension deployen =="
if [ -f app/vendor/bin/typo3 ] && [ -f app/public/index.php ]; then
  echo ">> TYPO3 bereits installiert (app/vendor + app/public vorhanden) – überspringe."
else
  echo ">> Starte MariaDB..."
  docker compose up -d db
  echo -n ">> Warte auf MariaDB"
  until [ "$(docker inspect -f '{{.State.Health.Status}}' weg3-db 2>/dev/null)" = "healthy" ]; do
    echo -n "."; sleep 2
  done
  echo " OK"

  echo ">> composer install (im web-Container, kein lokales PHP/Composer nötig)..."
  docker compose run --rm --no-deps -w /var/www/html web composer install --no-interaction

  echo ">> TYPO3-Setup (nicht-interaktiv)..."
  docker compose run --rm --no-deps web vendor/bin/typo3 setup \
    --driver=mysqli \
    --host=db --port=3306 \
    --dbname=t3 --username=t3 --password="${MARIADB_T3_PASSWORD:-t3}" \
    --admin-username=admin --admin-user-password='Weg3-Admin-2026!' \
    --admin-email=demo@example.org \
    --project-name="SightMetrics Demo" \
    --create-site="http://localhost:8091/" \
    --server-type=other \
    --no-interaction --force
fi

echo ">> Starte kompletten Stack..."
docker compose up -d

echo ">> Deploye Extension (sight_metrics) ins Demo-TYPO3..."
"${REPO}/extension/sync-to-demo.sh"

cat <<EOF

>> Demo-Setup abgeschlossen.
   Backend:  http://localhost:8091/typo3/   (admin / Weg3-Admin-2026!)
   Nächster Schritt (Beispiel-Log importieren):
     cd ingestion && ./load_cube.sh ../logs/example_1k.log "Bürgeramt Mitte" 1
EOF
