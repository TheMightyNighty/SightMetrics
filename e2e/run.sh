#!/usr/bin/env bash
# E2E-Test (Suite 3): Login -> Backend-Modul -> Assertions (KPIs/Barlisten/Drill/Karte).
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules/puppeteer-core ] || npm i --no-audit --no-fund >/dev/null 2>&1
exec node e2e.js
