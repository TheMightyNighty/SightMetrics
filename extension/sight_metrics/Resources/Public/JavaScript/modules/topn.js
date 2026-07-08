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
 * @returns {{ TOPN: Record<string, any>, reloadAll: (a: string, b: string) => void }}
 */
export function createTopN(ctx) {
  const { DATA, WIN, i18n, $ } = ctx;
  const t = i18n.t, tf = i18n.tf, nf = i18n.nf;
  const url = DATA.topNUrl || null;
  let curA = WIN.von, curB = WIN.bis; // currently selected range (for child fetches)

  /** @type {Record<string, any>} dim -> {rows, total:{pv,v,count}, metric, from, to, loading, limit} */
  const TOPN = {};
  Object.keys(TOPN_ROOT).forEach(function (dim) {
    const meta = TOPN_ROOT[dim], t0 = (DATA.topN && DATA.topN[dim]) || {};
    TOPN[dim] = {
      dim: dim,
      rows: (t0.rows || []).slice(),
      total: t0.total || { pv: 0, v: 0, count: 0 },
      metric: t0.metric || meta.metric,
      limit: t0.limit || meta.limit || 8,
      from: WIN.von, to: WIN.bis, loading: false,
    };
  });

  function fetchRows(dim, a, b, offset, limit, parentKey) {
    if (!url) return Promise.resolve({ rows: [], total: { pv: 0, v: 0, count: 0 } });
    const params = { dim: dim, from: a, to: b, limit: String(limit), offset: String(offset) };
    if (parentKey != null) params.parentKey = parentKey;
    return ctx.fetchJson(url, params);
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
        fetchRows(state.dim, state.from, state.to, state.rows.length, state.limit, state.parentKey).then(function (res) {
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
            dim: meta.child, from: curA, to: curB, parentKey: r.dimkey,
            rows: [], total: { pv: 0, v: 0, count: 0 }, metric: childMeta.metric, limit: 8, loading: true,
          };
          const childFactory = rowFactory(meta.child, childMeta);
          paint(sub, childState, childFactory);
          fetchRows(childState.dim, childState.from, childState.to, 0, childState.limit, childState.parentKey)
            .then(function (res) {
              childState.rows = res.rows || []; childState.total = res.total || childState.total; childState.loading = false;
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

  // On date change: show current state immediately, reload each list via Ajax
  // for [a,b] on a differing range. Race guard via st.from/st.to. A full
  // re-render discards expanded child lists (consistent with prior behavior).
  function reloadAll(a, b) {
    curA = a; curB = b;
    Object.keys(TOPN_ROOT).forEach(function (dim) {
      const st = TOPN[dim];
      renderRoot(dim);
      if (st.from === a && st.to === b) return;
      st.loading = true; st.from = a; st.to = b;
      renderRoot(dim);
      fetchRows(dim, a, b, 0, st.limit).then(function (res) {
        if (st.from !== a || st.to !== b) return; // superseded by a newer range change
        st.rows = res.rows || []; st.total = res.total || { pv: 0, v: 0, count: 0 }; st.loading = false;
        renderRoot(dim);
      }).catch(function () {
        if (st.from !== a || st.to !== b) return;
        st.loading = false; renderRoot(dim);
      });
    });
  }

  return { TOPN: TOPN, reloadAll: reloadAll };
}
