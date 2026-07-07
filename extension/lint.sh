#!/usr/bin/env bash
# Static analysis + code style of the extension (PHPStan + TYPO3 Coding Standards).
# Runs in the demo container (uses its tools + TYPO3 autoloader).
set -uo pipefail
cd "$(dirname "$0")"
P=packages/sight_metrics
fail=0

# Install tools if needed (demo app)
docker exec -w /var/www/html sightmetrics-web sh -c 'test -x vendor/bin/phpstan && test -x vendor/bin/php-cs-fixer && test -f vendor/phpstan/phpstan-strict-rules/rules.neon' \
  || docker exec -w /var/www/html sightmetrics-web composer require --dev --no-interaction --no-progress \
       phpstan/phpstan phpstan/phpstan-strict-rules "typo3/coding-standards:^0.8" >/dev/null 2>&1

echo "== PHPStan =="
# --memory-limit: PHPStan runs out with the PHP default (128M) during parallel analysis
docker exec -w /var/www/html sightmetrics-web vendor/bin/phpstan analyse -c $P/phpstan.neon --no-progress --memory-limit=512M || fail=1
echo; echo "== php-cs-fixer (dry-run) =="
docker exec -w /var/www/html sightmetrics-web vendor/bin/php-cs-fixer fix --dry-run --diff --config=$P/.php-cs-fixer.dist.php 2>&1 | tail -40 || fail=1
exit $fail
