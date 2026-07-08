/* SightMetrics – Chart.js pieces: theme colors, KPI delta badges, the trend
   line chart and the visiting-hours bar chart. Chart.js stays a global vendor
   script (window.Chart). */

import { DAY, inR, toDate, toStr } from './util.js';

const PAL = ['#15508c', '#2f8f5b', '#b9851d'];

// Dark mode: TYPO3 backend scheme (data-color-scheme on html/body, possibly in
// the parent document) preferred, otherwise the OS setting.
export function isDark() {
  try {
    const docs = [document, window.parent && window.parent !== window ? window.parent.document : null];
    for (let i = 0; i < docs.length; i++) {
      const d = docs[i]; if (!d) continue;
      const cs = (d.documentElement && d.documentElement.getAttribute('data-color-scheme'))
        || (d.body && d.body.getAttribute('data-color-scheme'));
      if (cs === 'dark') { return true; }
      if (cs === 'light') { return false; }
    }
  } catch (e) { /* cross-origin: ignore, fallback below */ }
  return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
}

// Axis/text colors depending on the scheme; also sets Chart.defaults so elements
// without an explicit color (e.g. the map legend) follow the theme.
export function chartColors() {
  const cc = isDark()
    ? { text: '#c7d0db', line: '#3a4250', mapArea: '#323a45', mapBorder: '#475063', tooltipBg: '#1a1f27' }
    : { text: '#1d2733', line: '#e3e8ef', mapArea: '#f4f6f9', mapBorder: '#cdd6e0', tooltipBg: '#1d2733' };
  if (typeof Chart !== 'undefined') {
    Chart.defaults.color = cc.text;
    Chart.defaults.borderColor = cc.line;
    Chart.defaults.plugins.tooltip.backgroundColor = cc.tooltipBg;
    Chart.defaults.plugins.tooltip.titleColor = '#fff';
    Chart.defaults.plugins.tooltip.bodyColor = '#fff';
  }
  return cc;
}

/**
 * @param {any} ctx dashboard context (createContext())
 * @returns {{
 *   setDelta: (id: string, cur: number, prev: number|null, invert?: boolean) => void,
 *   prevRange: (a: string, b: string) => [string, string]|null,
 *   renderTrend: (days: any[], cmp: [string,string]|null) => void,
 *   renderHours: (a: string, b: string) => void,
 *   resizeAll: () => void,
 * }}
 */
export function createCharts(ctx) {
  const { META, DAILY, i18n, $ } = ctx;
  const t = i18n.t, nf = i18n.nf;
  /** @type {Record<string, any>} */
  const charts = {};

  // (Re-)create a Chart.js instance: simpler than a partial update, data volume is small.
  function setChart(id, config) {
    if (charts[id]) charts[id].destroy();
    charts[id] = new Chart($(id).getContext('2d'), config);
    return charts[id];
  }

  // Immediately preceding range of the same length, clamped to available data.
  function prevRange(a, b) {
    const len = Math.round((toDate(b) - toDate(a)) / DAY) + 1;
    const pb = toDate(a) - DAY, pa = pb - (len - 1) * DAY;
    if (pa < toDate(META.von)) return null; // no complete previous period available
    return /** @type {[string, string]} */ ([toStr(pa), toStr(pb)]);
  }

  // Write a delta badge into a KPI element (arrow + percent, colored by direction).
  function setDelta(id, cur, prev, invert) {
    const elx = $(id); if (!elx) return;
    if (prev == null) { elx.textContent = ''; elx.className = 'd'; return; }
    if (prev === 0) { elx.textContent = cur > 0 ? t('new', 'new') : '±0'; elx.className = 'd flat'; return; }
    const pct = 100 * (cur - prev) / prev, up = pct > 0.05, down = pct < -0.05;
    const good = invert ? down : up; // for bounce rate, "down" is good
    elx.className = 'd ' + (up ? 'up' : down ? 'down' : 'flat') + (good ? ' good' : (up || down ? ' bad' : ''));
    elx.textContent = (up ? '▲ ' : down ? '▼ ' : '± ') + i18n.pct1(pct) + ' %';
  }

  function renderTrend(days, cmp) {
    /** @type {Array<any>} */
    const tDatasets = [
      { label: t('pageviews', 'Page views'), data: days.map(function (d) { return d.pageviews; }), borderColor: PAL[0], backgroundColor: PAL[0] + '14', fill: true, tension: .3, pointRadius: 0 },
      { label: t('visits', 'Visits'), data: days.map(function (d) { return d.visits; }), borderColor: PAL[1], fill: false, tension: .3, pointRadius: 0 },
      { label: t('uniques', 'Unique visitors'), data: days.map(function (d) { return d.uniques; }), borderColor: PAL[2], fill: false, tension: .3, pointRadius: 0 }];
    if (cmp) {
      // Previous period position-wise (day 1 to day 1) as a dashed reference for page views.
      const pdays = DAILY.filter(function (/** @type {any} */ d) { return inR(d.datum, cmp[0], cmp[1]); });
      tDatasets.push({ label: t('pageviewsPrev', 'Page views (previous period)'), borderColor: '#9aa7b6', borderDash: [4, 3], fill: false, tension: .3, pointRadius: 0,
        data: days.map(function (/** @type {any} */ _, /** @type {number} */ i) { return pdays[i] ? pdays[i].pageviews : null; }) });
    }
    const cc = chartColors();
    setChart('w-time', {
      type: 'line',
      data: { labels: days.map(function (d) { return d.datum; }), datasets: tDatasets },
      options: { responsive: true, maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
        plugins: { legend: { position: 'bottom', labels: { color: cc.text } }, tooltip: { mode: 'index', intersect: false } },
        scales: {
          x: { grid: { color: cc.line }, ticks: { color: cc.text } },
          y: { beginAtZero: true, grid: { color: cc.line }, ticks: { color: cc.text } },
        },
      },
    });
  }

  function renderHours(a, b) {
    const hours = ctx.agg('hour', a, b, 'pv');
    /** @type {Record<string, number>} */
    const hmap = {}; hours.forEach(function (/** @type {any} */ r) { hmap[r.key] = r.pv; });
    const hx = []; for (let i = 0; i < 24; i++) hx.push(('0' + i).slice(-2));
    const cc = chartColors();
    setChart('w-hour', {
      type: 'bar',
      data: { labels: hx, datasets: [{ label: t('pageviews', 'Page views'), data: hx.map(function (k) { return hmap[k] || 0; }), backgroundColor: PAL[0], borderRadius: 2 }] },
      options: { responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { mode: 'index', intersect: false } },
        scales: {
          x: { grid: { color: cc.line }, ticks: { color: cc.text } },
          y: { beginAtZero: true, grid: { color: cc.line }, ticks: { color: cc.text } },
        },
      },
    });
  }

  function resizeAll() {
    Object.keys(charts).forEach(function (k) { charts[k].resize(); });
  }

  return { setDelta: setDelta, prevRange: prevRange, renderTrend: renderTrend, renderHours: renderHours, resizeAll: resizeAll };
}
