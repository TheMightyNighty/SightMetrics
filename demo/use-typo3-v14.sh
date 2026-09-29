#!/usr/bin/env bash
# Stellt die Demo-App auf TYPO3 v14 um (Standard ist v13.4 laut app/composer.lock).
# Genutzt vom E2E-Job der CI (Matrix v13/v14); lokal nur in einem frischen
# Checkout/Worktree ausführen: composer.json wird umgeschrieben und die
# composer.lock entfernt, der Entrypoint löst beim Start dann neu auf.
set -euo pipefail

# Schutz: löscht vendor/, public/ und var/ der Demo-App. Außerhalb der CI nur
# mit --force (z. B. in einem separaten Worktree), nie im Arbeits-Checkout.
if [ "${CI:-}" != "true" ] && [ "${1:-}" != "--force" ]; then
  echo "Nur in der CI oder mit --force in einem frischen Worktree ausführen." >&2
  exit 1
fi

cd "$(dirname "$0")/app"

sed -i -E \
  -e 's#("typo3/cms-[a-z-]+": )"\^13\.4"#\1"^14.0"#' \
  -e 's#("typo3/testing-framework": )"[^"]*"#\1"^9.7"#' \
  -e 's#("typo3/coding-standards": )"[^"]*"#\1"^0.9"#' \
  composer.json
rm -f composer.lock
rm -rf vendor public/_assets public/typo3 var

grep -q '"\^13\.4"' composer.json && { echo "composer.json enthält noch ^13.4" >&2; exit 1; }
echo ">> Demo-App auf TYPO3 ^14.0 umgestellt (composer.lock entfernt)"
