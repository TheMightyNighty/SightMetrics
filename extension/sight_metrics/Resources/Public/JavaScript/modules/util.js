/* SightMetrics - pure helper functions (no DOM access, no state).
   Imported by dashboard.js and modules/export.js; individually testable. */

/** Parent|child separator in dimkey values -- exactly chr(31) like in
    ingestion/transform.sql and CubeRepository::CHILD_SEP. */
export const SEP = '\x1f';

/** One day in milliseconds (UTC date arithmetic). */
export const DAY = 86400000;

/** @param {unknown} s @returns {string} HTML-escaped */
export function esc(s) {
  return String(s).replace(/[&<>"]/g, function (c) {
    return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c] || c;
  });
}

/** @param {string} d @param {string} a @param {string} b ISO dates (lexicographically comparable) */
export function inR(d, a, b) { return d >= a && d <= b; }

/** @param {number} b bytes -> readable size */
export function fmtBytes(b) {
  return b >= 1e9 ? (b / 1e9).toFixed(2) + ' GB'
    : b >= 1e6 ? (b / 1e6).toFixed(1) + ' MB'
    : b >= 1e3 ? (b / 1e3).toFixed(0) + ' KB' : b + ' B';
}

/** @param {string} s ISO date -> UTC milliseconds */
export function toDate(s) { const p = s.split('-'); return Date.UTC(+p[0], +p[1] - 1, +p[2]); }

/** @param {number} ms UTC milliseconds -> ISO date */
export function toStr(ms) { return new Date(ms).toISOString().slice(0, 10); }

/** Last segment of a chr(31)-encoded dimkey (display without the parent prefix).
    @param {string} k */
export function lastSeg(k) { const i = k.lastIndexOf(SEP); return i < 0 ? k : k.slice(i + 1); }

/** @param {string} h '#rrggbb' -> [r,g,b] */
export function hex2rgb(h) { const n = parseInt(h.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }

/** Linearly interpolated color between two hex colors (t in [0,1]).
    @param {string} c0 @param {string} c1 @param {number} t */
export function lerpColor(c0, c1, t) {
  const a = hex2rgb(c0), b = hex2rgb(c1);
  const rgb = [0, 1, 2].map(function (i) { return Math.round(a[i] + (b[i] - a[i]) * t); });
  return 'rgb(' + rgb.join(',') + ')';
}

/** CSV cell: neutralize formula prefixes (CSV injection, url/referrer/keyword are
    attacker-controlled) and quote if needed. @param {unknown} s */
export function csvCell(s) {
  let v = String(s == null ? '' : s);
  if (/^[=+\-@]/.test(v)) v = "'" + v;
  return /[";\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
}

/** @param {Array<unknown>} arr */
export function csvRow(arr) { return arr.map(csvCell).join(';'); }

/** @param {string|undefined} s filename-safe slug */
export function slug(s) {
  return String(s || 'sightmetrics').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}
