# ---------------------------------------------------------------------------
# Shared geo source selection (sourced by load_cube.sh + fetch_loki_logs.sh).
# Expects: caller is already in the ingestion/ directory (pwd).
# Sets: GEO, GEO_LOC, GEO_SOURCE_SQL. Aborts with a TODO hint if the
# GeoIP file is missing (deliberately not part of the repo, see
# docs/ingestion-runbook.md §3a).
#
# ENV: SM_GEO_SOURCE (native|ip2location|dbip|maxmind, default native),
#      SM_GEO_PATH, SM_GEO_LOC_PATH (maxmind only)
# ---------------------------------------------------------------------------
SM_GEO_SOURCE="${SM_GEO_SOURCE:-native}"
case "$SM_GEO_SOURCE" in
  native|ip2location|dbip|maxmind) ;;
  *)
    echo "Fehler: unbekanntes SM_GEO_SOURCE='${SM_GEO_SOURCE}'." >&2
    echo "        Gültig: native (Standard), ip2location, dbip, maxmind" >&2
    exit 1
    ;;
esac
GEO_SOURCE_SQL="$(pwd)/geo_sources/${SM_GEO_SOURCE}.sql"
GEO="${SM_GEO_PATH:-$(pwd)/geo/country-ipv4-num.csv}"
GEO_LOC="${SM_GEO_LOC_PATH:-$(pwd)/geo/GeoLite2-Country-Locations-en.csv}"
if [ ! -f "$GEO" ]; then
  echo "Fehler: Geo-Datensatz fehlt unter '${GEO}'." >&2
  echo "        TODO: Datei selbst beschaffen und ablegen (siehe" >&2
  echo "        docs/ingestion-runbook.md -> Abschnitt 'GeoIP-Datensatz')." >&2
  exit 1
fi
if [ "$SM_GEO_SOURCE" = "maxmind" ] && [ ! -f "$GEO_LOC" ]; then
  echo "Fehler: MaxMind-Locations-Datei fehlt unter '${GEO_LOC}'." >&2
  echo "        TODO: GeoLite2-Country-Locations-en.csv ablegen (siehe" >&2
  echo "        docs/ingestion-runbook.md -> Abschnitt 'GeoIP-Datensatz')." >&2
  exit 1
fi
echo ">> Geo-Quelle: ${SM_GEO_SOURCE} (${GEO})"

# ---- Optional IPv6 geo data (SM_GEO6_PATH) ----------------------------------
# Textual ranges start_ip,end_ip,cc (native v6 format or the DB-IP CSV, which
# carries IPv4+IPv6 in one file). When present, GEO6_SQL loads
# geo_sources/v6_ranges.sql (DuckDB inet extension) and IPv6 visitors get a
# country; without it they stay '??'. See runbook §3a.
GEO6="${SM_GEO6_PATH:-}"
GEO6_SQL=""
if [ -n "$GEO6" ] && [ -f "$GEO6" ]; then
  GEO6_SQL="SET VARIABLE geo6path = '${GEO6//\'/\'\'}';
.read '$(pwd)/geo_sources/v6_ranges.sql'"
  echo ">> Geo-Quelle IPv6: ${GEO6}"
fi
