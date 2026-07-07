/* SightMetrics – Uebersetzungen/Locale fuers Dashboard.
   Labels kommen serverseitig aufgeloest als lang-Map im Payload mit
   (DashboardController::jsLabels(), Quelle locallang_mod.xlf); ohne Map greifen
   die englischen Fallbacks (Default-Sprache der XLF). */

/**
 * @param {{lang?: Record<string,string>, locale?: string}} data JSON-Payload (DATA)
 */
export function createI18n(data) {
  const LANG = (data && data.lang) || {};
  const LOC = (data && data.locale) || 'en';

  /** @param {string} key @param {string} fallback */
  function t(key, fallback) { return LANG[key] || fallback; }
  /** @param {string} key @param {string} fallback @param {string|number} arg ersetzt %s */
  function tf(key, fallback, arg) { return t(key, fallback).replace('%s', String(arg)); }
  /** @param {number|string} n Zahl im Locale des BE-Benutzers */
  function nf(n) { return Number(n).toLocaleString(LOC); }
  /** @param {number} n Betrag mit genau einer Nachkommastelle (Delta-Badges) */
  function pct1(n) {
    return Math.abs(n).toLocaleString(LOC, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  }

  // ISO-2 -> Laendername in der Sprache des BE-Benutzers (Intl.DisplayNames statt
  // statischer Uebersetzungsliste); '??' = Land unbekannt (kein GeoIP-Treffer/IPv6).
  /** @type {Intl.DisplayNames|null} */
  let regionNames = null;
  try { regionNames = new Intl.DisplayNames([LOC, 'en'], { type: 'region' }); } catch (e) { /* alte Browser: Code anzeigen */ }
  /** @param {string} c ISO-2-Code */
  function landName(c) {
    if (c === '??') return t('unknown', 'Unknown');
    if (regionNames) { try { return regionNames.of(c) || c; } catch (e) { return c; } }
    return c;
  }

  // referrer_type-WERTE sind deutsche Datenwerte aus dem Cube (transform.sql,
  // Teil des DB-Vertrags) -> fuer die Anzeige auf lokalisierte Labels mappen.
  /** @type {Record<string,string>} */
  const refTypeLabels = {
    'Direkt': t('ref.direct', 'Direct'),
    'Suchmaschine': t('ref.search', 'Search engines'),
    'Soziale Medien': t('ref.social', 'Social media'),
    'Website': t('ref.website', 'Websites'),
  };
  /** @param {string} v roher dimkey-Wert */
  function refTypeLabel(v) { return refTypeLabels[v] || v; }

  return { t, tf, nf, pct1, landName, refTypeLabel, LOC };
}
