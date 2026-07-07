#!/usr/bin/env bash
# E2E test (suite 3): login -> backend module -> assertions (KPIs/bar lists/drill/map).
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules/puppeteer-core ] || npm i --no-audit --no-fund >/dev/null 2>&1
exec node e2e.js
