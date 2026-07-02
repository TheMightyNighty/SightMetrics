// Minimaler DOM-Smoke-Test fuer dashboard.js: laedt das echte Fluid-Template + das echte
// Skript in jsdom, mit gefaelschten Chart.js-/Leaflet-Stubs statt der echten Bibliotheken
// (schnell, keine echte Canvas-/WebGL-Implementierung noetig). Deckt genau die Fehlerklasse
// ab, die beim ECharts->Chart.js/Leaflet-Umbau mehrfach durchgerutscht ist: falscher
// Element-Typ (canvas vs. div), ungueltiges GeoJSON, Bibliotheks-API falsch benutzt,
// stillschweigend nichts gerendert. Kein Build-Prozess -- reines Node + jsdom (devDependency).
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

// Kleines, aber realistisches Payload -- deckt Tages-Serie, Cube-Zeilen (inkl. country-Dimension
// fuer die Karte) und Multi-Site-Auswahl ab.
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

// Kleine synthetische Weltkarte statt der echten (~1,4 MB) Vendor-Datei -- der Test prueft
// dashboard.js' Umgang mit GeoJSON, nicht den Inhalt der echten Kartendaten.
const FAKE_WORLD = {
  type: 'FeatureCollection',
  features: [
    { type: 'Feature', properties: { name: 'Germany' }, geometry: { type: 'Polygon', coordinates: [[[0, 0], [1, 0], [1, 1], [0, 0]]] } },
    { type: 'Feature', properties: { name: 'United States of America' }, geometry: { type: 'Polygon', coordinates: [[[10, 10], [11, 10], [11, 11], [10, 10]]] } },
  ],
};

// jsdom meldet direkt nach dem Konstruieren readyState 'loading' (realistisches
// Navigations-Timing) -- dashboard.js haengt sich dann an DOMContentLoaded statt sofort zu
// laufen, genau wie im echten Browser. Darauf warten statt synchron zu pruefen.
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

  // runScripts:'dangerously' noetig, damit window.eval() spaeter mit vollem Zugriff auf
  // window/document laeuft (Standardverhalten von jsdom ohne diese Option ist sandboxed).
  // Unbedenklich hier: wir evaluieren nur unseren eigenen, lokalen dashboard.js-Quelltext.
  const dom = new JSDOM(`<!doctype html><html><body>${bodyHtml}</body></html>`, {
    url: 'http://localhost/',
    runScripts: 'dangerously',
  });
  const { window } = dom;

  // Canvas-getContext gibt es in jsdom nicht ohne natives 'canvas'-Paket -- Chart.js braucht
  // nur irgendein Objekt als Kontext, echtes Zeichnen wird hier nicht geprueft.
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
      // Wie echtes Leaflet: style()/onEachFeature() pro Feature ausfuehren, um Exceptions
      // in diesen Callbacks zu fangen (genau hier lag der "Invalid GeoJSON object"-Fehler).
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
  const source = readFileSync(DASHBOARD_JS_PATH, 'utf8');

  // dashboard.js registriert bei 'loading' seinen eigenen DOMContentLoaded-Listener (init())
  // und laeuft danach genau wie im echten Browser -- hier mitwarten statt synchron zu pruefen.
  window.eval(source);
  await waitForReady(window);

  assert.deepEqual(windowErrors, [], 'dashboard.js darf beim Laden/Rendern keine Exceptions werfen');

  // KPIs wurden befuellt (Platzhalter "–" ersetzt).
  const visits = window.document.getElementById('k-visits').textContent;
  assert.notEqual(visits, '–', 'KPI "Besuche" wurde nicht gerendert');
  assert.equal(visits, (10 + 15 + 12).toLocaleString('de-DE'));

  // Linien- und Balkenchart wurden mit den erwarteten Chart.js-Typen erzeugt.
  const types = chartInstances.map((c) => c.type).sort();
  assert.deepEqual(types, ['bar', 'line'], 'erwartet genau einen Line- und einen Bar-Chart (Verlauf + Stunden)');

  // Karte: L.geoJSON wurde mit einer echten FeatureCollection aufgerufen (nicht leer/undefined).
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

  const source = readFileSync(DASHBOARD_JS_PATH, 'utf8');
  window.eval(source);
  await waitForReady(window);
  assert.deepEqual(windowErrors, [], 'dashboard.js darf beim Laden/Rendern keine Exceptions werfen');

  const keywordEl = window.document.getElementById('bl-keyword');
  assert.ok(keywordEl.textContent.includes('rathaus'), 'initiale Top-N-Zeilen aus dem Payload muessen gerendert werden');
  const more = keywordEl.querySelector('.bl-more-click');
  assert.ok(more, '"+ N weitere" muss angezeigt werden, wenn total.count > geladene Zeilen');
  assert.equal(more.textContent, '+ 3 weitere');

  more.click();
  await new Promise((r) => setTimeout(r, 0));

  assert.equal(fetchCalls.length, 1, 'Klick auf "+ N weitere" muss genau einen Ajax-Request ausloesen');
  assert.match(fetchCalls[0], /dim=keyword/);
  assert.match(fetchCalls[0], /offset=2/);
  assert.ok(keywordEl.textContent.includes('anmeldung'), 'nachgeladene Zeilen muessen angehaengt werden');
  assert.equal(keywordEl.querySelectorAll('.bl-more').length, 0, 'nach vollstaendigem Nachladen kein "+ N weitere" mehr');
});

test('dashboard.js bricht sauber ab, wenn Chart.js/Leaflet fehlen (kein Wurf, kein Crash)', async () => {
  const { window, windowErrors } = buildDom();
  delete window.Chart;
  delete window.L;
  const source = readFileSync(DASHBOARD_JS_PATH, 'utf8');

  window.eval(source);
  await waitForReady(window);

  assert.deepEqual(windowErrors, [], 'ohne Chart.js/Leaflet darf dashboard.js nicht werfen, nur fruehzeitig abbrechen');
});
