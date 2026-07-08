/* E2E test (suite 3): drives the real TYPO3 backend module and checks that
   KPIs, bar lists, drill-down and the world map render. Exit 1 on failure. */
const puppeteer = require('puppeteer-core');

const BASE = process.env.BASE_URL || 'http://localhost:8091';
const USER = process.env.BE_USER || 'admin';
const PASS = process.env.BE_PASS || 'SightMetrics-Admin-2026!';
const CHROME = process.env.CHROME_BIN || '/usr/bin/chromium';

let failed = 0;
function check(name, cond) {
  console.log((cond ? 'PASS ' : 'FAIL ') + name);
  if (!cond) failed++;
}

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', '--window-size=1500,1200'] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1500, height: 1200 });

  // Login
  await page.goto(BASE + '/typo3/', { waitUntil: 'networkidle2' });
  await page.type('input[name="username"]', USER);
  await page.type('input[name="p_field"]', PASS);
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}),
    page.click('button.t3js-login-submit, button[type="submit"]'),
  ]);
  await new Promise(r => setTimeout(r, 2000));
  check('Login erfolgreich (Backend erreicht)', /\/typo3\/module\//.test(page.url()) || !!(await page.$('[data-modulemenu-identifier]')));

  // Open module
  const modSel = '[data-modulemenu-identifier="web_sightmetrics"]';
  check('Modul "SightMetrics" registriert', !!(await page.$(modSel)));
  await page.click(modSel);
  await new Promise(r => setTimeout(r, 4500));

  const handle = await page.$('#typo3-contentIframe');
  const f = handle ? await handle.contentFrame() : null;
  check('Modul-Iframe geladen', !!f);
  if (!f) { await browser.close(); process.exit(1); }

  // CSP: the module must run without policy violations (assets self-contained,
  // no inline style attributes, ES modules + JSON data block CSP-compliant).
  const cspViolations = await f.evaluate(() => new Promise((resolve) => {
    const hits = [];
    document.addEventListener('securitypolicyviolation', (e) => {
      hits.push(e.violatedDirective + ': ' + (e.blockedURI || e.sourceFile || ''));
    });
    setTimeout(() => resolve(hits), 1500);
  }));
  check('Keine CSP-Verletzungen im Modul' + (cspViolations.length ? ' (' + cspViolations.join('; ') + ')' : ''), cspViolations.length === 0);

  const data = await f.evaluate(() => ({
    visits: (document.getElementById('k-visits') || {}).textContent || '',
    pv: (document.getElementById('k-pv') || {}).textContent || '',
    bounce: (document.getElementById('k-bounce') || {}).textContent || '',
    band: (document.getElementById('k-band') || {}).textContent || '',
    browserRows: document.querySelectorAll('#bl-browser .bl-row').length,
    treeNodes: document.querySelectorAll('#w-tree .tnode').length,
    siteOptions: document.querySelectorAll('#w-siteselect option').length,
    // Chart.js renders directly into <canvas id="w-time"> (no child canvas like
    // previously with ECharts). The Leaflet map (preferCanvas: true, see map.js)
    // draws countries onto a <canvas> in the overlay pane rather than SVG paths.
    mapSvgPaths: document.querySelectorAll('#w-map svg path').length,
    mapCanvasNonEmpty: (() => {
      const c = document.querySelector('#w-map canvas');
      if (!c || !c.width || !c.height) return false;
      // Sample a coarse grid of pixels; a real choropleth has many distinct,
      // non-transparent colors (an empty/unrendered canvas is uniformly blank).
      const ctx = c.getContext('2d');
      const colors = new Set();
      for (let x = 0; x < c.width; x += Math.max(1, Math.floor(c.width / 20))) {
        for (let y = 0; y < c.height; y += Math.max(1, Math.floor(c.height / 20))) {
          const [r, g, b, a] = ctx.getImageData(x, y, 1, 1).data;
          if (a > 0) colors.add(r + ',' + g + ',' + b);
        }
      }
      return colors.size > 3;
    })(),
    timeCanvas: (document.getElementById('w-time') || {}).tagName === 'CANVAS'
      && (document.getElementById('w-time') || {}).height > 0,
  }));
  check('KPI Besuche gefüllt', /[1-9]/.test(data.visits));
  check('KPI Seitenaufrufe gefüllt', /[1-9]/.test(data.pv));
  check('KPI Absprungrate gefüllt (%)', /%/.test(data.bounce));
  check('KPI Bandbreite gefüllt', /(B|KB|MB|GB)/.test(data.band));
  check('Verlaufs-Diagramm gerendert (Chart.js-Canvas)', data.timeCanvas);
  check('Weltkarte gerendert (' + data.mapSvgPaths + ' SVG-Pfade oder gefuelltes Canvas)',
    data.mapSvgPaths > 100 || data.mapCanvasNonEmpty);
  check('Browser-Barliste hat Zeilen', data.browserRows > 0);
  check('Seitenbaum hat Knoten', data.treeNodes > 0);
  check('Site-Auswahl befüllt (Multi-Site)', data.siteOptions >= 1);

  // Drill-down: expand browser row -> subtable appears
  const drill = await f.evaluate(() => {
    const row = document.querySelector('#bl-browser .bl-drill .bl-label');
    if (!row) return { ok: false, reason: 'kein aufklappbarer Browser' };
    row.click();
    const sub = document.querySelector('#bl-browser .bl-sub');
    const open = sub && sub.style.display !== 'none';
    return { ok: !!open, child: open ? (sub.querySelector('.bl-text') || {}).textContent : null };
  });
  check('Drill-down öffnet Subtabelle' + (drill.child ? ' (' + drill.child + ')' : ''), drill.ok);

  // Time range dropdown: grouped (one dropdown), custom inputs initially hidden
  const preset = await f.evaluate(() => {
    const sel = document.getElementById('w-preset'), custom = document.getElementById('w-custom');
    return {
      options: sel ? sel.options.length : 0,
      customHidden: !!(custom && custom.hidden),
      // Label is localized (en "Year ...", de "Jahr ...") -- accept both.
      hasYear: sel ? Array.from(sel.options).some(o => /^(Jahr|Year) /.test(o.textContent)) : false,
    };
  });
  check('Zeitraum-Dropdown mit Vorgaben', preset.options >= 8);
  check('Custom-Datepicker anfangs eingeklappt', preset.customHidden);
  check('Konkrete Jahre als Vorgabe vorhanden', preset.hasYear);

  // Dark mode class is set for a dark scheme (checked via matchMedia)
  const dark = await f.evaluate(() => {
    const root = document.getElementById('sightmetrics');
    const wantDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    const cs = document.documentElement.getAttribute('data-color-scheme');
    const expectDark = cs === 'dark' || (cs !== 'light' && wantDark);
    return { ok: !!root && (root.classList.contains('sm-dark') === expectDark) };
  });
  check('Dark-Mode-Klasse passend zum Schema', dark.ok);

  // Period comparison: narrow the time range to the last day (so a previous period exists),
  // then enable the checkbox -> delta badge appears.
  const cmp = await f.evaluate(() => {
    const cb = document.getElementById('w-cmp'), from = document.getElementById('w-from'), to = document.getElementById('w-to');
    if (!cb || !from || !to) return { present: false };
    from.value = to.max; to.value = to.max; from.dispatchEvent(new Event('change'));
    cb.checked = true; cb.dispatchEvent(new Event('change'));
    const d = document.getElementById('d-visits');
    return { present: true, delta: d ? d.textContent.trim() : '' };
  });
  check('Vergleichs-Checkbox vorhanden', cmp.present);
  check('Perioden-Delta gefüllt' + (cmp.delta ? ' (' + cmp.delta + ')' : ''), !!cmp.delta);

  // Export: buttons present
  const exp = await f.evaluate(() => ({
    csvBtn: !!document.getElementById('w-csv'),
    pdfBtn: !!document.getElementById('w-pdf'),
  }));
  check('CSV-Export-Button vorhanden', exp.csvBtn);
  check('PDF-Export-Button vorhanden', exp.pdfBtn);

  await browser.close();
  console.log(failed === 0 ? '\n>> E2E-TEST: OK' : `\n>> E2E-TEST: ${failed} FEHLGESCHLAGEN`);
  process.exit(failed === 0 ? 0 : 1);
})().catch(e => { console.error('FEHLER', e.message); process.exit(1); });
