.. _known-problems:

==============
Known Problems
==============

Scaling and caching
=====================

**Server-side caching.** The reads whose volume/frequency grows with the time
window or dimension cardinality (`daily()`, `cube()`, `topN()`,
`dimSummary()`) go through the TYPO3 caching framework cache `sight_metrics`
(`VariableFrontend` + `Typo3DatabaseBackend`, registered in
`ext_localconf.php`; the table `cache_sight_metrics` is created by TYPO3
itself via `extension:setup`/database compare). The TTL is controlled by the
extension setting `cacheLifetime` (default 60s, `0` = disabled — every call
then reads live). `sites()`/`meta()` are deliberately left uncached (small,
single rows/lists; a new site or a fresh ingestion run should be visible
without delay). If the cache configuration is missing (e.g. in unit/functional
tests without a loaded `ext_localconf.php`), `CubeRepository::cached()` falls
back gracefully to a live query.

**Cache cleanup is the operator's responsibility.** `Typo3DatabaseBackend`
does **not** delete expired entries on its own — they remain as dead rows in
`cache_sight_metrics` until a garbage collection run happens. Cache keys are
high-cardinality (every combination of period, dimension, offset, and
drill-down parent category produces its own entry with only a 60s TTL), so the
table grows continuously in operation. Two options:

- **With EXT:scheduler:** set up the core task "Caching framework garbage
  collection" (e.g. daily) with the `sight_metrics` cache selected.
- **Without a scheduler (cron/SQL):** delete expired rows directly against the
  TYPO3 database, e.g. daily via cron:

  .. code-block:: sql

     DELETE FROM cache_sight_metrics WHERE expires < UNIX_TIMESTAMP();

  (The associated `cache_sight_metrics_tags` table stays empty — the extension
  does not set cache tags — and needs no cleanup of its own.)

Running `vendor/bin/typo3 cache:flush` also empties the table (a blunt
instrument, but harmless — the cache refills on the next module call).

**Server-side cardinality limiting.** `windowDays` limits only the time axis
(how many days are loaded). For all dimensions with potentially unbounded
distinct values — search keywords, entry/exit pages, downloads, status codes,
HTTP methods, browser, OS, device type, referrer type/name/URL, and their
version/model sub-categories — `CubeRepository::topN()` returns only the
top-N rows server-side (default 8, `TopNDims::DEFAULT_LIMIT`; 10 for referrer
URLs), together with a total sum (`dimSummary()`) for percentage display and
"+ N more". Reloading (date-range changes in the picker, clicking "+ N more",
expanding a drill-down row) goes through the AJAX route
`ajax_sightmetrics_topn`. Drill-down children (e.g. browser versions under
"Chrome") are never preloaded — they are only requested on expansion via a
`parentKey` parameter. Country stays deliberately unbounded (the choropleth
map needs all countries; ISO codes are limited to ~250 values anyway).

The **page tree** (`url` dimension) is limited server-side via its own
scheme: `CubeRepository::urlTree()` segments URL paths in SQL and returns
only the top-8 segments per level, with subtree sums. The initial payload
contains the first two levels; deeper branches and "+ N more" are loaded on
demand via the AJAX route `ajax_sightmetrics_tree`.

Data accuracy limitations
===========================

- **Unique visitors** over multi-day ranges are approximated **additively**
  (the daily unique-visitor counts are summed), not deduplicated across days.
  This can overstate the true number of distinct visitors for longer periods.
- **Sessions crossing midnight (UTC)** are split at the day boundary — a
  visit that starts before and ends after midnight is counted as two
  sessions, one per day.
- **GeoIP data is not bundled** with either package. The operator must supply
  a GeoIP database themselves. By default, only IPv4 lookups are resolved;
  IPv6 addresses are shown as `??` (unknown country) unless an IPv6-capable
  data set is configured.
