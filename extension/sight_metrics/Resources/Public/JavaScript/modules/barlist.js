/* SightMetrics – bar list building blocks: single row element and the simple
   (client-side aggregated) list renderer, used by the country panel and as
   row primitive by the Top-N lists. */

import { esc } from './util.js';

/**
 * Builds one bar list row.
 * @param {any} ctx dashboard context (createContext())
 * @param {string} label
 * @param {number} val
 * @param {number} total percentage base
 * @param {number} max largest value (bar width base)
 * @param {(s: string) => string} fmt label formatter (escaping included)
 * @param {boolean} drillable
 */
export function rowEl(ctx, label, val, total, max, fmt, drillable) {
  const pct = 100 * val / total, w = Math.max(2, 100 * val / max);
  const row = document.createElement('div'); row.className = 'bl-row' + (drillable ? ' bl-drill' : '');
  row.innerHTML = '<div class="bl-label" title="' + esc(label) + '"'
    + (drillable ? ' role="button" tabindex="0" aria-expanded="false"' : '') + '>'
    + '<span class="bl-bar" style="width:' + w.toFixed(1) + '%"></span>'
    + '<span class="bl-text">' + (drillable ? '<span class="bl-tog" aria-hidden="true">▸</span> ' : '') + fmt(label) + '</span></div>'
    + '<div class="bl-val">' + ctx.i18n.nf(val) + '</div><div class="bl-pct">' + pct.toFixed(1) + '%</div>';
  return row;
}

/**
 * Renders a plain (non-drillable, client-side aggregated) bar list – only the
 * country panel still uses this; everything else is server-side Top-N.
 * @param {any} ctx
 * @param {string} id container element id
 * @param {string} dim cube dimension
 * @param {string} a @param {string} b ISO range
 * @param {'pv'|'v'} metric
 * @param {{fmt?: (s: string) => string, limit?: number}} [opts]
 */
export function renderBarlist(ctx, id, dim, a, b, metric, opts) {
  opts = opts || {};
  const cont = ctx.$(id); if (!cont) return;
  cont.innerHTML = '';
  const t = ctx.i18n.t, tf = ctx.i18n.tf, nf = ctx.i18n.nf;
  const rows = ctx.agg(dim, a, b, metric);
  const fmt = opts.fmt || esc, limit = opts.limit || 8;
  const total = rows.reduce(function (/** @type {number} */ s, /** @type {any} */ r) { return s + r[metric]; }, 0) || 1;
  const top = rows.slice(0, limit), max = top.length ? top[0][metric] : 1;
  top.forEach(function (/** @type {any} */ r) {
    cont.appendChild(rowEl(ctx, r.key, r[metric], total, max, fmt, false));
  });
  if (rows.length > limit) {
    const m = document.createElement('div'); m.className = 'bl-more';
    m.textContent = tf('more', '+ %s more', nf(rows.length - limit));
    cont.appendChild(m);
  }
  if (!top.length) cont.innerHTML = '<div class="bl-more">' + esc(t('noData', 'no data')) + '</div>';
}
