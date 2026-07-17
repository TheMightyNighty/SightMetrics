/* SightMetrics – server-side Top-N bar lists with drill-down + "+ N more"
   lazy loading (CubeRepository::topN / TopNAjaxController). State that spans
   date changes lives in a per-dim entry of the returned controller. */

import { esc } from './util.js';
import { rowEl } from './barlist.js';

// Root dimensions, server-side limited to Top-N. Country stays out (choropleth
// map needs all countries); "child" marks dims with a drill-down child.
export const TOPN_ROOT = {
  keyword: { id: 'bl-keyword', metric: 'v' },
  entry: { id: 'bl-entry', metric: 'v' },
  exit: { id: 'bl-exit', metric: 'v' },
  download: { id: 'bl-download', metric: 'pv' },
  status: { id: 'bl-status', metric: 'pv' },
  method: { id: 'bl-method', metric: 'pv' },
  browser: { id: 'bl-browser', metric: 'v', child: 'browser_version', limit: 8 },
  os: { id: 'bl-os', metric: 'v', child: 'os_version', limit: 8 },
  device: { id: 'bl-device', metric: 'v', child: 'device_model', limit: 8 },
  referrer_type: { id: 'bl-reftype', metric: 'v', child: 'referrer_name', limit: 8 },
  // Standalone flat list; the same dimension is also reachable as a child of referrer_name.
  referrer_url: { id: 'bl-refurl', metric: 'v', limit: 10 },
};
// Child dimensions: only reachable via parentKey, never in the initial payload.
export const TOPN_CHILD = {
  browser_version: { metric: 'v' },
  os_version: { metric: 'v' },
  device_model: { metric: 'v' },
  referrer_name: { metric: 'v', child: 'referrer_url' },
  referrer_url: { metric: 'v' },
};

/**
 * @param {any} ctx dashboard context (createContext())
 * @returns {{ TOPN: Record<string, any>, reloadAll: (a: string, b: string, windowLabel?: string|null) => void, allLoaded: () => boolean }}
 */
export function createTopN(ctx) {
  const { DATA, META, WIN, i18n, $ } = ctx;
  const t = i18n.t, tf = i18n.tf, nf = i18n.nf;
  const url = DATA.topNUrl || null;
  let curA = WIN.von, curB = WIN.bis; // currently selected range (for child fetches)
  let curWindow = null; // preset label of the current range (w-preset value), see reloadAll()

  /** @type {Record<string, any>} dim -> {rows, total:{pv,v,count}, metric, from, to, loading, loaded, limit} */
  const TOPN = {};
  Object.keys(TOPN_ROOT).forEach(function (dim) {
    const meta = TOPN_ROOT[dim];
    TOPN[dim] = {
      dim: dim,
      rows: [],
      total: { pv: 0, v: 0, count: 0 },
      metric: meta.metric,
      limit: meta.limit || 8,
      // Root dims are no longer preloaded in the initial payload (see
      // DashboardController) -- always start in "loading" so the first paint
      // shows the loading indicator instead of a one-tick "no data" flash.
      from: WIN.von, to: WIN.bis, loading: true, loaded: false,
    };
  });

  function fetchRows(dim, a, b, offset, limit, parentKey, windowLabel) {
    if (!url) return Promise.resolve({ rows: [], total: { pv: 0, v: 0, count: 0 } });
    const params = { dim: dim, from: a, to: b, limit: String(limit), offset: String(offset) };
    if (parentKey != null) params.parentKey = parentKey;
    // Preset label of [a,b] if known (docs/topn-precompute-spec.md); the server
    // verifies it against a/b itself, so passing a stale/wrong value is harmless
    // (falls back to the live query), never produces wrong data.
    if (windowLabel != null) params.window = windowLabel;
    return ctx.fetchJson(url, params);
  }

  // Two-stage initial fetch (offset=0 only -- "+ N more" pagination stays a
  // single fetchRows() call, see paint()): first the single most recent
  // COMPLETE day (META.bis -- not calendar "today", which the day-boundary
  // cut leaves empty until the next night's import), always cheap regardless
  // of total cube size; then the real requested range in the background.
  // onStage(res, 'fast'|'final') is called for each response that arrives,
  // in order (a slow 'fast' response arriving after 'final' is dropped by
  // the caller via the loaded flag, not here). Returns the 'final' promise,
  // so callers can .catch() it the same way they did the single fetchRows().
  function fetchTwoStage(dim, a, b, limit, parentKey, windowLabel, onStage) {
    const anchor = META && META.bis;
    if (anchor && !(a === anchor && b === anchor)) {
      fetchRows(dim, anchor, anchor, 0, limit, parentKey, null)
        .then(function (res) { onStage(res, 'fast'); })
        .catch(function () { /* fast stage is best-effort, the final fetch below is what counts */ });
    }
    return fetchRows(dim, a, b, 0, limit, parentKey, windowLabel).then(function (res) {
      onStage(res, 'final');
      return res;
    });
  }

  // Shared renderer for Top-N rows (root OR child) + "+ N more" lazy loading.
  function paint(cont, state, rowFactory) {
    cont.innerHTML = '';
    const rows = state.rows;
    if (!rows.length && !state.loading) { cont.innerHTML = '<div class="bl-more">' + esc(t('noData', 'no data')) + '</div>'; return; }
    const total = state.total[state.metric] || 1, max = rows.length ? rows[0][state.metric] : 1;
    rows.forEach(function (r) { rowFactory(cont, r, total, max); });
    const remaining = state.total.count - rows.length;
    if (state.loading) {
      const l = document.createElement('div'); l.className = 'bl-more'; l.textContent = t('loading', 'loading …'); cont.appendChild(l);
    } else if (remaining > 0) {
      const m = document.createElement('div'); m.className = 'bl-more bl-more-click';
      m.textContent = tf('more', '+ %s more', nf(remaining));
      m.setAttribute('role', 'button'); m.tabIndex = 0;
      const loadMore = function () {
        state.loading = true; paint(cont, state, rowFactory);
        fetchRows(state.dim, state.from, state.to, state.rows.length, state.limit, state.parentKey, state.window).then(function (res) {
          state.rows = state.rows.concat(res.rows || []); state.total = res.total || state.total; state.loading = false;
          paint(cont, state, rowFactory);
        }).catch(function () { state.loading = false; paint(cont, state, rowFactory); });
      };
      m.onclick = loadMore;
      m.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); loadMore(); } };
      cont.appendChild(m);
    }
  }

  // Builds a rowFactory for a given dim; if a child exists (meta.child) attaches
  // an expand handler that lazy-loads via Ajax on first click.
  function rowFactory(dim, meta) {
    return function (cont, r, total, max) {
      let label = r.dimkey; // SCHEMA v2: dimkey is the plain value, parents live in their own column
      if (dim === 'referrer_type') label = i18n.refTypeLabel(label);
      const row = rowEl(ctx, label, r[meta.metric], total, max, esc, !!meta.child);
      cont.appendChild(row);
      if (!meta.child) return;
      const sub = document.createElement('div'); sub.className = 'bl-sub'; sub.style.display = 'none';
      row.insertAdjacentElement('afterend', sub);
      let built = false;
      const lbl = /** @type {any} */ (row.querySelector('.bl-label'));
      function toggleSub() {
        if (!built) {
          built = true;
          const childMeta = TOPN_CHILD[meta.child];
          const childState = {
            dim: meta.child, from: curA, to: curB, parentKey: r.dimkey, window: curWindow,
            rows: [], total: { pv: 0, v: 0, count: 0 }, metric: childMeta.metric, limit: 8, loading: true, loaded: false,
          };
          const childFactory = rowFactory(meta.child, childMeta);
          paint(sub, childState, childFactory);
          fetchTwoStage(childState.dim, childState.from, childState.to, childState.limit, childState.parentKey, childState.window, function (res, stage) {
            const rows = res.rows || [];
            if (stage === 'fast') {
              // Late-arriving fast response after final already landed, or a
              // genuinely empty day (that parent may just not occur today) --
              // either way don't overwrite the more complete/accurate state.
              if (childState.loaded || !rows.length) return;
              childState.rows = rows; childState.total = res.total || childState.total;
              paint(sub, childState, childFactory);
              return;
            }
            childState.rows = rows; childState.total = res.total || childState.total;
            childState.loading = false; childState.loaded = true;
            paint(sub, childState, childFactory);
          }).catch(function () { childState.loading = false; paint(sub, childState, childFactory); });
        }
        const open = sub.style.display === 'none';
        sub.style.display = open ? 'block' : 'none';
        row.querySelector('.bl-tog').textContent = open ? '▾' : '▸';
        lbl.setAttribute('aria-expanded', open ? 'true' : 'false');
      }
      lbl.onclick = toggleSub;
      lbl.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleSub(); } };
    };
  }

  function renderRoot(dim) {
    const meta = TOPN_ROOT[dim], cont = $(meta.id); if (!cont) return;
    paint(cont, TOPN[dim], rowFactory(dim, meta));
  }

  // On date change (including the very first call, from dashboard.js's initial
  // render()): show current state immediately, reload each list via the
  // two-stage fetch for [a,b] on a differing (or not-yet-loaded) range. Race
  // guard via st.from/st.to. A full re-render discards expanded child lists
  // (consistent with prior behavior).
  // windowLabel: the active preset (w-preset value), if any -- passed through
  // to fetchRows so the server can serve from the precomputed `topn` table
  // (docs/topn-precompute-spec.md); irrelevant/wrong values are simply ignored
  // server-side, so this never needs to be exact.
  function reloadAll(a, b, windowLabel) {
    curA = a; curB = b; curWindow = windowLabel == null ? null : windowLabel;
    Object.keys(TOPN_ROOT).forEach(function (dim) {
      const st = TOPN[dim];
      renderRoot(dim);
      if (st.loaded && st.from === a && st.to === b) return;
      st.loading = true; st.loaded = false; st.from = a; st.to = b; st.window = curWindow;
      renderRoot(dim);
      fetchTwoStage(dim, a, b, st.limit, null, curWindow, function (res, stage) {
        if (st.from !== a || st.to !== b) return; // superseded by a newer range change
        const rows = res.rows || [];
        if (stage === 'fast') {
          if (st.loaded || !rows.length) return; // see toggleSub() for the same guard
          st.rows = rows; st.total = res.total || st.total;
          renderRoot(dim);
          return;
        }
        st.rows = rows; st.total = res.total || { pv: 0, v: 0, count: 0 };
        st.loading = false; st.loaded = true;
        renderRoot(dim);
      }).catch(function () {
        if (st.from !== a || st.to !== b) return;
        st.loading = false; renderRoot(dim);
      });
    });
  }

  /** True once every root dim's accurate ("final") data has loaded at least once. */
  function allLoaded() {
    return Object.keys(TOPN_ROOT).every(function (dim) { return TOPN[dim].loaded; });
  }

  return { TOPN: TOPN, reloadAll: reloadAll, allLoaded: allLoaded };
}
