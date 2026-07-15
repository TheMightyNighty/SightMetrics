#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Contract-Test (Suite 4): Ingestion schreibt -> Extension liest (docs/SCHEMA.md).
# Importiert ingestion/tests/fixture.log als Site 990 (log path) und
# ingestion/tests/matomo_fixture/*.json as Site 991 (Matomo path, from a
# frozen real-Matomo fixture -- no live Matomo needed, see
# ingestion/tests/matomo_fixture/README.md) into the demo MariaDB, then
# prueft die Zahlen anschliessend durch das echte CubeRepository
# (Tests/Functional/CubeContractTest.php, im web-Container).
#
# Voraussetzungen: Docker; ingestion/bin/duckdb (wird bei Bedarf geladen);
# Demo-App mit composer install (typo3/testing-framework) -- siehe demo/setup.sh.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/../.."   # -> Repo-Root
fail=0

echo "== Contract: Demo-MariaDB starten =="
docker compose -f demo/docker-compose.yaml up -d db >/dev/null
until [ "$(docker inspect -f '{{.State.Health.Status}}' sightmetrics-db 2>/dev/null)" = "healthy" ]; do
  sleep 2
done
echo "PASS MariaDB healthy"

if [ ! -x ingestion/bin/duckdb ]; then
  echo ">> DuckDB-Binary fehlt - lade v1.5.4"
  mkdir -p ingestion/bin
  curl -fsSL -o /tmp/duckdb.zip \
    https://github.com/duckdb/duckdb/releases/download/v1.5.4/duckdb_cli-linux-amd64.zip
  unzip -o -q /tmp/duckdb.zip duckdb -d ingestion/bin/
  chmod +x ingestion/bin/duckdb
fi

echo "== Contract: Fixture als Site 990 importieren (erzwungene Heuristiken) =="
docker exec sightmetrics-db mariadb -ucube_rw -pcube_rw analytics \
  -e "DELETE FROM cube WHERE site_id=990; DELETE FROM daily WHERE site_id=990; DELETE FROM meta WHERE site_id=990;" 2>/dev/null || true

STATE_TMP=$(mktemp -d)
if ( cd ingestion && \
     CUBE_DSN="host=127.0.0.1 port=3307 user=cube_rw password=cube_rw database=analytics" \
     STATE_DIR="$STATE_TMP" \
     SM_GEO_PATH=tests/geo_mini.csv \
     SM_COMPLETE_DAYS=0 \
     SM_BOT_RE_PATH=/nonexistent SM_UA_BROWSERS_PATH=/nonexistent SM_UA_OSS_PATH=/nonexistent \
     ./load_cube.sh tests/fixture.log "Contract-Fixture" 990 >/dev/null ); then
  echo "PASS Import (load_cube.sh, Site 990)"
else
  echo "FAIL Import fehlgeschlagen"; exit 1
fi
rm -rf "$STATE_TMP"

echo "== Contract: Matomo fixture as Site 991 (no live Matomo, frozen JSON) =="
docker exec sightmetrics-db mariadb -ucube_rw -pcube_rw analytics \
  -e "DELETE FROM cube WHERE site_id=991; DELETE FROM daily WHERE site_id=991; DELETE FROM meta WHERE site_id=991;" 2>/dev/null || true

# Same DuckDB run matomo_import.sh would do per chunk, minus its HTTP-fetch
# layer -- jsondir points straight at the frozen fixture instead of a live
# Matomo download.
MATOMO_SQL_TMP=$(mktemp)
( cd ingestion && \
  export SM_TABLE_CUBE=cube SM_TABLE_DAILY=daily SM_TABLE_META=meta SM_TABLE_TOPN=topn && \
  cat matomo_to_cube.sql sink_mysql.sql \
    | envsubst '${SM_TABLE_CUBE} ${SM_TABLE_DAILY} ${SM_TABLE_META} ${SM_TABLE_TOPN}' \
    > "$MATOMO_SQL_TMP" )
if ( cd ingestion && ./bin/duckdb <<SQL
INSTALL mysql; LOAD mysql;
ATTACH 'host=127.0.0.1 port=3307 user=cube_rw password=cube_rw database=analytics' AS m (TYPE mysql);
SET VARIABLE jsondir    = 'tests/matomo_fixture';
SET VARIABLE site_id    = '991';
SET VARIABLE site_name  = 'Matomo-Contract-Fixture';
SET VARIABLE range_from = '2026-06-01';
SET VARIABLE range_to   = '2026-06-01';
.read '${MATOMO_SQL_TMP}'
SQL
); then
  echo "PASS Import (matomo_to_cube.sql + sink_mysql.sql, Site 991)"
else
  echo "FAIL Matomo import fehlgeschlagen"; exit 1
fi
rm -f "$MATOMO_SQL_TMP"

echo "== Contract: CubeContractTest (Extension liest via report_ro) =="
if docker exec \
     -e CONTRACT_DB_HOST=db -e CONTRACT_DB_PORT=3306 \
     -e CONTRACT_DB_USER=report_ro -e CONTRACT_DB_PASS=report_ro -e CONTRACT_DB_NAME=analytics \
     sightmetrics-web bash -c "cd /var/www/html && php vendor/bin/phpunit \
       -c vendor/sightmetrics/sight-metrics/phpunit.functional.xml.dist \
       --bootstrap vendor/typo3/testing-framework/Resources/Core/Build/FunctionalTestsBootstrap.php \
       --filter CubeContractTest"; then
  echo "PASS contract: Ingestion-Zahlen kommen identisch durch CubeRepository an"
else
  echo "FAIL contract"; fail=1
fi

exit "$fail"
