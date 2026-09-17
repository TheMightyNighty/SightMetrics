/* Screenshot tool: logs into the TYPO3 backend, opens the
   SightMetrics module and saves PNG screenshots (for Documentation/Images/
   and manual visual inspection). Usage:
     node screenshot.js <output.png> [--full] [--selector '#sightmetrics ...']
                        [--scroll <px>] [--site '<name>']
   ENV like e2e.js (BASE_URL, BE_USER, BE_PASS, CHROME_BIN), plus
   SHOT_SCHEME=light|dark (default light — the documentation images are light;
   headless Chrome would otherwise follow its own default and produce a dark
   module) and SHOT_W/SHOT_H.
   Since the panels below the fold load via Ajax (two-stage loading), the tool
   waits for the loading placeholders to disappear before it scrolls/shoots.

   Recipes for the committed documentation images (demo stack running, both
   demo sites imported — see the repo README "Quick start"):
     node screenshot.js .../Images/dashboard.png  --site 'Bürgeramt Mitte'
     node screenshot.js .../Images/visitors.png   --site 'Bürgeramt Mitte' \
            --anchor '#bl-country' --anchor-offset 105
     node screenshot.js .../Images/behaviour.png  --site 'Bürgeramt Mitte' \
            --anchor '#bl-entry'   --anchor-offset 200
     node screenshot.js .../Images/onboarding.png --selector '.sm-notice'
            (needs an EMPTY cube, so the module shows the onboarding notice)
     SHOT_W=1600 SHOT_H=3000 node screenshot.js ../extension/typo3-Logauswertung.png \
            --site 'Bürgeramt Mitte' --selector '#sightmetrics'
   The last one uses an oversized viewport so the whole module fits on screen
   (--full duplicates the header on a page this tall). */
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

const scheme = process.env.SHOT_SCHEME || 'light';
const siteIdx = process.argv.indexOf('--site');
const site = siteIdx > -1 ? process.argv[siteIdx + 1] : null;
const anchorIdx = process.argv.indexOf('--anchor');
const anchor = anchorIdx > -1 ? process.argv[anchorIdx + 1] : null;
const aOffIdx = process.argv.indexOf('--anchor-offset');
const anchorOffset = aOffIdx > -1 ? parseInt(process.argv[aOffIdx + 1], 10) : 0;

/* Wait until the Ajax-loaded bar lists have stopped showing their
   "loading …" indicator (two-stage panel loading, see modules/topn.js). */
async function waitForPanels(frame, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const busy = await frame.evaluate(() =>
      Array.from(document.querySelectorAll('#sightmetrics .bl-more'))
        .some(el => /loading|lädt/i.test(el.textContent || ''))).catch(() => false);
    if (!busy || Date.now() > deadline) return;
    await new Promise(r => setTimeout(r, 300));
  }
}

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', `--window-size=${W},${H + 100}`] });
  const page = await browser.newPage();
  await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }]);

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

  if (site) {
    const picked = await frame.evaluate((name) => {
      const sel = document.querySelector('#sightmetrics select[name="site"], #sightmetrics select');
      if (!sel) return false;
      const opt = Array.from(sel.options).find(o => (o.textContent || '').trim() === name);
      if (!opt) return false;
      sel.value = opt.value;
      sel.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    }, site);
    if (!picked) { console.error('Site nicht in der Auswahl: ' + site); await browser.close(); process.exit(1); }
    await new Promise(r => setTimeout(r, 3000));
  }

  await waitForPanels(frame);

  // --anchor scrolls an element to the top edge (minus --anchor-offset) and
  // stays reproducible when panel heights change, unlike --scroll.
  if (anchor) {
    const ok = await frame.evaluate((sel, off) => {
      const el = document.querySelector(sel);
      if (!el) return false;
      window.scrollTo(0, Math.max(0, el.getBoundingClientRect().top + window.scrollY - off));
      return true;
    }, anchor, anchorOffset);
    if (!ok) { console.error('Anchor nicht gefunden: ' + anchor); await browser.close(); process.exit(1); }
    await new Promise(r => setTimeout(r, 800));
    await waitForPanels(frame);
  } else if (scrollY) {
    await frame.evaluate((y) => window.scrollTo(0, y), scrollY);
    await new Promise(r => setTimeout(r, 800));
    await waitForPanels(frame);
  }

  if (selector) {
    const el = await frame.$(selector);
    if (!el) { console.error('Selector nicht gefunden: ' + selector); await browser.close(); process.exit(1); }
    await el.screenshot({ path: out });
  } else if (full) {
    // Entire module document (iframe content) including the scroll area.
    // Panels below the fold load on demand, so walk down the page and wait
    // for each of them before returning to the top.
    // scrollHeight is re-read each round: loading a panel makes the page grow.
    for (let y = 0, steps = 0; steps < 40; y += Math.floor(H * 0.8), steps++) {
      if (y >= await frame.evaluate(() => document.body.scrollHeight)) break;
      await frame.evaluate((v) => window.scrollTo(0, v), y);
      await new Promise(r => setTimeout(r, 500));
      await waitForPanels(frame);
    }
    await frame.evaluate(() => window.scrollTo(0, 0));
    await new Promise(r => setTimeout(r, 800));
    const body = await frame.$('body');
    await body.screenshot({ path: out });
  } else {
    await page.screenshot({ path: out });
  }
  console.log('Screenshot: ' + out);
  await browser.close();
})();
