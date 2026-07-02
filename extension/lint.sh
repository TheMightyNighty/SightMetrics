#!/usr/bin/env bash
# Static Analysis + Code-Style der Extension (PHPStan + TYPO3 Coding Standards).
# Laeuft im Demo-Container (nutzt dessen Tools + TYPO3-Autoloader).
set -uo pipefail
cd "$(dirname "$0")"
bash ./sync-to-demo.sh >/dev/null 2>&1
P=packages/sight_metrics
fail=0

# Tools bei Bedarf nachinstallieren (Demo-App)
docker exec -w /var/www/html sightmetrics-web sh -c 'test -x vendor/bin/phpstan && test -x vendor/bin/php-cs-fixer' \
  || docker exec -w /var/www/html sightmetrics-web composer require --dev --no-interaction --no-progress \
       phpstan/phpstan "typo3/coding-standards:^0.8" >/dev/null 2>&1

echo "== PHPStan =="
docker exec -w /var/www/html sightmetrics-web vendor/bin/phpstan analyse -c $P/phpstan.neon --no-progress || fail=1
echo; echo "== php-cs-fixer (dry-run) =="
docker exec -w /var/www/html sightmetrics-web vendor/bin/php-cs-fixer fix --dry-run --diff --config=$P/.php-cs-fixer.dist.php 2>&1 | tail -40 || fail=1
exit $fail
