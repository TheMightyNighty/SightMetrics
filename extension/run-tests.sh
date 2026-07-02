#!/usr/bin/env bash
# Suite 2: PHP-Tests der Extension.
#   2a) Unit (PHPUnit-Phar, kein TYPO3 nötig)
#   2b) Functional (typo3/testing-framework, SQLite, Demo läuft)
#   2c) Smoke (TYPO3-CLI gegen echte Cube-DB, Demo läuft)
set -uo pipefail
cd "$(dirname "$0")"          # extension/
EXT="$(pwd)/sight_metrics"
DEMO="$(cd ../demo && pwd)"
PHAR="/tmp/phpunit-11.phar"
fail=0

echo "== 2a: PHP Unit (PHPUnit) =="
[ -f "$PHAR" ] || curl -fsSL -o "$PHAR" https://phar.phpunit.de/phpunit-11.phar
docker compose -f "$DEMO/docker-compose.yml" run --rm --no-deps \
  -v "$EXT:/ext:ro" -v "$PHAR:/phpunit.phar:ro" web \
  php /phpunit.phar -c /ext/phpunit.xml.dist || fail=1

echo; echo "== 2b: PHP Functional (typo3/testing-framework, SQLite) =="
bash ./sync-to-demo.sh >/dev/null 2>&1
# Prüfen ob testing-framework installiert ist (erst nach: composer update in demo/app/)
if docker exec sightmetrics-web test -f /var/www/html/vendor/typo3/testing-framework/Resources/Core/Build/FunctionalTestsBootstrap.php; then
  docker exec sightmetrics-web bash -c \
    "cd /var/www/html && php vendor/bin/phpunit \
      -c packages/sight_metrics/phpunit.functional.xml.dist \
      --bootstrap vendor/typo3/testing-framework/Resources/Core/Build/FunctionalTestsBootstrap.php" \
    || fail=1
else
  echo "SKIP typo3/testing-framework nicht installiert."
  echo "     → docker exec sightmetrics-web composer update --no-interaction"
fi

echo; echo "== 2c: PHP Smoke (TYPO3 CLI, read-only Cube) =="
docker exec sightmetrics-web php /var/www/html/vendor/bin/typo3 sightmetrics:smoke || fail=1

exit $fail
