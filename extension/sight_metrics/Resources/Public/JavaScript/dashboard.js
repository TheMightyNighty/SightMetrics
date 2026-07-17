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
    // server-side Top-N + lazy loading. Preset label (if any) lets the server use
    // the precomputed topn table (docs/topn-precompute-spec.md); only meaningful
    // for calendar-anchored presets, so 'custom'/'window'/'today' etc. are passed
    // through too but simply never match server-side and stay on the live path.
    const presetEl = $('w-preset');
    topN.reloadAll(a, b, presetEl ? presetEl.value : null);
    pollExportAvailability();
  }

  // Root Top-N panels now load asynchronously (modules/topn.js: last-complete-day
  // first, then the real range) instead of arriving in the initial payload --
  // export.js reads TOPN[dim].rows synchronously, so an export triggered before
  // the accurate ("final") data has landed for every dim would silently ship
  // incomplete rows. Disable CSV/PDF until topN.allLoaded(), polling instead of
  // an event (reloadAll()/toggleSub() have several async completion points).
  let exportPoll = null;
  function pollExportAvailability() {
    if (exportPoll) clearInterval(exportPoll);
    const apply = function () {
      const ready = topN.allLoaded();
      if ($('w-csv')) $('w-csv').disabled = !ready;
      if ($('w-pdf')) $('w-pdf').disabled = !ready;
      return ready;
    };
    if (apply()) return;
    exportPoll = setInterval(function () { if (apply()) { clearInterval(exportPoll); exportPoll = null; } }, 300);
  }

  function resizeAll() { charts.resizeAll(); map.invalidate(); }

  // Click a card's header to expand it to the full grid width (e.g. for panels
  // with long lines -- referrer URLs, search terms); the other cards in that
  // .sm-grid reflow below (plain CSS Grid, .sm-expanded sets grid-column:1/-1).
  // Accordion per .sm-grid section: expanding one card collapses any other
  // already-expanded card in the *same* section, not across sections.
  function initExpandableCards() {
    document.querySelectorAll('#sightmetrics .sm-grid > .sm-card').forEach(function (card) {
      const header = /** @type {any} */ (card.querySelector('h2, h3'));
      if (!header) return;
      card.classList.add('sm-expandable');
      header.setAttribute('role', 'button');
      header.tabIndex = 0;
      header.setAttribute('aria-expanded', 'false');
      const toggle = function () {
        const grid = card.parentElement, willExpand = !card.classList.contains('sm-expanded');
        grid.querySelectorAll(':scope > .sm-card.sm-expanded').forEach(function (other) {
          other.classList.remove('sm-expanded');
          const h = other.querySelector('h2, h3'); if (h) h.setAttribute('aria-expanded', 'false');
        });
        card.classList.toggle('sm-expanded', willExpand);
        header.setAttribute('aria-expanded', willExpand ? 'true' : 'false');
        resizeAll();
      };
      header.onclick = toggle;
      header.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } };
    });
  }

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
    initExpandableCards();
    if ($('w-cmp')) $('w-cmp').onchange = render;
    if ($('w-csv')) $('w-csv').onclick = function () { csvExport.exportCsv($('w-from').value, $('w-to').value); };
    if ($('w-pdf')) $('w-pdf').onclick = function () { resizeAll(); window.print(); };
    window.addEventListener('resize', resizeAll);
    render();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
