// Minimal DOM smoke test for dashboard.js: loads the real Fluid template + the real
// script in jsdom, with fake Chart.js/Leaflet stubs instead of the real libraries
// (fast, no real canvas/WebGL implementation needed). Covers exactly the class of bugs
// that slipped through repeatedly during the ECharts->Chart.js/Leaflet rebuild: wrong
// element type (canvas vs. div), invalid GeoJSON, library API misuse,
// silently rendering nothing. No build process -- pure Node + jsdom (devDependency).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const HERE = dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = join(HERE, '..', '..');
const TEMPLATE_PATH = join(EXT_ROOT, 'Resources/Private/Templates/Dashboard/Index.html');
const DASHBOARD_JS_PATH = join(EXT_ROOT, 'Resources/Public/JavaScript/dashboard.js');

// dashboard.js is a native ES module (import from ./modules/*) -- window.eval()
// cannot execute modules. Instead: expose jsdom objects as Node globals
// and load the module via dynamic import. Cache buster (?t=...) needed,
// because Node's ESM cache would otherwise only run the same module once (for the first test).
async function loadDashboard(window) {
  for (const key of ['window', 'document', 'location', 'Chart', 'L', 'SM_WORLD']) {
    globalThis[key] = window[key];
  }
  // fetch: bound late, so tests can stub window.fetch after buildDom().
  globalThis.fetch = (...args) => window.fetch(...args);
  const { pathToFileURL } = await import('node:url');
  await import(pathToFileURL(DASHBOARD_JS_PATH).href + '?t=' + Date.now() + Math.random());
  await waitForReady(window);
}

// Small but realistic payload -- covers daily series, cube rows (incl. country dimension
// for the map) and multi-site selection.
const FAKE_PAYLOAD = {
  meta: { site: 'Testbehörde', von: '2026-06-01', bis: '2026-06-03', erzeugt: '2026-06-03 10:00', uniques_total: 42 },
  daily: [
    { datum: '2026-06-01', visits: 10, pageviews: 20, uniques: 8, bounces: 2, bytes: 1000 },
    { datum: '2026-06-02', visits: 15, pageviews: 25, uniques: 11, bounces: 3, bytes: 1500 },
    { datum: '2026-06-03', visits: 12, pageviews: 22, uniques: 9, bounces: 1, bytes: 1200 },
  ],
  cube: [
    { datum: '2026-06-01', dim: 'country', dimkey: 'DE', pv: 12, v: 6 },
    { datum: '2026-06-02', dim: 'country', dimkey: 'US', pv: 8, v: 4 },
    { datum: '2026-06-01', dim: 'hour', dimkey: '09', pv: 5, v: 3 },
    { datum: '2026-06-01', dim: 'browser', dimkey: 'Firefox', pv: 7, v: 4 },
  ],
  sites: [{ site_id: 1, site: 'Testbehörde' }],
  siteId: 1,
  window: { von: '2026-06-01', bis: '2026-06-03' },
};

// Small synthetic world map instead of the real (~1.4 MB) vendor file -- the test checks
// dashboard.js's handling of GeoJSON, not the content of the real map data.
const FAKE_WORLD = {
  type: 'FeatureCollection',
  features: [
    { type: 'Feature', properties: { name: 'Germany' }, geometry: { type: 'Polygon', coordinates: [[[0, 0], [1, 0], [1, 1], [0, 0]]] } },
    { type: 'Feature', properties: { name: 'United States of America' }, geometry: { type: 'Polygon', coordinates: [[[10, 10], [11, 10], [11, 11], [10, 10]]] } },
  ],
};

// jsdom reports readyState 'loading' right after construction (realistic
// navigation timing) -- dashboard.js then hooks into DOMContentLoaded instead of running
// immediately, just like in a real browser. Wait for that instead of checking synchronously.
function waitForReady(window) {
  if (window.document.readyState !== 'loading') return Promise.resolve();
  return new Promise((resolve) => {
    window.document.addEventListener('DOMContentLoaded', resolve, { once: true });
  });
}

function buildDom(payload) {
  const template = readFileSync(TEMPLATE_PATH, 'utf8');
  const match = template.match(/<f:else>([\s\S]*)<\/f:else>/);
  assert.ok(match, 'Template-Struktur <f:else>...</f:else> nicht gefunden -- Test an Template-Aenderung anpassen');
  const bodyHtml = match[1].replace(
    '<f:format.raw>{payload}</f:format.raw>',
    JSON.stringify(payload || FAKE_PAYLOAD).replace(/</g, '\\u003c')
  );

  // runScripts:'dangerously' lets event handlers/timers run in the jsdom window;
  // the module itself is loaded via loadDashboard() (Node ESM + jsdom globals).
  const dom = new JSDOM(`<!doctype html><html><body>${bodyHtml}</body></html>`, {
    url: 'http://localhost/',
    runScripts: 'dangerously',
  });
  const { window } = dom;

  // jsdom has no canvas getContext without the native 'canvas' package -- Chart.js just
  // needs some object as context, real drawing is not checked here.
  window.HTMLCanvasElement.prototype.getContext = () => ({});

  const chartInstances = [];
  class FakeChart {
    constructor(ctx, config) {
      this.ctx = ctx;
      this.config = config;
      chartInstances.push(config);
    }
    destroy() {}
    resize() {}
  }
  FakeChart.defaults = { color: null, borderColor: null, plugins: { tooltip: {} } };
  window.Chart = FakeChart;

  const geoJsonCalls = [];
  window.L = {
    map(id, opts) {
      return { id, opts, setView() { return this; }, removeLayer() {}, removeControl() {}, invalidateSize() {} };
    },
    geoJSON(data, opts) {
      geoJsonCalls.push({ data, opts });
      // Like real Leaflet: run style()/onEachFeature() per feature, to catch exceptions
      // in these callbacks (this is exactly where the "Invalid GeoJSON object" bug was).
      for (const feature of (data && data.features) || []) {
        assert.equal(feature.type, 'Feature', 'jedes Feature braucht type:"Feature" (GeoJSON-Pflichtfeld, siehe Leaflet-Migration)');
        if (opts.style) opts.style(feature);
        if (opts.onEachFeature) {
          const fakeLayer = { bindTooltip() {}, setStyle() {}, on() {} };
          opts.onEachFeature(feature, fakeLayer);
        }
      }
      return { addTo() { return this; } };
    },
    control() {
      const ctrl = { onAdd: null, addTo(map) { if (this.onAdd) this.onAdd(map); return this; } };
      return ctrl;
    },
    DomUtil: { create: (tag) => window.document.createElement(tag) },
  };

  window.SM_WORLD = FAKE_WORLD;

  const windowErrors = [];
  window.addEventListener('error', (e) => windowErrors.push(e.error || e.message));

  return { dom, window, chartInstances, geoJsonCalls, windowErrors };
}

test('dashboard.js laedt Payload, rendert KPIs, Linien-/Balkenchart und Karte ohne Fehler', async () => {
  const { window, chartInstances, geoJsonCalls, windowErrors } = buildDom();

  // dashboard.js registers its own DOMContentLoaded listener (init()) while 'loading'
  // and then runs just like in a real browser -- wait for it here instead of checking synchronously.
  await loadDashboard(window);

  assert.deepEqual(windowErrors, [], 'dashboard.js darf beim Laden/Rendern keine Exceptions werfen');

  // KPIs were populated (placeholder "-" replaced).
  const visits = window.document.getElementById('k-visits').textContent;
  assert.notEqual(visits, '–', 'KPI "Besuche" wurde nicht gerendert');
  assert.equal(visits, (10 + 15 + 12).toLocaleString('de-DE'));

  // Line and bar chart were created with the expected Chart.js types.
  const types = chartInstances.map((c) => c.type).sort();
  assert.deepEqual(types, ['bar', 'line'], 'erwartet genau einen Line- und einen Bar-Chart (Verlauf + Stunden)');

  // Map: L.geoJSON was called with a real FeatureCollection (not empty/undefined).
  assert.equal(geoJsonCalls.length, 1, 'L.geoJSON haette genau einmal aufgerufen werden muessen');
  assert.equal(geoJsonCalls[0].data.type, 'FeatureCollection');
  assert.ok(geoJsonCalls[0].data.features.length > 0, 'Karte ohne Laender-Features gerendert');
});

test('Top-N-Barliste (z. B. Keyword) rendert Server-Top-N und laedt "+ N weitere" per Fetch nach', async () => {
  const payload = {
    ...FAKE_PAYLOAD,
    topNUrl: '/typo3/ajax/sightmetrics/topn',
    topNLimit: 2,
    topN: {
      keyword: {
        metric: 'v',
        rows: [{ dimkey: 'rathaus', pv: 10, v: 6 }, { dimkey: 'personalausweis', pv: 8, v: 4 }],
        total: { pv: 30, v: 15, count: 5 },
      },
      entry: { metric: 'v', rows: [], total: { pv: 0, v: 0, count: 0 } },
      exit: { metric: 'v', rows: [], total: { pv: 0, v: 0, count: 0 } },
      download: { metric: 'pv', rows: [], total: { pv: 0, v: 0, count: 0 } },
      status: { metric: 'pv', rows: [], total: { pv: 0, v: 0, count: 0 } },
      method: { metric: 'pv', rows: [], total: { pv: 0, v: 0, count: 0 } },
    },
  };
  const { window, windowErrors } = buildDom(payload);

  const fetchCalls = [];
  window.fetch = (url) => {
    fetchCalls.push(String(url));
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve({
        rows: [{ dimkey: 'anmeldung', pv: 5, v: 3 }, { dimkey: 'termin', pv: 4, v: 2 }],
        total: { pv: 30, v: 15, count: 4 },
      }),
    });
  };
  await loadDashboard(window);
  assert.deepEqual(windowErrors, [], 'dashboard.js darf beim Laden/Rendern keine Exceptions werfen');

  const keywordEl = window.document.getElementById('bl-keyword');
  assert.ok(keywordEl.textContent.includes('rathaus'), 'initiale Top-N-Zeilen aus dem Payload muessen gerendert werden');
  const more = keywordEl.querySelector('.bl-more-click');
  assert.ok(more, '"+ N weitere" muss angezeigt werden, wenn total.count > geladene Zeilen');
  // Without a lang map in the payload, the English fallback applies (default language of the XLF).
  assert.equal(more.textContent, '+ 3 more');

  more.click();
  await new Promise((r) => setTimeout(r, 0));

  assert.equal(fetchCalls.length, 1, 'Klick auf "+ N weitere" muss genau einen Ajax-Request ausloesen');
  assert.match(fetchCalls[0], /dim=keyword/);
  assert.match(fetchCalls[0], /offset=2/);
  assert.ok(keywordEl.textContent.includes('anmeldung'), 'nachgeladene Zeilen muessen angehaengt werden');
  assert.equal(keywordEl.querySelectorAll('.bl-more').length, 0, 'nach vollstaendigem Nachladen kein "+ N weitere" mehr');
});

test('Drill-down (Browser -> Version) laedt Kinder per parentKey nach, wenn eine Zeile aufgeklappt wird', async () => {
  const payload = {
    ...FAKE_PAYLOAD,
    topNUrl: '/typo3/ajax/sightmetrics/topn',
    topN: {
      browser: {
        metric: 'v',
        limit: 8,
        rows: [{ dimkey: 'Firefox', pv: 12, v: 7 }],
        total: { pv: 12, v: 7, count: 1 },
      },
    },
  };
  const { window, windowErrors } = buildDom(payload);

  const fetchCalls = [];
  window.fetch = (url) => {
    fetchCalls.push(String(url));
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve({
        rows: [{ dimkey: 'Firefox\x1f120', pv: 8, v: 5 }, { dimkey: 'Firefox\x1f119', pv: 4, v: 2 }],
        total: { pv: 12, v: 7, count: 2 },
      }),
    });
  };
  await loadDashboard(window);
  assert.deepEqual(windowErrors, [], 'dashboard.js darf beim Laden/Rendern keine Exceptions werfen');

  const browserEl = window.document.getElementById('bl-browser');
  assert.ok(browserEl.textContent.includes('Firefox'), 'Root-Top-N-Zeile aus dem Payload muss gerendert werden');
  const label = browserEl.querySelector('.bl-drill .bl-label');
  assert.ok(label, 'Zeile mit Drill-down-Kind muss als .bl-drill (aufklappbar) markiert sein');
  assert.equal(fetchCalls.length, 0, 'Kinder duerfen erst bei Klick geladen werden, nicht vorab');

  label.click();
  await new Promise((r) => setTimeout(r, 0));

  assert.equal(fetchCalls.length, 1, 'Aufklappen muss genau einen Ajax-Request ausloesen');
  assert.match(fetchCalls[0], /dim=browser_version/);
  assert.match(fetchCalls[0], /parentKey=Firefox/);
  const sub = browserEl.querySelector('.bl-sub');
  assert.ok(sub, 'Sub-Container fuer die Kind-Liste muss erzeugt werden');
  assert.ok(sub.textContent.includes('120'), 'nachgeladene Kind-Zeilen muessen gerendert werden (Eltern-Praefix abgetrennt)');
  assert.ok(!sub.textContent.includes('Firefox\x1f120'), 'Anzeige-Label muss lastSeg-bereinigt sein, nicht der rohe dimkey');
});

test('Seitenbaum rendert vorgeladene 2 Ebenen und laedt tiefere Aeste per path-Fetch nach', async () => {
  const payload = {
    ...FAKE_PAYLOAD,
    treeUrl: '/typo3/ajax/sightmetrics/tree',
    tree: {
      rows: [
        {
          seg: 'buergerservice', path: '/buergerservice', pv: 20, v: 12, hasChildren: true,
          children: [
            { seg: 'personalausweis', path: '/buergerservice/personalausweis', pv: 8, v: 5, hasChildren: true },
            { seg: 'reisepass', path: '/buergerservice/reisepass', pv: 4, v: 2, hasChildren: false },
          ],
          childTotal: { count: 2 },
        },
        { seg: 'aktuelles', path: '/aktuelles', pv: 6, v: 4, hasChildren: false },
      ],
      total: { count: 2 },
    },
  };
  const { window, windowErrors } = buildDom(payload);

  const fetchCalls = [];
  window.fetch = (url) => {
    fetchCalls.push(String(url));
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve({
        rows: [{ seg: 'beantragen', path: '/buergerservice/personalausweis/beantragen', pv: 5, v: 3, hasChildren: false }],
        total: { count: 1 },
      }),
    });
  };
  await loadDashboard(window);
  assert.deepEqual(windowErrors, [], 'dashboard.js darf beim Laden/Rendern keine Exceptions werfen');

  const treeEl = window.document.getElementById('w-tree');
  assert.ok(treeEl.textContent.includes('buergerservice/'), 'Ebene 1 aus dem Payload muss gerendert werden');
  assert.ok(treeEl.textContent.includes('personalausweis'), 'vorgeladene Ebene 2 muss sichtbar sein (aufgeklappt)');
  assert.equal(fetchCalls.length, 0, 'vorgeladene Ebenen duerfen keinen Fetch ausloesen');

  // Expand level-3 branch -> exactly one fetch with the path prefix.
  const toggles = [...treeEl.querySelectorAll('.tog[role="button"]')];
  const level2Toggle = toggles.find((t) => t.getAttribute('aria-expanded') === 'false');
  assert.ok(level2Toggle, 'Ebene-2-Knoten mit Kindern muss aufklappbar (zu) sein');
  level2Toggle.onclick();
  await new Promise((r) => setTimeout(r, 0));

  assert.equal(fetchCalls.length, 1, 'Aufklappen muss genau einen Ajax-Request ausloesen');
  assert.match(fetchCalls[0], /path=%2Fbuergerservice%2Fpersonalausweis/);
  assert.ok(treeEl.textContent.includes('beantragen'), 'nachgeladene Ebene 3 muss gerendert werden');
});

test('dashboard.js bricht sauber ab, wenn Chart.js/Leaflet fehlen (kein Wurf, kein Crash)', async () => {
  const { window, windowErrors } = buildDom();
  delete window.Chart;
  delete window.L;

  await loadDashboard(window);

  assert.deepEqual(windowErrors, [], 'ohne Chart.js/Leaflet darf dashboard.js nicht werfen, nur fruehzeitig abbrechen');
});
