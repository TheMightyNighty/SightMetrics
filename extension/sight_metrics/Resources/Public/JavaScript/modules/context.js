/* SightMetrics – shared dashboard context: parses the CSP-safe JSON data
   block, prepares the data series and exposes the helpers every feature
   module needs. All state that crosses module boundaries lives here. */

import { inR } from './util.js';
import { createI18n } from './i18n.js';

/**
 * @returns {null | {
 *   DATA: any, META: any,
 *   DAILY: Array<{datum: string, visits: number, pageviews: number, uniques: number, bounces: number, bytes: number}>,
 *   CUBE: Array<{datum: string, dim: string, key: string, pv: number, v: number}>,
 *   WIN: {von: string, bis: string},
 *   i18n: ReturnType<typeof createI18n>,
 *   $: (id: string) => any,
 *   agg: (dim: string, a: string, b: string, metric: string) => Array<{key: string, pv: number, v: number}>,
 *   dailySum: (a: string, b: string, k: string) => number,
 *   fetchJson: (baseUrl: string|null, params: Record<string, string>) => Promise<any>,
 * }}
 */
export function createContext() {
  let DATA = null;
  const el0 = document.getElementById('sm-data');
  try { DATA = el0 ? JSON.parse(el0.textContent || '') : (window.SM_DATA || null); }
  catch (e) { DATA = window.SM_DATA || null; }
  if (!DATA) return null;

  const i18n = createI18n(DATA);
  const META = DATA.meta || {};
  const DAILY = (DATA.daily || []).map(function (/** @type {any} */ d) {
    return { datum: d.datum, visits: +d.visits || 0, pageviews: +d.pageviews || 0,
             uniques: +d.uniques || 0, bounces: +d.bounces || 0, bytes: +d.bytes || 0 };
  });
  const CUBE = (DATA.cube || []).map(function (/** @type {any} */ r) {
    return { datum: r.datum, dim: r.dim, key: r.dimkey, pv: +r.pv || 0, v: +r.v || 0 };
  });
  // Server-side loaded time window (limits transfer volume; the picker spans
  // the whole dataset and reloads when leaving this window).
  const WIN = DATA.window || { von: META.von, bis: META.bis };

  /** DOM shorthand; deliberately 'any' (returns input/canvas/select depending on id).
      @type {(id: string) => any} */
  const $ = function (id) { return document.getElementById(id); };

  /** Aggregates the full-payload cube rows of one dimension over [a,b]. */
  function agg(/** @type {string} */ dim, /** @type {string} */ a, /** @type {string} */ b, /** @type {string} */ metric) {
    /** @type {Record<string, {key: string, pv: number, v: number}>} */
    const map = {};
    for (let i = 0; i < CUBE.length; i++) {
      const r = CUBE[i];
      if (r.dim !== dim || !inR(r.datum, a, b) || r.key == null || r.key === '') continue;
      if (!map[r.key]) map[r.key] = { key: r.key, pv: 0, v: 0 };
      map[r.key].pv += r.pv; map[r.key].v += r.v;
    }
    return Object.keys(map).map(function (k) { return map[k]; })
      .sort(function (x, y) { return y[metric] - x[metric]; });
  }

  function dailySum(/** @type {string} */ a, /** @type {string} */ b, /** @type {string} */ k) {
    return DAILY.reduce(function (/** @type {number} */ s, /** @type {any} */ d) { return inR(d.datum, a, b) ? s + d[k] : s; }, 0);
  }

  /** Ajax helper for the Top-N/tree endpoints: appends the site id, rejects on
      HTTP errors, resolves the JSON body. */
  function fetchJson(/** @type {string|null} */ baseUrl, /** @type {Record<string, string>} */ params) {
    if (!baseUrl) return Promise.resolve(null);
    const u = new URL(baseUrl, location.href);
    Object.keys(params).forEach(function (k) { u.searchParams.set(k, params[k]); });
    if (DATA.siteId) u.searchParams.set('site', String(DATA.siteId));
    return fetch(u.toString(), { credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  return { DATA, META, DAILY, CUBE, WIN, i18n, $, agg, dailySum, fetchJson };
}
