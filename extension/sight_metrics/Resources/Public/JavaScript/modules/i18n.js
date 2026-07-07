/* SightMetrics - translations/locale for the dashboard.
   Labels come resolved server-side as a lang map in the payload
   (DashboardController::jsLabels(), source locallang_mod.xlf); without the map, the
   English fallbacks apply (default language of the XLF). */

/**
 * @param {{lang?: Record<string,string>, locale?: string}} data JSON payload (DATA)
 */
export function createI18n(data) {
  const LANG = (data && data.lang) || {};
  const LOC = (data && data.locale) || 'en';

  /** @param {string} key @param {string} fallback */
  function t(key, fallback) { return LANG[key] || fallback; }
  /** @param {string} key @param {string} fallback @param {string|number} arg replaces %s */
  function tf(key, fallback, arg) { return t(key, fallback).replace('%s', String(arg)); }
  /** @param {number|string} n number in the backend user's locale */
  function nf(n) { return Number(n).toLocaleString(LOC); }
  /** @param {number} n value with exactly one decimal place (delta badges) */
  function pct1(n) {
    return Math.abs(n).toLocaleString(LOC, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  }

  // ISO-2 -> country name in the backend user's language (Intl.DisplayNames instead of
  // a static translation list); '??' = country unknown (no GeoIP match/IPv6).
  /** @type {Intl.DisplayNames|null} */
  let regionNames = null;
  try { regionNames = new Intl.DisplayNames([LOC, 'en'], { type: 'region' }); } catch (e) { /* old browsers: show the code */ }
  /** @param {string} c ISO-2 code */
  function landName(c) {
    if (c === '??') return t('unknown', 'Unknown');
    if (regionNames) { try { return regionNames.of(c) || c; } catch (e) { return c; } }
    return c;
  }

  // referrer_type VALUES are German data values from the cube (transform.sql,
  // part of the DB contract) -> map to localized labels for display.
  /** @type {Record<string,string>} */
  const refTypeLabels = {
    'Direkt': t('ref.direct', 'Direct'),
    'Suchmaschine': t('ref.search', 'Search engines'),
    'Soziale Medien': t('ref.social', 'Social media'),
    'Website': t('ref.website', 'Websites'),
  };
  /** @param {string} v raw dimkey value */
  function refTypeLabel(v) { return refTypeLabels[v] || v; }

  return { t, tf, nf, pct1, landName, refTypeLabel, LOC };
}
