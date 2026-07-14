#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Builds the browser/OS detection lists from matomo/device-detector
# (regexes/client/browsers.yml + regexes/oss.yml).
#
# Result: TSV files (priority, regex, name, version template) ->
#   ua/browsers.tsv and ua/oss.tsv. ua_lookup.sql matches them in order
# (first match wins, like the device-detector engine) against the distinct
# user agents of an import batch -- browser/OS detection then matches Matomo
# instead of the built-in LIKE heuristic.
#
# License note: the patterns come from matomo/device-detector (LGPL-3.0-or-
# later, https://github.com/matomo-org/device-detector). Like the bot list
# and GeoIP data they are therefore NOT shipped in the repo/image -- the
# operator generates them (rebuild e.g. quarterly).
#
# Usage:  ./tools/fetch_ua_lists.sh
#   ENV: UA_YML_BASE_URL  source base URL (default: device-detector master)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."   # -> ingestion/
BASE="${UA_YML_BASE_URL:-https://raw.githubusercontent.com/matomo-org/device-detector/master/regexes}"
# DuckDB-Binary: $DUCKDB-Override, sonst lokal gepinnt (Host/Tests: ./bin/duckdb),
# sonst aus PATH (Container: /usr/local/bin/duckdb).
if [ -z "${DUCKDB:-}" ]; then
  if [ -x bin/duckdb ]; then DUCKDB="$(pwd)/bin/duckdb"; else DUCKDB=duckdb; fi
fi
mkdir -p ua

build_list() { # $1=yml-url  $2=out.tsv  $3=label
  local url="$1" out="$2" label="$3"
  local tmp_yml tmp_raw
  tmp_yml=$(mktemp); tmp_raw=$(mktemp)
  echo ">> Lade ${url}"
  curl -fsSL -o "$tmp_yml" "$url"

  # Extract ordered top-level entries (regex/name/version); nested blocks
  # (engine:, versions:) are skipped. RE2-incompatible constructs are dropped.
  python3 - "$tmp_yml" > "$tmp_raw" <<'PY'
import re, sys
def unquote(v):
    v = v.strip()
    if v.startswith("'") and v.endswith("'"):
        return v[1:-1].replace("''", "'")
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1].replace('\\"', '"')
    return v
entries, cur, dropped = [], None, 0
for line in open(sys.argv[1], encoding='utf-8'):
    if line.startswith('- regex:'):
        if cur and cur.get('regex') and cur.get('name'):
            entries.append(cur)
        cur = {'regex': unquote(line[len('- regex:'):]), 'name': '', 'version': ''}
    elif cur is not None and re.match(r'^  name:', line):
        cur['name'] = unquote(line[len('  name:'):])
    elif cur is not None and re.match(r'^  version:', line):
        cur['version'] = unquote(line[len('  version:'):])
if cur and cur.get('regex') and cur.get('name'):
    entries.append(cur)
kept = stripped = 0
for i, e in enumerate(entries):
    r = e['regex']
    # Simple negative lookaheads (?!...) without nested groups: strip instead of
    # drop -- first-match-wins ordering plus the boundary wrapper keeps the
    # semantics close enough (e.g. 'Chrome(?!book)'), and dropping would lose
    # flagship browsers entirely.
    r2 = re.sub(r"\(\?![^()]*\)", "", r)
    if r2 != r:
        stripped += 1
        r = r2
        e['regex'] = r
    if re.search(r"\(\?<[=!]|\(\?=|\(\?!|\(\?>|[*+?][+]|\\[1-9]", r):
        dropped += 1
        continue
    if '\t' in r or '\t' in e['name'] or '\t' in e['version']:
        dropped += 1
        continue
    kept += 1
    print(f"{i}\t{r}\t{e['name']}\t{e['version']}")
print(f">> {kept} Muster uebernommen ({stripped} Lookaheads gestrippt), {dropped} RE2-inkompatible verworfen", file=sys.stderr)
PY

  # Validate each pattern individually in DuckDB (RE2), including the
  # device-detector engine wrapper used by ua_lookup.sql.
  {
    echo -e "# Quelle: ${url}"
    echo -e "# Erzeugt: $(date -u +%Y-%m-%dT%H:%M:%SZ) von tools/fetch_ua_lists.sh"
    echo -e "# Lizenz der Muster: LGPL-3.0-or-later (matomo/device-detector)"
  } > "$out"
  local ok=0 bad=0
  while IFS=$'\t' read -r prio pat name ver; do
    wrapped="(?i)(?:^|[^A-Z0-9_-]|[^A-Z0-9-]_|sprd-|MZ-)(?:${pat})"
    if printf 'SELECT regexp_matches(%s, %s);\n' "'probe'" "'${wrapped//\'/\'\'}'" | "$DUCKDB" >/dev/null 2>&1; then
      printf '%s\t%s\t%s\t%s\n' "$prio" "$pat" "$name" "$ver" >> "$out"; ok=$((ok+1))
    else
      bad=$((bad+1))
    fi
  done < "$tmp_raw"
  rm -f "$tmp_yml" "$tmp_raw"
  echo ">> ${label}: ${ok} Muster validiert, ${bad} verworfen -> ${out}"
}

build_list "${BASE}/client/browsers.yml" "ua/browsers.tsv" "Browser"
build_list "${BASE}/oss.yml"             "ua/oss.tsv"      "Betriebssysteme"
echo ">> Aktivierung: Dateien liegen am Standardpfad (ua/) oder SM_UA_BROWSERS_PATH/SM_UA_OSS_PATH setzen."
