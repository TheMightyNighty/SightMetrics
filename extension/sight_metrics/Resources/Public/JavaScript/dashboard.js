/* SightMetrics - TYPO3 backend module (native ES module, loaded via
   Configuration/JavaScriptModules.php). Reads the CSP-safe JSON data block
   (read-only DBAL from the cube DB) and renders it client-side. Matomo-like:
   bar lists with drill-down (click -> subtable) + choropleth world map.
   Chart.js/Leaflet/world.js remain classic (global) vendor scripts. */
import { DAY, esc, fmtBytes, hex2rgb, inR, lerpColor, toDate, toStr } from './modules/util.js';
import { createI18n } from './modules/i18n.js';
import { createCsvExport } from './modules/export.js';

(function () {
  'use strict';
  var DATA = null, el0 = document.getElementById('sm-data');
  try { DATA = el0 ? JSON.parse(el0.textContent) : (window.SM_DATA || null); }
  catch (e) { DATA = window.SM_DATA || null; }
  if (!DATA) return;
  var i18n = createI18n(DATA);
  var t = i18n.t, tf = i18n.tf, nf = i18n.nf, landName = i18n.landName;
  var META = DATA.meta || {};
  var DAILY = (DATA.daily || []).map(function (d) {
    return {datum: d.datum, visits: +d.visits || 0, pageviews: +d.pageviews || 0,
            uniques: +d.uniques || 0, bounces: +d.bounces || 0, bytes: +d.bytes || 0};
  });
  var CUBE = (DATA.cube || []).map(function (r) {
    return {datum: r.datum, dim: r.dim, key: r.dimkey, pv: +r.pv || 0, v: +r.v || 0};
  });

  // Root dimensions, server-side limited to Top-N (ROADMAP.md "Top-N + lazy loading",
  // phase 1+2). Country deliberately stays out (choropleth map needs all countries, ISO
  // cardinality is limited anyway); "child" marks dims with a drill-down child.
  var TOPN_ROOT = {
    keyword: {id: 'bl-keyword', metric: 'v'},
    entry: {id: 'bl-entry', metric: 'v'},
    exit: {id: 'bl-exit', metric: 'v'},
    download: {id: 'bl-download', metric: 'pv'},
    status: {id: 'bl-status', metric: 'pv'},
    method: {id: 'bl-method', metric: 'pv'},
    browser: {id: 'bl-browser', metric: 'v', child: 'browser_version', limit: 8},
    os: {id: 'bl-os', metric: 'v', child: 'os_version', limit: 8},
    device: {id: 'bl-device', metric: 'v', child: 'device_model', limit: 8},
    referrer_type: {id: 'bl-reftype', metric: 'v', child: 'referrer_name', limit: 8},
    // Standalone flat list (all referrer_url rows, not grouped by parent) --
    // the same dimension is additionally reachable as a child of referrer_name (see below).
    referrer_url: {id: 'bl-refurl', metric: 'v', limit: 10},
  };
  // Child dimensions: only reachable via parentKey, never in the initial payload.
  var TOPN_CHILD = {
    browser_version: {metric: 'v'},
    os_version: {metric: 'v'},
    device_model: {metric: 'v'},
    referrer_name: {metric: 'v', child: 'referrer_url'},
    referrer_url: {metric: 'v'},
  };
  var TOPN_URL = DATA.topNUrl || null;
  var TOPN_WIN = DATA.window || {von: META.von, bis: META.bis};
  var CUR_A = TOPN_WIN.von, CUR_B = TOPN_WIN.bis; // currently selected time range (for child fetches)
  /** @type {Record<string, any>} dim -> {rows, total:{pv,v,count}, metric, from, to, loading, limit} */
  var TOPN = {};
  Object.keys(TOPN_ROOT).forEach(function (dim) {
    var meta = TOPN_ROOT[dim], t = (DATA.topN && DATA.topN[dim]) || {};
    TOPN[dim] = {
      dim: dim,
      rows: (t.rows || []).slice(),
      total: t.total || {pv: 0, v: 0, count: 0},
      metric: t.metric || meta.metric,
      limit: t.limit || meta.limit || 8,
      from: TOPN_WIN.von, to: TOPN_WIN.bis, loading: false,
    };
  });

  function topNFetch(dim, a, b, offset, limit, parentKey) {
    if (!TOPN_URL) return Promise.resolve({rows: [], total: {pv: 0, v: 0, count: 0}});
    var u = new URL(TOPN_URL, location.href);
    u.searchParams.set('dim', dim);
    u.searchParams.set('from', a);
    u.searchParams.set('to', b);
    u.searchParams.set('limit', String(limit));
    u.searchParams.set('offset', String(offset));
    if (parentKey != null) u.searchParams.set('parentKey', parentKey);
    if (DATA.siteId) u.searchParams.set('site', String(DATA.siteId));
    return fetch(u.toString(), {credentials: 'same-origin'}).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  // Shared renderer for Top-N rows (root OR child) + "+ N more" lazy-loading.
  // rowFactory(cont, row, total, max) builds/appends the row (decides
  // drillability); state needs {dim, from, to, parentKey, rows, total, metric, limit, loading}.
  function paintTopN(cont, state, rowFactory) {
    cont.innerHTML = '';
    var rows = state.rows;
    if (!rows.length && !state.loading) { cont.innerHTML = '<div class="bl-more">' + esc(t('noData', 'no data')) + '</div>'; return; }
    var total = state.total[state.metric] || 1, max = rows.length ? rows[0][state.metric] : 1;
    rows.forEach(function (r) { rowFactory(cont, r, total, max); });
    var remaining = state.total.count - rows.length;
    if (state.loading) {
      var l = document.createElement('div'); l.className = 'bl-more'; l.textContent = t('loading', 'loading …'); cont.appendChild(l);
    } else if (remaining > 0) {
      var m = document.createElement('div'); m.className = 'bl-more bl-more-click';
      m.textContent = tf('more', '+ %s more', nf(remaining));
      m.setAttribute('role', 'button'); m.tabIndex = 0;
      var loadMore = function () {
        state.loading = true; paintTopN(cont, state, rowFactory);
        topNFetch(state.dim, state.from, state.to, state.rows.length, state.limit, state.parentKey).then(function (res) {
          state.rows = state.rows.concat(res.rows || []); state.total = res.total || state.total; state.loading = false;
          paintTopN(cont, state, rowFactory);
        }).catch(function () { state.loading = false; paintTopN(cont, state, rowFactory); });
      };
      m.onclick = loadMore;
      m.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); loadMore(); } };
      cont.appendChild(m);
    }
  }

  // Builds a rowFactory for a given dim (root or child); if a child exists
  // (meta.child), attaches an expand handler that lazy-loads via Ajax on first click.
  function topNRowFactory(dim, meta) {
    return function (cont, r, total, max) {
      var label = r.dimkey; // SCHEMA v2: dimkey is the plain value, parents live in their own column
      // referrer_type values are German data values from the cube -> localize.
      if (dim === 'referrer_type') label = i18n.refTypeLabel(label);
      var row = rowEl(label, r[meta.metric], total, max, esc, !!meta.child);
      cont.appendChild(row);
      if (!meta.child) return;
      var sub = document.createElement('div'); sub.className = 'bl-sub'; sub.style.display = 'none';
      row.insertAdjacentElement('afterend', sub);
      var built = false, lbl = /** @type {any} */ (row.querySelector('.bl-label'));
      function toggleSub() {
        if (!built) {
          built = true;
          var childMeta = TOPN_CHILD[meta.child];
          var childState = {
            dim: meta.child, from: CUR_A, to: CUR_B, parentKey: r.dimkey,
            rows: [], total: {pv: 0, v: 0, count: 0}, metric: childMeta.metric, limit: 8, loading: true,
          };
          var childFactory = topNRowFactory(meta.child, childMeta);
          paintTopN(sub, childState, childFactory);
          topNFetch(childState.dim, childState.from, childState.to, 0, childState.limit, childState.parentKey)
            .then(function (res) {
              childState.rows = res.rows || []; childState.total = res.total || childState.total; childState.loading = false;
              paintTopN(sub, childState, childFactory);
            }).catch(function () { childState.loading = false; paintTopN(sub, childState, childFactory); });
        }
        var open = sub.style.display === 'none';
        sub.style.display = open ? 'block' : 'none';
        row.querySelector('.bl-tog').textContent = open ? '▾' : '▸';
        lbl.setAttribute('aria-expanded', open ? 'true' : 'false');
      }
      lbl.onclick = toggleSub;
      lbl.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleSub(); } };
    };
  }

  function renderTopNRoot(dim) {
    var meta = TOPN_ROOT[dim], cont = $(meta.id); if (!cont) return;
    paintTopN(cont, TOPN[dim], topNRowFactory(dim, meta));
  }

  // On date change: show current state immediately, on a differing time range
  // reload the Top-N list via Ajax for [a,b] (offset 0). Race guard via st.from/st.to,
  // in case the time range changes again while a fetch is in flight. A
  // full re-render (paintTopN via renderTopNRoot) always discards any
  // expanded child lists in the process -- consistent with the previous drill-down behavior.
  function reloadTopNAll(a, b) {
    CUR_A = a; CUR_B = b;
    Object.keys(TOPN_ROOT).forEach(function (dim) {
      var st = TOPN[dim];
      renderTopNRoot(dim);
      if (st.from === a && st.to === b) return;
      st.loading = true; st.from = a; st.to = b;
      renderTopNRoot(dim);
      topNFetch(dim, a, b, 0, st.limit).then(function (res) {
        if (st.from !== a || st.to !== b) return; // superseded by a newer time range change
        st.rows = res.rows || []; st.total = res.total || {pv: 0, v: 0, count: 0}; st.loading = false;
        renderTopNRoot(dim);
      }).catch(function () {
        if (st.from !== a || st.to !== b) return;
        st.loading = false; renderTopNRoot(dim);
      });
    });
  }

  // ISO-2 -> country name in the world map geodata (world.js, Leaflet choropleth)
  // Names must match properties.name in world.js exactly (world-atlas/Natural Earth,
  // see Vendor/NOTICE.md). US/KR/CZ differ from the everyday name.
  var ISO2NAME = {US:'United States of America',CN:'China',JP:'Japan',KR:'South Korea',DE:'Germany',GB:'United Kingdom',
    FR:'France',IN:'India',BR:'Brazil',CA:'Canada',RU:'Russia',IT:'Italy',ES:'Spain',NL:'Netherlands',
    PL:'Poland',TR:'Turkey',SE:'Sweden',CH:'Switzerland',AT:'Austria',BE:'Belgium',AU:'Australia',
    MX:'Mexico',ID:'Indonesia',ZA:'South Africa',EG:'Egypt',NG:'Nigeria',AR:'Argentina',VN:'Vietnam',
    TH:'Thailand',UA:'Ukraine',RO:'Romania',GR:'Greece',PT:'Portugal',NO:'Norway',FI:'Finland',
    DK:'Denmark',IE:'Ireland',SG:'Singapore',MY:'Malaysia',PK:'Pakistan',BD:'Bangladesh',PH:'Philippines',
    SA:'Saudi Arabia',AE:'United Arab Emirates',IL:'Israel',CZ:'Czechia',HU:'Hungary',CL:'Chile',
    CO:'Colombia',NZ:'New Zealand',TW:'Taiwan',HK:'Hong Kong',KE:'Kenya',MA:'Morocco'};
  var PAL = ['#15508c', '#2f8f5b', '#b9851d'];
  var charts = {};
  /** DOM shorthand; deliberately 'any' (returns input/canvas/select depending on id).
      @type {(id: string) => any} */
  var $ = function (id) { return document.getElementById(id); };
  // (Re-)create the Chart.js instance: simpler than a partial update, data volume is small.
  function setChart(id, config) {
    if (charts[id]) charts[id].destroy();
    charts[id] = new Chart($(id).getContext('2d'), config);
    return charts[id];
  }
  // Dark mode: TYPO3 backend scheme (data-color-scheme on html/body, possibly in the parent document)
  // preferred, otherwise OS setting (prefers-color-scheme).
  function isDark() {
    try {
      var docs = [document, window.parent && window.parent !== window ? window.parent.document : null];
      for (var i = 0; i < docs.length; i++) {
        var d = docs[i]; if (!d) continue;
        var cs = (d.documentElement && d.documentElement.getAttribute('data-color-scheme'))
          || (d.body && d.body.getAttribute('data-color-scheme'));
        if (cs === 'dark') { return true; }
        if (cs === 'light') { return false; }
      }
    } catch (e) { /* cross-origin: ignore, fallback below */ }
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }
  // Axis/text colors for Chart.js depending on the scheme (default dark gray would be unreadable on dark).
  // Also sets Chart.defaults, so elements without an explicit color
  // (e.g. the world map's color scale legend) follow the theme instead of Chart.js's default (black).
  function chartColors() {
    var cc = isDark()
      ? {text: '#c7d0db', line: '#3a4250', mapArea: '#323a45', mapBorder: '#475063', tooltipBg: '#1a1f27'}
      : {text: '#1d2733', line: '#e3e8ef', mapArea: '#f4f6f9', mapBorder: '#cdd6e0', tooltipBg: '#1d2733'};
    if (typeof Chart !== 'undefined') {
      Chart.defaults.color = cc.text;
      Chart.defaults.borderColor = cc.line;
      Chart.defaults.plugins.tooltip.backgroundColor = cc.tooltipBg;
      Chart.defaults.plugins.tooltip.titleColor = '#fff';
      Chart.defaults.plugins.tooltip.bodyColor = '#fff';
    }
    return cc;
  }
  // --- Period comparison -------------------------------------------------
  // Immediately preceding time range of the same length, clamped to available data.
  function prevRange(a, b) {
    var len = Math.round((toDate(b) - toDate(a)) / DAY) + 1;
    var pb = toDate(a) - DAY, pa = pb - (len - 1) * DAY;
    var min = toDate(META.von);
    if (pa < min) return null;                 // no complete previous period available
    return [toStr(pa), toStr(pb)];
  }
  // Write a delta badge into a KPI element (arrow + percent, colored by direction).
  function setDelta(id, cur, prev, invert) {
    var elx = $(id); if (!elx) return;
    if (prev == null) { elx.textContent = ''; elx.className = 'd'; return; }
    if (prev === 0) { elx.textContent = cur > 0 ? t('new', 'new') : '±0'; elx.className = 'd flat'; return; }
    var pct = 100 * (cur - prev) / prev, up = pct > 0.05, down = pct < -0.05;
    var good = invert ? down : up;             // for bounce rate, "down" is good
    elx.className = 'd ' + (up ? 'up' : down ? 'down' : 'flat') + (good ? ' good' : (up || down ? ' bad' : ''));
    elx.textContent = (up ? '▲ ' : down ? '▼ ' : '± ') + i18n.pct1(pct) + ' %';
  }
  function dailySum(a, b, k) {
    return DAILY.reduce(function (s, d) { return inR(d.datum, a, b) ? s + d[k] : s; }, 0);
  }

  function agg(dim, a, b, metric) {
    var map = {};
    for (var i = 0; i < CUBE.length; i++) {
      var r = CUBE[i];
      if (r.dim !== dim || !inR(r.datum, a, b) || r.key == null || r.key === '') continue;
      if (!map[r.key]) map[r.key] = {key: r.key, pv: 0, v: 0};
      map[r.key].pv += r.pv; map[r.key].v += r.v;
    }
    return Object.keys(map).map(function (k) { return map[k]; }).sort(function (x, y) { return y[metric] - x[metric]; });
  }
  function rowEl(label, val, total, max, fmt, drillable) {
    var pct = 100 * val / total, w = Math.max(2, 100 * val / max);
    var row = document.createElement('div'); row.className = 'bl-row' + (drillable ? ' bl-drill' : '');
    row.innerHTML = '<div class="bl-label" title="' + esc(label) + '"'
      + (drillable ? ' role="button" tabindex="0" aria-expanded="false"' : '') + '>'
      + '<span class="bl-bar" style="width:' + w.toFixed(1) + '%"></span>'
      + '<span class="bl-text">' + (drillable ? '<span class="bl-tog" aria-hidden="true">▸</span> ' : '') + fmt(label) + '</span></div>'
      + '<div class="bl-val">' + nf(val) + '</div><div class="bl-pct">' + pct.toFixed(1) + '%</div>';
    return row;
  }

  // Only still used for country (no more client-side drill-down children -- browser/OS/
  // device/referrer type run via renderTopNRoot(), see above).
  function renderInto(container, rows, metric, fmt, limit) {
    var total = rows.reduce(function (s, r) { return s + r[metric]; }, 0) || 1;
    var top = rows.slice(0, limit), max = top.length ? top[0][metric] : 1;
    top.forEach(function (r) {
      container.appendChild(rowEl(r.key, r[metric], total, max, fmt, false));
    });
    if (rows.length > limit) { var m = document.createElement('div'); m.className = 'bl-more'; m.textContent = tf('more', '+ %s more', nf(rows.length - limit)); container.appendChild(m); }
    if (!top.length) container.innerHTML = '<div class="bl-more">' + esc(t('noData', 'no data')) + '</div>';
  }

  function barlist(id, dim, a, b, metric, opts) {
    opts = opts || {};
    var cont = $(id); if (!cont) return; cont.innerHTML = '';
    renderInto(cont, agg(dim, a, b, metric), metric, opts.fmt || esc, opts.limit || 8);
  }

  // Leaflet map + GeoJSON layer persist across renders (only restyle/rebind),
  // the Chart.js choropleth plugin (chartjs-chart-geo) turned out to be too immature
  // (countries weren't colored, no mouseover, no discernible JS error).
  var leafletMap = null, mapLayer = null, mapLegend = null;
  // Hex -> [r,g,b] and linearly interpolated; continuous scale instead of fixed steps,
  // so the coloring actually appears proportional to the visit count.
  function renderMap(a, b) {
    if (typeof window.SM_WORLD === 'undefined' || typeof L === 'undefined') return;
    var rows = agg('country', a, b, 'v').filter(function (r) { return r.key !== '??'; });
    var byName = {};
    rows.forEach(function (r) { byName[ISO2NAME[r.key] || r.key] = r.v; });
    var max = rows.reduce(function (m, r) { return Math.max(m, r.v); }, 1);
    var cc = chartColors();
    // Gradient adapted to the theme: in dark mode, a blue tone intended for light mode
    // has too little contrast on a dark map background, hence its own, lighter steps.
    var LO = isDark() ? '#3a5a80' : '#9cc0e0', HI = isDark() ? '#8fc4ff' : '#0d3b6b';
    // Square-root scaling: with strongly dominant individual countries (e.g. one country = 50%+
    // of all visits), almost all other countries would otherwise stay stuck at the lightest step.
    function fillFor(v) {
      if (!v) return cc.mapArea;
      var t = max ? Math.sqrt(v / max) : 0;
      return lerpColor(LO, HI, Math.max(0, Math.min(1, t)));
    }
    function valueFor(f) {
      var name = f.properties && (f.properties.name || f.properties.NAME) || '';
      return byName[name] || 0;
    }
    if (!leafletMap) {
      leafletMap = L.map('w-map', {zoomControl: true, attributionControl: false, minZoom: 1, maxZoom: 6, worldCopyJump: true})
        .setView([20, 12], 1.4);
    }
    if (mapLayer) { leafletMap.removeLayer(mapLayer); }
    mapLayer = L.geoJSON(window.SM_WORLD, {
      style: function (f) {
        return {fillColor: fillFor(valueFor(f)), fillOpacity: 1, color: cc.mapBorder, weight: .5};
      },
      onEachFeature: function (f, layer) {
        var name = (f.properties && (f.properties.name || f.properties.NAME)) || '';
        var v = valueFor(f);
        layer.bindTooltip(esc(name) + ': ' + nf(v) + ' ' + esc(t('visits', 'Visits')), {sticky: true});
        layer.on('mouseover', function () { layer.setStyle({weight: 1.5, color: '#b9851d'}); });
        layer.on('mouseout', function () { layer.setStyle({weight: .5, color: cc.mapBorder}); });
      }
    }).addTo(leafletMap);

    if (mapLegend) { leafletMap.removeControl(mapLegend); }
    mapLegend = L.control({position: 'bottomright'});
    mapLegend.onAdd = function () {
      var div = L.DomUtil.create('div', 'sm-map-legend');
      var steps = 5, grad = [];
      for (var i = 0; i <= steps; i++) grad.push(lerpColor(LO, HI, i / steps));
      div.innerHTML = '<div class="sm-map-legend-bar" style="background:linear-gradient(90deg,' + grad.join(',') + ')"></div>'
        + '<div class="sm-map-legend-lbl"><span>0</span><span>' + nf(max) + '</span></div>';
      return div;
    };
    mapLegend.addTo(leafletMap);
    leafletMap.invalidateSize();
  }

  // --- Page tree: server-side segmented (CubeRepository::urlTree), lazy-loaded ---
  // Rows come pre-sorted + capped per level from the server; expanding a branch
  // loads its children once via Ajax (path prefix), "+ N more" paginates.
  var TREE_URL = DATA.treeUrl || null;
  var TREE_LIMIT = 8;
  var TREE = {
    rows: (DATA.tree && DATA.tree.rows) || [],
    total: (DATA.tree && DATA.tree.total) || {count: 0},
    from: TOPN_WIN.von, to: TOPN_WIN.bis, loading: false,
  };

  function treeFetch(path, a, b, offset, depth) {
    if (!TREE_URL) return Promise.resolve({rows: [], total: {count: 0}});
    var u = new URL(TREE_URL, location.href);
    u.searchParams.set('path', path);
    u.searchParams.set('from', a);
    u.searchParams.set('to', b);
    u.searchParams.set('limit', String(TREE_LIMIT));
    u.searchParams.set('offset', String(offset));
    u.searchParams.set('depth', String(depth || 1));
    if (DATA.siteId) u.searchParams.set('site', String(DATA.siteId));
    return fetch(u.toString(), {credentials: 'same-origin'}).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  // Renders a tree level from state = {path, rows, total:{count}, loading}. max is the
  // largest pv of the topmost level (bar widths remain globally comparable as before).
  function paintTreeLevel(container, state, max, depth) {
    container.innerHTML = '';
    state.rows.forEach(function (node) {
      var row = document.createElement('div'); row.className = 'tnode';
      var tog = document.createElement('span'); tog.className = 'tog' + (node.hasChildren ? '' : ' leaf'); tog.textContent = node.hasChildren ? '▸' : '•';
      var lbl = document.createElement('span'); lbl.className = 'lbl'; lbl.title = node.path; lbl.textContent = node.seg + (node.hasChildren ? '/' : '');
      var bar = document.createElement('span'); bar.className = 'bar'; bar.style.width = Math.max(2, Math.round(120 * node.pv / max)) + 'px';
      var num = document.createElement('span'); num.className = 'num'; num.textContent = nf(node.pv);
      row.appendChild(tog); row.appendChild(lbl); row.appendChild(bar); row.appendChild(num); container.appendChild(row);
      if (!node.hasChildren) return;

      tog.setAttribute('role', 'button'); tog.setAttribute('tabindex', '0');
      var open = depth < 1; // first level expanded as before (children are preloaded)
      var ch = document.createElement('div'); ch.className = 'children' + (open ? ' open' : '');
      container.appendChild(ch);
      tog.textContent = open ? '▾' : '▸';
      tog.setAttribute('aria-expanded', open ? 'true' : 'false');
      var childState = null;
      function buildChildren() {
        childState = {
          path: node.path,
          rows: node.children || [],
          total: node.childTotal || {count: node.children ? node.children.length : 0},
          loading: !node.children,
        };
        paintTreeLevel(ch, childState, max, depth + 1);
        if (!node.children) {
          treeFetch(node.path, TREE.from, TREE.to, 0).then(function (res) {
            node.children = res.rows || []; node.childTotal = res.total || {count: 0};
            childState.rows = node.children; childState.total = node.childTotal; childState.loading = false;
            paintTreeLevel(ch, childState, max, depth + 1);
          }).catch(function () { childState.loading = false; paintTreeLevel(ch, childState, max, depth + 1); });
        }
      }
      if (open) buildChildren();
      var toggleBranch = function () {
        if (!childState) buildChildren();
        var o = ch.classList.toggle('open');
        tog.textContent = o ? '▾' : '▸';
        tog.setAttribute('aria-expanded', o ? 'true' : 'false');
      };
      tog.onclick = toggleBranch;
      tog.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleBranch(); } };
    });

    var remaining = (state.total.count || 0) - state.rows.length;
    if (state.loading) {
      var l = document.createElement('div'); l.className = 'bl-more'; l.textContent = t('loading', 'loading …'); container.appendChild(l);
    } else if (remaining > 0) {
      var m = document.createElement('div'); m.className = 'bl-more bl-more-click';
      m.textContent = tf('more', '+ %s more', nf(remaining));
      m.setAttribute('role', 'button'); m.tabIndex = 0;
      var loadMore = function () {
        state.loading = true; paintTreeLevel(container, state, max, depth);
        treeFetch(state.path, TREE.from, TREE.to, state.rows.length).then(function (res) {
          state.rows = state.rows.concat(res.rows || []); state.total = res.total || state.total; state.loading = false;
          paintTreeLevel(container, state, max, depth);
        }).catch(function () { state.loading = false; paintTreeLevel(container, state, max, depth); });
      };
      m.onclick = loadMore;
      m.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); loadMore(); } };
      container.appendChild(m);
    } else if (!state.rows.length) {
      container.innerHTML = '<div class="bl-more">' + esc(t('noData', 'no data')) + '</div>';
    }
  }

  function renderTreeRoot() {
    var tc = $('w-tree'); if (!tc) return;
    var max = TREE.rows.length ? TREE.rows[0].pv : 1;
    paintTreeLevel(tc, {path: '', rows: TREE.rows, total: TREE.total, loading: TREE.loading}, max, 0);
  }

  // Date change: reload the root (2 levels); expanded deeper branches are
  // discarded in the process -- consistent with the Top-N bar list behavior. Race guard as there.
  function reloadTree(a, b) {
    renderTreeRoot();
    if (TREE.from === a && TREE.to === b) return;
    TREE.loading = true; TREE.from = a; TREE.to = b;
    renderTreeRoot();
    treeFetch('', a, b, 0, 2).then(function (res) {
      if (TREE.from !== a || TREE.to !== b) return;
      TREE.rows = res.rows || []; TREE.total = res.total || {count: 0}; TREE.loading = false;
      renderTreeRoot();
    }).catch(function () {
      if (TREE.from !== a || TREE.to !== b) return;
      TREE.loading = false; renderTreeRoot();
    });
  }

  function render() {
    var a = $('w-from').value, b = $('w-to').value;
    var days = DAILY.filter(function (d) { return inR(d.datum, a, b); });
    var sum = function (k) { return days.reduce(function (s, d) { return s + d[k]; }, 0); };
    var visits = sum('visits'), bounces = sum('bounces'), full = (a <= META.von && b >= META.bis);
    var bounceRate = visits ? 100 * bounces / visits : 0;
    $('k-visits').textContent = nf(visits);
    $('k-uniq').textContent = (full ? '' : '~') + nf(full ? (META.uniques_total || sum('uniques')) : sum('uniques'));
    $('k-pv').textContent = nf(sum('pageviews'));
    $('k-bounce').textContent = visits ? bounceRate.toFixed(1) + ' %' : '–';
    $('k-band').textContent = fmtBytes(sum('bytes'));

    // Period comparison: deltas against the immediately preceding period of the same length.
    var cmp = $('w-cmp') && $('w-cmp').checked ? prevRange(a, b) : null;
    if (cmp) {
      var pa = cmp[0], pb = cmp[1], pVisits = dailySum(pa, pb, 'visits');
      var pBounceRate = pVisits ? 100 * dailySum(pa, pb, 'bounces') / pVisits : 0;
      setDelta('d-visits', visits, pVisits);
      setDelta('d-uniq', sum('uniques'), dailySum(pa, pb, 'uniques'));
      setDelta('d-pv', sum('pageviews'), dailySum(pa, pb, 'pageviews'));
      setDelta('d-bounce', bounceRate, pVisits ? pBounceRate : null, true);
      setDelta('d-band', sum('bytes'), dailySum(pa, pb, 'bytes'));
    } else {
      ['d-visits', 'd-uniq', 'd-pv', 'd-bounce', 'd-band'].forEach(function (id) { setDelta(id, 0, null); });
    }

    /** @type {Array<any>} */
    var tDatasets = [
      {label: t('pageviews', 'Page views'), data: days.map(function (d) { return d.pageviews; }), borderColor: PAL[0], backgroundColor: PAL[0] + '14', fill: true, tension: .3, pointRadius: 0},
      {label: t('visits', 'Visits'), data: days.map(function (d) { return d.visits; }), borderColor: PAL[1], fill: false, tension: .3, pointRadius: 0},
      {label: t('uniques', 'Unique visitors'), data: days.map(function (d) { return d.uniques; }), borderColor: PAL[2], fill: false, tension: .3, pointRadius: 0}];
    if (cmp) {
      // Previous period position-wise (day 1 to day 1) as a dashed reference for page views.
      var pdays = DAILY.filter(function (d) { return inR(d.datum, cmp[0], cmp[1]); });
      tDatasets.push({label: t('pageviewsPrev', 'Page views (previous period)'), borderColor: '#9aa7b6', borderDash: [4, 3], fill: false, tension: .3, pointRadius: 0,
        data: days.map(function (_, i) { return pdays[i] ? pdays[i].pageviews : null; })});
    }
    var cc = chartColors();
    setChart('w-time', {
      type: 'line',
      data: {labels: days.map(function (d) { return d.datum; }), datasets: tDatasets},
      options: {responsive: true, maintainAspectRatio: false, interaction: {mode: 'index', intersect: false},
        plugins: {legend: {position: 'bottom', labels: {color: cc.text}}, tooltip: {mode: 'index', intersect: false}},
        scales: {
          x: {grid: {color: cc.line}, ticks: {color: cc.text}},
          y: {beginAtZero: true, grid: {color: cc.line}, ticks: {color: cc.text}}
        }
      }
    });

    var hours = agg('hour', a, b, 'pv'), hmap = {}; hours.forEach(function (r) { hmap[r.key] = r.pv; });
    var hx = []; for (var i = 0; i < 24; i++) hx.push(('0' + i).slice(-2));
    setChart('w-hour', {
      type: 'bar',
      data: {labels: hx, datasets: [{label: t('pageviews', 'Page views'), data: hx.map(function (k) { return hmap[k] || 0; }), backgroundColor: PAL[0], borderRadius: 2}]},
      options: {responsive: true, maintainAspectRatio: false,
        plugins: {legend: {display: false}, tooltip: {mode: 'index', intersect: false}},
        scales: {
          x: {grid: {color: cc.line}, ticks: {color: cc.text}},
          y: {beginAtZero: true, grid: {color: cc.line}, ticks: {color: cc.text}}
        }
      }
    });

    renderMap(a, b);

    reloadTree(a, b); // page tree: server-side segmented + lazy-loaded

    barlist('bl-country', 'country', a, b, 'v', {fmt: function (k) { return esc(landName(k)); }});
    // Keyword/entry/exit/download/status/method/browser/OS/device/referrer type/URL:
    // server-side Top-N + lazy-loading (see TOPN_ROOT/TOPN_CHILD above).
    reloadTopNAll(a, b);
  }

  // --- Export (modules/export.js) ------------------------------------------
  // TREE/TOPN are stable object references (reloads only replace .rows/.total),
  // so passing them to the factory once is enough.
  var csvExport = createCsvExport({
    i18n: i18n, META: META, DAILY: DAILY,
    TOPN: TOPN, TOPN_ROOT: TOPN_ROOT, TREE: TREE, agg: agg,
  });
  function exportCsv() {
    csvExport.exportCsv($('w-from').value, $('w-to').value);
  }

  function init() {
    if (typeof Chart === 'undefined') return;
    if (isDark()) { var rootEl = document.getElementById('sightmetrics'); if (rootEl) rootEl.classList.add('sm-dark'); }
    $('w-site').textContent = META.site || 'SightMetrics';
    $('w-gen').textContent = META.erzeugt ? tf('asOf', 'As of: %s', META.erzeugt) : '';
    // Multi-site: fill the selector; switching reloads the module with ?site=<id>
    var sel = $('w-siteselect'), sites = DATA.sites || [];
    if (sel && sites.length) {
      sel.innerHTML = sites.map(function (s) {
        return '<option value="' + s.site_id + '"' + (+s.site_id === +DATA.siteId ? ' selected' : '') + '>' + esc(s.site) + '</option>';
      }).join('');
      sel.onchange = function () { var u = new URL(location.href); u.searchParams.set('site', sel.value); location.href = u.toString(); };
      if (sites.length < 2) sel.style.display = 'none';   // no selector needed with only one site
    }
    // The server only delivers one time window (DATA.window) -- this limits the transfer volume.
    // The picker, however, spans the entire dataset (meta.von/bis); a selection outside the
    // loaded window loads the matching window (reload), within it filters immediately.
    var WIN = DATA.window || {von: META.von, bis: META.bis};
    $('w-from').value = WIN.von; $('w-from').min = META.von; $('w-from').max = META.bis;
    $('w-to').value = WIN.bis; $('w-to').min = META.von; $('w-to').max = META.bis;
    function onDateChange() {
      var a = $('w-from').value, b = $('w-to').value;
      if (a && b && (a < WIN.von || b > WIN.bis)) {   // outside the loaded window -> reload
        var u = new URL(location.href);
        u.searchParams.set('from', a); u.searchParams.set('to', b);
        if (DATA.siteId) u.searchParams.set('site', DATA.siteId);
        location.href = u.toString(); return;
      }
      render();
    }
    // Set the time range (clamped to the dataset) and trigger evaluation/reload.
    function setRange(a, b) {
      a = a < META.von ? META.von : a; b = b > META.bis ? META.bis : b;
      $('w-from').value = a; $('w-to').value = b;
      onDateChange();
    }
    // --- Matomo-style time range presets -----------------------------------
    function ymd(y, m, d) { return y + '-' + ('0' + m).slice(-2) + '-' + ('0' + d).slice(-2); }
    function monthRange(y, m) { return [ymd(y, m, 1), toStr(Date.UTC(y, m, 0))]; }  // m = 1..12
    // Anchor for relative time ranges: today, but never after the latest data.
    // UTC instead of local browser time, consistent with 'datum' in the backend
    // (transform.sql: timezone('UTC', ...)).
    function anchor() {
      // "Today" in the site's bucketing timezone (DATA.tz = meta.tz, SCHEMA v2);
      // en-CA formats as YYYY-MM-DD. Fallback: UTC.
      var today;
      try { today = new Intl.DateTimeFormat('en-CA', {timeZone: DATA.tz || 'UTC'}).format(new Date()); }
      catch (e) { var t = new Date(); today = ymd(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()); }
      return today < META.bis ? today : META.bis;
    }
    function applyPreset(v) {
      var an = anchor(), ad = toDate(an), ay = +an.slice(0, 4), am = +an.slice(5, 7), m;
      if (v === 'today') setRange(an, an);
      else if (v === 'yesterday') { var g = toStr(ad - DAY); setRange(g, g); }
      else if (v === 'last7') setRange(toStr(ad - 6 * DAY), an);
      else if (v === 'last30') setRange(toStr(ad - 29 * DAY), an);
      else if (v === 'last90') setRange(toStr(ad - 89 * DAY), an);
      else if (v === 'thismonth') { m = monthRange(ay, am); setRange(m[0], m[1]); }
      else if (v === 'lastmonth') { m = am === 1 ? monthRange(ay - 1, 12) : monthRange(ay, am - 1); setRange(m[0], m[1]); }
      else if (v === 'thisyear') setRange(ymd(ay, 1, 1), ymd(ay, 12, 31));
      else if (v === 'lastyear') setRange(ymd(ay - 1, 1, 1), ymd(ay - 1, 12, 31));
      else if (v === 'all') setRange(META.von, META.bis);
      else if (v === 'window') setRange(WIN.von, WIN.bis);   // loaded window (no reload)
      else if (/^year:/.test(v)) { var y = +v.slice(5); setRange(ymd(y, 1, 1), ymd(y, 12, 31)); }
      // 'custom' -> no action (manual from/to input)
    }
    // Only show custom inputs (from/to/month) in "custom" mode --
    // otherwise only the single time range dropdown is visible (not side by side).
    function toggleCustom() { var c = $('w-custom'); if (c) c.hidden = ($('w-preset').value !== 'custom'); }
    function buildPresets() {
      var sel = $('w-preset'); if (!sel) return;
      var fullData = (WIN.von <= META.von && WIN.bis >= META.bis);
      var winDays = Math.round((toDate(WIN.bis) - toDate(WIN.von)) / DAY) + 1;
      var opt = [];
      // Default entry reflects the initially loaded state (no reload on display).
      if (fullData) opt.push(['all', t('preset.all', 'Entire period')]);
      else opt.push(['window', tf('preset.window', 'Last %s days', winDays)]);
      opt.push(['today', t('preset.today', 'Today')], ['yesterday', t('preset.yesterday', 'Yesterday')],
        ['last7', t('preset.last7', 'Last 7 days')], ['last30', t('preset.last30', 'Last 30 days')],
        ['last90', t('preset.last90', 'Last 90 days')],
        ['thismonth', t('preset.thisMonth', 'This month')], ['lastmonth', t('preset.lastMonth', 'Last month')],
        ['thisyear', t('preset.thisYear', 'This year')], ['lastyear', t('preset.lastYear', 'Last year')]);
      var y0 = +META.von.slice(0, 4), y1 = +META.bis.slice(0, 4);
      for (var y = y1; y >= y0; y--) opt.push(['year:' + y, tf('preset.year', 'Year %s', y)]);  // concrete years from the dataset
      if (!fullData) opt.push(['all', t('preset.all', 'Entire period')]);
      opt.push(['custom', t('preset.custom', 'Custom …')]);
      sel.innerHTML = opt.map(function (o) { return '<option value="' + o[0] + '">' + esc(o[1]) + '</option>'; }).join('');
      sel.value = opt[0][0];   // default = loaded state
      sel.onchange = function () { toggleCustom(); if (sel.value !== 'custom') applyPreset(sel.value); };
      toggleCustom();
    }
    function onManualDate() { var p = $('w-preset'); if (p) p.value = 'custom'; toggleCustom(); onDateChange(); }
    $('w-from').onchange = $('w-to').onchange = onManualDate;
    // Jump directly to a specific month (YYYY-MM).
    if ($('w-month')) {
      $('w-month').min = META.von.slice(0, 7); $('w-month').max = META.bis.slice(0, 7);
      $('w-month').onchange = function () {
        var val = $('w-month').value; if (!val) return;
        var m = monthRange(+val.slice(0, 4), +val.slice(5, 7)); setRange(m[0], m[1]);
      };
    }
    buildPresets();
    if ($('w-cmp')) $('w-cmp').onchange = render;
    if ($('w-csv')) $('w-csv').onclick = exportCsv;
    function resizeAll() {
      Object.keys(charts).forEach(function (k) { charts[k].resize(); });
      if (leafletMap) leafletMap.invalidateSize();
    }
    if ($('w-pdf')) $('w-pdf').onclick = function () {
      // Redraw charts before printing so the canvas size fits; then the browser print dialog.
      resizeAll();
      window.print();
    };
    window.addEventListener('resize', resizeAll);
    render();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
