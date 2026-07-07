/* Screenshot tool: logs into the TYPO3 backend, opens the
   SightMetrics module and saves PNG screenshots (for Documentation/Images/
   and manual visual inspection). Usage:
     node screenshot.js <output.png> [--full] [--selector '#sightmetrics ...']
   ENV like e2e.js (BASE_URL, BE_USER, BE_PASS, CHROME_BIN). */
const puppeteer = require('puppeteer-core');

const BASE = process.env.BASE_URL || 'http://localhost:8091';
const USER = process.env.BE_USER || 'admin';
const PASS = process.env.BE_PASS || 'SightMetrics-Admin-2026!';
const CHROME = process.env.CHROME_BIN || '/usr/bin/chromium';

const out = process.argv[2] || 'module.png';
const full = process.argv.includes('--full');
const selIdx = process.argv.indexOf('--selector');
const selector = selIdx > -1 ? process.argv[selIdx + 1] : null;
const scrollIdx = process.argv.indexOf('--scroll');
const scrollY = scrollIdx > -1 ? parseInt(process.argv[scrollIdx + 1], 10) : 0;
const W = parseInt(process.env.SHOT_W || '1920', 10);
const H = parseInt(process.env.SHOT_H || '1080', 10);

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', `--window-size=${W},${H + 100}`] });
  const page = await browser.newPage();
  await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });

  await page.goto(BASE + '/typo3/', { waitUntil: 'networkidle2' });
  await page.type('input[name="username"]', USER);
  await page.type('input[name="p_field"]', PASS);
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}),
    page.click('button.t3js-login-submit, button[type="submit"]'),
  ]);
  await new Promise(r => setTimeout(r, 2000));
  await page.click('[data-modulemenu-identifier="web_sightmetrics"]');
  await new Promise(r => setTimeout(r, 5000));

  const handle = await page.$('#typo3-contentIframe');
  const frame = handle ? await handle.contentFrame() : null;
  if (!frame) { console.error('Modul-Iframe nicht gefunden'); await browser.close(); process.exit(1); }

  if (scrollY) {
    await frame.evaluate((y) => window.scrollTo(0, y), scrollY);
    await new Promise(r => setTimeout(r, 800));
  }

  if (selector) {
    const el = await frame.$(selector);
    if (!el) { console.error('Selector nicht gefunden: ' + selector); await browser.close(); process.exit(1); }
    await el.screenshot({ path: out });
  } else if (full) {
    // Entire module document (iframe content) including the scroll area
    const body = await frame.$('body');
    await body.screenshot({ path: out });
  } else {
    await page.screenshot({ path: out });
  }
  console.log('Screenshot: ' + out);
  await browser.close();
})();
