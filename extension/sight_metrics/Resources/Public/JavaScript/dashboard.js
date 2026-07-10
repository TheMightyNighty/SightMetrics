/* SightMetrics – TYPO3 backend module entry (native ES module, loaded via
   Configuration/JavaScriptModules.php). Wires the feature modules together and
   orchestrates render(); everything specific lives in modules/*. Chart.js,
   Leaflet and world.js remain classic global vendor scripts. */
import { esc, fmtBytes, inR } from './modules/util.js';
import { createContext } from './modules/context.js';
import { createCharts, isDark } from './modules/charts.js';
import { createMap } from './modules/map.js';
import { createTopN, TOPN_ROOT } from './modules/topn.js';
import { createTree } from './modules/tree.js';
import { renderBarlist } from './modules/barlist.js';
import { createCsvExport } from './modules/export.js';
import { initPresets } from './modules/presets.js';

(function () {
  'use strict';
  const ctx = createContext();
  if (!ctx) return;
  const { DATA, META, DAILY, i18n, $ } = ctx;
  const t = i18n.t, tf = i18n.tf, nf = i18n.nf, landName = i18n.landName;

  const charts = createCharts(ctx);
  const map = createMap(ctx);
  const topN = createTopN(ctx);
  const tree = createTree(ctx);
  const csvExport = createCsvExport({
    i18n: i18n, META: META, DAILY: DAILY,
    TOPN: topN.TOPN, TOPN_ROOT: TOPN_ROOT, TREE: tree.state, agg: ctx.agg,
  });

  function render() {
    const a = $('w-from').value, b = $('w-to').value;
    const days = DAILY.filter(function (d) { return inR(d.datum, a, b); });
    const sum = function (k) { return days.reduce(function (s, d) { return s + d[k]; }, 0); };
    const visits = sum('visits'), bounces = sum('bounces'), full = (a <= META.von && b >= META.bis);
    const bounceRate = visits ? 100 * bounces / visits : 0;
    $('k-visits').textContent = nf(visits);
    $('k-uniq').textContent = (full ? '' : '~') + nf(full ? (META.uniques_total || sum('uniques')) : sum('uniques'));
    $('k-pv').textContent = nf(sum('pageviews'));
    $('k-bounce').textContent = visits ? bounceRate.toFixed(1) + ' %' : '–';
    $('k-band').textContent = fmtBytes(sum('bytes'));

    // Period comparison: deltas against the immediately preceding period of the same length.
    const cmp = $('w-cmp') && $('w-cmp').checked ? charts.prevRange(a, b) : null;
    if (cmp) {
      const pa = cmp[0], pb = cmp[1], pVisits = ctx.dailySum(pa, pb, 'visits');
      const pBounceRate = pVisits ? 100 * ctx.dailySum(pa, pb, 'bounces') / pVisits : 0;
      charts.setDelta('d-visits', visits, pVisits);
      charts.setDelta('d-uniq', sum('uniques'), ctx.dailySum(pa, pb, 'uniques'));
      charts.setDelta('d-pv', sum('pageviews'), ctx.dailySum(pa, pb, 'pageviews'));
      charts.setDelta('d-bounce', bounceRate, pVisits ? pBounceRate : null, true);
      charts.setDelta('d-band', sum('bytes'), ctx.dailySum(pa, pb, 'bytes'));
    } else {
      ['d-visits', 'd-uniq', 'd-pv', 'd-bounce', 'd-band'].forEach(function (id) { charts.setDelta(id, 0, null); });
    }

    charts.renderTrend(days, cmp);
    charts.renderHours(a, b);
    map.render(a, b);
    tree.reload(a, b); // page tree: server-side segmented + lazy-loaded

    renderBarlist(ctx, 'bl-country', 'country', a, b, 'v', { fmt: function (k) { return esc(landName(k)); } });
    // Keyword/entry/exit/download/status/method/browser/OS/device/referrer type/URL:
    // server-side Top-N + lazy loading.
    topN.reloadAll(a, b);
  }

  function resizeAll() { charts.resizeAll(); map.invalidate(); }

  function init() {
    if (typeof Chart === 'undefined') return;
    if (isDark()) { const rootEl = document.getElementById('sightmetrics'); if (rootEl) rootEl.classList.add('sm-dark'); }
    $('w-site').textContent = META.site || 'SightMetrics';
    $('w-gen').textContent = META.erzeugt ? tf('asOf', 'As of: %s', META.erzeugt) : '';
    $('w-version').textContent = DATA.extVersion ? 'v' + DATA.extVersion : '';

    // Multi-site: fill the selector; switching reloads the module with ?site=<id>.
    const sel = $('w-siteselect'), sites = DATA.sites || [];
    if (sel && sites.length) {
      sel.innerHTML = sites.map(function (s) {
        return '<option value="' + s.site_id + '"' + (+s.site_id === +DATA.siteId ? ' selected' : '') + '>' + esc(s.site) + '</option>';
      }).join('');
      sel.onchange = function () { const u = new URL(location.href); u.searchParams.set('site', sel.value); location.href = u.toString(); };
      if (sites.length < 2) sel.style.display = 'none';
    }

    initPresets(ctx, render);
    if ($('w-cmp')) $('w-cmp').onchange = render;
    if ($('w-csv')) $('w-csv').onclick = function () { csvExport.exportCsv($('w-from').value, $('w-to').value); };
    if ($('w-pdf')) $('w-pdf').onclick = function () { resizeAll(); window.print(); };
    window.addEventListener('resize', resizeAll);
    render();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
