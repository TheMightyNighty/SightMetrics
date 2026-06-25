#!/usr/bin/env bash
# Deployt die Extension-Quelle (Paket B) in das Wegwerf-TYPO3 (demo/app/packages)
# und leert den Cache. demo/app/packages/sight_metrics ist nur der Deploy-Abzug.
set -euo pipefail
cd "$(dirname "$0")"
EXT="$(pwd)/sight_metrics"
DEMO="$(cd ../demo && pwd)"
docker compose -f "$DEMO/docker-compose.yml" run --rm --no-deps -v "$EXT:/src:ro" web bash -c '
  find /var/www/html/packages/sight_metrics -mindepth 1 -delete &&
  cp -a /src/. /var/www/html/packages/sight_metrics/ &&
  php /var/www/html/vendor/bin/typo3 cache:flush >/dev/null 2>&1 &&
  echo ">> Extension synchronisiert + Cache geleert"'
