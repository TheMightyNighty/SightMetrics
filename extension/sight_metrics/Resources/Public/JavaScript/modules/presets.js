/* SightMetrics – Matomo-style time range control: preset dropdown, month
   picker and manual from/to inputs. Owns the date-range wiring and calls back
   into render() when the selection changes (reloading if it leaves the loaded
   window). */

import { DAY, esc, toDate, toStr } from './util.js';

/**
 * @param {any} ctx dashboard context (createContext())
 * @param {() => void} render re-render callback for in-window changes
 */
export function initPresets(ctx, render) {
  const { DATA, META, WIN, i18n, $ } = ctx;
  const t = i18n.t, tf = i18n.tf;

  $('w-from').value = WIN.von; $('w-from').min = META.von; $('w-from').max = META.bis;
  $('w-to').value = WIN.bis; $('w-to').min = META.von; $('w-to').max = META.bis;

  function onDateChange() {
    const a = $('w-from').value, b = $('w-to').value;
    if (a && b && (a < WIN.von || b > WIN.bis)) { // outside the loaded window -> reload
      const u = new URL(location.href);
      u.searchParams.set('from', a); u.searchParams.set('to', b);
      if (DATA.siteId) u.searchParams.set('site', DATA.siteId);
      location.href = u.toString(); return;
    }
    render();
  }

  // Set the range (clamped to the dataset) and trigger evaluation/reload.
  function setRange(a, b) {
    a = a < META.von ? META.von : a; b = b > META.bis ? META.bis : b;
    $('w-from').value = a; $('w-to').value = b;
    onDateChange();
  }

  function ymd(y, m, d) { return y + '-' + ('0' + m).slice(-2) + '-' + ('0' + d).slice(-2); }
  function monthRange(y, m) { return [ymd(y, m, 1), toStr(Date.UTC(y, m, 0))]; } // m = 1..12

  // Anchor for relative ranges: "today" in the site's bucketing timezone
  // (DATA.tz = meta.tz, SCHEMA v2; en-CA formats as YYYY-MM-DD), never after the
  // latest data. Fallback: UTC.
  function anchor() {
    let today;
    try { today = new Intl.DateTimeFormat('en-CA', { timeZone: DATA.tz || 'UTC' }).format(new Date()); }
    catch (e) { const d = new Date(); today = ymd(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()); }
    return today < META.bis ? today : META.bis;
  }

  function applyPreset(v) {
    const an = anchor(), ad = toDate(an), ay = +an.slice(0, 4), am = +an.slice(5, 7);
    let m;
    if (v === 'today') setRange(an, an);
    else if (v === 'yesterday') { const g = toStr(ad - DAY); setRange(g, g); }
    else if (v === 'last7') setRange(toStr(ad - 6 * DAY), an);
    else if (v === 'last30') setRange(toStr(ad - 29 * DAY), an);
    else if (v === 'last90') setRange(toStr(ad - 89 * DAY), an);
    else if (v === 'thismonth') { m = monthRange(ay, am); setRange(m[0], m[1]); }
    else if (v === 'lastmonth') { m = am === 1 ? monthRange(ay - 1, 12) : monthRange(ay, am - 1); setRange(m[0], m[1]); }
    else if (v === 'thisyear') setRange(ymd(ay, 1, 1), ymd(ay, 12, 31));
    else if (v === 'lastyear') setRange(ymd(ay - 1, 1, 1), ymd(ay - 1, 12, 31));
    else if (v === 'all') setRange(META.von, META.bis);
    else if (v === 'window') setRange(WIN.von, WIN.bis); // loaded window (no reload)
    else if (/^year:/.test(v)) { const y = +v.slice(5); setRange(ymd(y, 1, 1), ymd(y, 12, 31)); }
    // 'custom' -> no action (manual from/to input)
  }

  // Only show custom inputs (from/to/month) in "custom" mode.
  function toggleCustom() { const c = $('w-custom'); if (c) c.hidden = ($('w-preset').value !== 'custom'); }

  function buildPresets() {
    const sel = $('w-preset'); if (!sel) return;
    const fullData = (WIN.von <= META.von && WIN.bis >= META.bis);
    const winDays = Math.round((toDate(WIN.bis) - toDate(WIN.von)) / DAY) + 1;
    const opt = [];
    // Default entry reflects the initially loaded state (no reload on display).
    if (fullData) opt.push(['all', t('preset.all', 'Entire period')]);
    else opt.push(['window', tf('preset.window', 'Last %s days', winDays)]);
    opt.push(['today', t('preset.today', 'Today')], ['yesterday', t('preset.yesterday', 'Yesterday')],
      ['last7', t('preset.last7', 'Last 7 days')], ['last30', t('preset.last30', 'Last 30 days')],
      ['last90', t('preset.last90', 'Last 90 days')],
      ['thismonth', t('preset.thisMonth', 'This month')], ['lastmonth', t('preset.lastMonth', 'Last month')],
      ['thisyear', t('preset.thisYear', 'This year')], ['lastyear', t('preset.lastYear', 'Last year')]);
    const y0 = +META.von.slice(0, 4), y1 = +META.bis.slice(0, 4);
    for (let y = y1; y >= y0; y--) opt.push(['year:' + y, tf('preset.year', 'Year %s', y)]); // concrete years from the dataset
    if (!fullData) opt.push(['all', t('preset.all', 'Entire period')]);
    opt.push(['custom', t('preset.custom', 'Custom …')]);
    sel.innerHTML = opt.map(function (o) { return '<option value="' + o[0] + '">' + esc(o[1]) + '</option>'; }).join('');
    sel.value = opt[0][0]; // default = loaded state
    sel.onchange = function () { toggleCustom(); if (sel.value !== 'custom') applyPreset(sel.value); };
    toggleCustom();
  }

  function onManualDate() { const p = $('w-preset'); if (p) p.value = 'custom'; toggleCustom(); onDateChange(); }
  $('w-from').onchange = $('w-to').onchange = onManualDate;

  // Jump directly to a specific month (YYYY-MM).
  if ($('w-month')) {
    $('w-month').min = META.von.slice(0, 7); $('w-month').max = META.bis.slice(0, 7);
    $('w-month').onchange = function () {
      const val = $('w-month').value; if (!val) return;
      const m = monthRange(+val.slice(0, 4), +val.slice(5, 7)); setRange(m[0], m[1]);
    };
  }

  buildPresets();
}
