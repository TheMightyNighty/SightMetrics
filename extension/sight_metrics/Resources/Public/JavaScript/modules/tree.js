/* SightMetrics – page tree: server-side segmented (CubeRepository::urlTree),
   lazy-loaded per branch. Rows arrive pre-sorted + capped per level; expanding
   a branch loads its children once, "+ N more" paginates. */

import { esc } from './util.js';

const TREE_LIMIT = 8;

/**
 * @param {any} ctx dashboard context (createContext())
 * @returns {{ reload: (a: string, b: string) => void, state: any }}
 */
export function createTree(ctx) {
  const { DATA, WIN, i18n, $ } = ctx;
  const t = i18n.t, tf = i18n.tf, nf = i18n.nf;
  const url = DATA.treeUrl || null;
  const TREE = {
    rows: (DATA.tree && DATA.tree.rows) || [],
    total: (DATA.tree && DATA.tree.total) || { count: 0 },
    from: WIN.von, to: WIN.bis, loading: false,
  };

  function fetchLevel(path, a, b, offset, depth) {
    if (!url) return Promise.resolve({ rows: [], total: { count: 0 } });
    return ctx.fetchJson(url, {
      path: path, from: a, to: b,
      limit: String(TREE_LIMIT), offset: String(offset), depth: String(depth || 1),
    });
  }

  // Renders a tree level. max is the largest pv of the topmost level (bar
  // widths remain globally comparable).
  function paintLevel(container, state, max, depth) {
    container.innerHTML = '';
    state.rows.forEach(function (node) {
      const row = document.createElement('div'); row.className = 'tnode';
      const tog = document.createElement('span'); tog.className = 'tog' + (node.hasChildren ? '' : ' leaf'); tog.textContent = node.hasChildren ? '▸' : '•';
      const lbl = document.createElement('span'); lbl.className = 'lbl'; lbl.title = node.path; lbl.textContent = node.seg + (node.hasChildren ? '/' : '');
      const bar = document.createElement('span'); bar.className = 'bar'; bar.style.width = Math.max(2, Math.round(120 * node.pv / max)) + 'px';
      const num = document.createElement('span'); num.className = 'num'; num.textContent = nf(node.pv);
      row.appendChild(tog); row.appendChild(lbl); row.appendChild(bar); row.appendChild(num); container.appendChild(row);
      if (!node.hasChildren) return;

      tog.setAttribute('role', 'button'); tog.setAttribute('tabindex', '0');
      const open = depth < 1; // first level expanded (children are preloaded)
      const ch = document.createElement('div'); ch.className = 'children' + (open ? ' open' : '');
      container.appendChild(ch);
      tog.textContent = open ? '▾' : '▸';
      tog.setAttribute('aria-expanded', open ? 'true' : 'false');
      let childState = null;
      function buildChildren() {
        childState = {
          path: node.path,
          rows: node.children || [],
          total: node.childTotal || { count: node.children ? node.children.length : 0 },
          loading: !node.children,
        };
        paintLevel(ch, childState, max, depth + 1);
        if (!node.children) {
          fetchLevel(node.path, TREE.from, TREE.to, 0).then(function (res) {
            node.children = res.rows || []; node.childTotal = res.total || { count: 0 };
            childState.rows = node.children; childState.total = node.childTotal; childState.loading = false;
            paintLevel(ch, childState, max, depth + 1);
          }).catch(function () { childState.loading = false; paintLevel(ch, childState, max, depth + 1); });
        }
      }
      if (open) buildChildren();
      const toggleBranch = function () {
        if (!childState) buildChildren();
        const o = ch.classList.toggle('open');
        tog.textContent = o ? '▾' : '▸';
        tog.setAttribute('aria-expanded', o ? 'true' : 'false');
      };
      tog.onclick = toggleBranch;
      tog.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleBranch(); } };
    });

    const remaining = (state.total.count || 0) - state.rows.length;
    if (state.loading) {
      const l = document.createElement('div'); l.className = 'bl-more'; l.textContent = t('loading', 'loading …'); container.appendChild(l);
    } else if (remaining > 0) {
      const m = document.createElement('div'); m.className = 'bl-more bl-more-click';
      m.textContent = tf('more', '+ %s more', nf(remaining));
      m.setAttribute('role', 'button'); m.tabIndex = 0;
      const loadMore = function () {
        state.loading = true; paintLevel(container, state, max, depth);
        fetchLevel(state.path, TREE.from, TREE.to, state.rows.length).then(function (res) {
          state.rows = state.rows.concat(res.rows || []); state.total = res.total || state.total; state.loading = false;
          paintLevel(container, state, max, depth);
        }).catch(function () { state.loading = false; paintLevel(container, state, max, depth); });
      };
      m.onclick = loadMore;
      m.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); loadMore(); } };
      container.appendChild(m);
    } else if (!state.rows.length) {
      container.innerHTML = '<div class="bl-more">' + esc(t('noData', 'no data')) + '</div>';
    }
  }

  function renderRoot() {
    const tc = $('w-tree'); if (!tc) return;
    const max = TREE.rows.length ? TREE.rows[0].pv : 1;
    paintLevel(tc, { path: '', rows: TREE.rows, total: TREE.total, loading: TREE.loading }, max, 0);
  }

  // Date change: reload the root (2 levels); expanded deeper branches are
  // discarded. Race guard as in Top-N.
  function reload(a, b) {
    renderRoot();
    if (TREE.from === a && TREE.to === b) return;
    TREE.loading = true; TREE.from = a; TREE.to = b;
    renderRoot();
    fetchLevel('', a, b, 0, 2).then(function (res) {
      if (TREE.from !== a || TREE.to !== b) return;
      TREE.rows = res.rows || []; TREE.total = res.total || { count: 0 }; TREE.loading = false;
      renderRoot();
    }).catch(function () {
      if (TREE.from !== a || TREE.to !== b) return;
      TREE.loading = false; renderRoot();
    });
  }

  // state is a stable reference (reloads mutate .rows); the CSV export reads it.
  return { reload: reload, state: TREE };
}
