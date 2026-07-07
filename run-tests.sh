#!/usr/bin/env bash
# Overall test run: lint + all three suites, aggregated.
set -uo pipefail
cd "$(dirname "$0")"
fail=0
echo "############ Suite 0: Lint (PHPStan + Coding-Standards) ############"
bash extension/lint.sh || fail=1
echo; echo "############ Suite 1: Pipeline (DuckDB) ############"
bash ingestion/tests/run.sh || fail=1
echo; echo "############ Suite 2: Extension (PHP) ############"
bash extension/run-tests.sh || fail=1
echo; echo "############ Suite 3: E2E (Puppeteer) ############"
bash e2e/run.sh || fail=1
echo
if [ "$fail" -eq 0 ]; then echo "==================== ALLE TESTS GRÜN ===================="; else echo "==================== TESTS FEHLGESCHLAGEN ===================="; fi
exit $fail
