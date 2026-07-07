/* SightMetrics - CSV export of the dashboard.
   Deliberately mirrors the currently LOADED state (Top-N + lazy-loaded, page tree
   subset), no completeness request on export. */

import { csvRow, inR, lastSeg, slug, SEP } from './util.js';

/**
 * @param {{
 *   i18n: ReturnType<import('./i18n.js').createI18n>,
 *   META: Record<string, any>,
 *   DAILY: Array<{datum: string, visits: number, pageviews: number, uniques: number, bounces: number, bytes: number}>,
 *   TOPN: Record<string, {rows: Array<{dimkey: string, pv: number, v: number}>}>,
 *   TOPN_ROOT: Record<string, unknown>,
 *   TREE: {rows: Array<any>},
 *   agg: (dim: string, a: string, b: string, metric: string) => Array<{key: string, pv: number, v: number}>,
 * }} ctx
 */
export function createCsvExport(ctx) {
  const { i18n, META, DAILY, TOPN, TOPN_ROOT, TREE, agg } = ctx;
  const t = i18n.t, tf = i18n.tf;

  // Dimensions for the export (cube key -> readable heading + metric
  // + optional display mapper for raw values).
  /** @type {Array<[string, string, 'pv'|'v', ((v: string) => string)?]>} */
  const EXPORT_DIMS = [
    ['country', t('dim.country', 'Countries'), 'v', i18n.landName],
    ['browser', t('dim.browser', 'Browsers'), 'v'], ['os', t('dim.os', 'Operating systems'), 'v'],
    ['device', t('dim.device', 'Device types'), 'v'],
    ['referrer_type', t('dim.refTypes', 'Referrer types'), 'v', i18n.refTypeLabel],
    ['referrer_url', t('dim.refUrls', 'Referrer URLs'), 'v'],
    ['keyword', t('dim.keywords', 'Search keywords'), 'v'], ['entry', t('dim.entry', 'Entry pages'), 'v'],
    ['exit', t('dim.exit', 'Exit pages'), 'v'], ['download', t('dim.downloads', 'Downloads'), 'pv'],
    ['status', t('dim.status', 'Status codes'), 'pv'],
    ['method', t('dim.methods', 'HTTP methods'), 'pv'], ['hour', t('dim.hours', 'Visiting hours (hour of day)'), 'pv'],
  ];

  /** @param {string} a @param {string} b ISO time range */
  function buildCsv(a, b) {
    const L = [], days = DAILY.filter(function (d) { return inR(d.datum, a, b); });
    L.push(csvRow(['SightMetrics-Export']));
    L.push(csvRow([t('csv.website', 'Website'), META.site || '']));
    L.push(csvRow([t('csv.period', 'Period'), a, t('csv.to', 'to'), b]));
    L.push(csvRow([tf('asOf', 'As of: %s', '').replace(/[:\s]+$/, ''), META.erzeugt || '']));
    L.push('');
    L.push(csvRow([t('csv.daily', 'Trend (daily)')]));
    L.push(csvRow([t('csv.date', 'Date'), t('visits', 'Visits'), t('pageviews', 'Page views'),
                   t('uniques', 'Unique visitors'), t('csv.bounces', 'Bounces'), t('csv.bytes', 'Bytes')]));
    days.forEach(function (d) { L.push(csvRow([d.datum, d.visits, d.pageviews, d.uniques, d.bounces, d.bytes])); });

    EXPORT_DIMS.forEach(function (dd) {
      // Top-N dims: only the loaded subset (see header comment); expanded
      // child lists (browser version etc.) are not included -- only the root level.
      const governed = Object.prototype.hasOwnProperty.call(TOPN_ROOT, dd[0]);
      let rows = governed
        ? TOPN[dd[0]].rows.map(function (r) { return { key: r.dimkey, pv: r.pv, v: r.v }; })
        : agg(dd[0], a, b, dd[2]);
      rows = rows.filter(function (r) { return r.key != null && r.key !== ''; });
      if (!rows.length) return;
      const label = dd[3] || function (/** @type {string} */ x) { return x; };
      L.push('');
      const mVisits = t('visits', 'Visits'), mPv = t('pageviews', 'Page views');
      let title = dd[1] + ' (' + (dd[2] === 'v' ? mVisits : mPv) + ')';
      if (governed) title += ' ' + t('csv.partial', '– loaded subset only, see "+ N more" in the dashboard');
      L.push(csvRow([title]));
      L.push(csvRow([t('csv.value', 'Value'), dd[2] === 'v' ? mVisits : mPv, mPv, mVisits]));
      rows.forEach(function (r) { L.push(csvRow([label(r.key.split(SEP).join(' › ')), r[dd[2]], r.pv, r.v])); });
    });

    // Page tree: recursive dump of the currently loaded state (full paths with
    // subtree totals including the page itself).
    if (TREE.rows.length) {
      L.push('');
      L.push(csvRow([t('csv.pages', 'Pages (subtree totals) – loaded subset only, see page tree in the dashboard')]));
      L.push(csvRow([t('csv.path', 'Path'), t('pageviews', 'Page views'), t('visits', 'Visits')]));
      (function dumpTree(/** @type {Array<any>} */ rows) {
        rows.forEach(function (r) {
          L.push(csvRow([r.path, r.pv, r.v]));
          if (r.children) dumpTree(r.children);
        });
      })(TREE.rows);
    }
    return L.join('\r\n');
  }

  /** @param {string} name @param {string} text */
  function downloadFile(name, text) {
    const blob = new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' }); // BOM for Excel
    const url = URL.createObjectURL(blob), a = document.createElement('a');
    a.href = url; a.download = name; document.body.appendChild(a); a.click();
    document.body.removeChild(a); setTimeout(function () { URL.revokeObjectURL(url); }, 0);
  }

  /** @param {string} a @param {string} b ISO time range */
  function exportCsv(a, b) {
    downloadFile('sightmetrics_' + slug(META.site) + '_' + a + '_' + b + '.csv', buildCsv(a, b));
  }

  return { exportCsv, buildCsv };
}
