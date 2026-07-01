/* SightMetrics – TYPO3-Backend-Modul. Liest den CSP-sicheren JSON-Datenblock
   (read-only DBAL aus der Cube-DB) und rendert client-seitig. Matomo-nah:
   Barlisten mit Drill-down (Klick -> Subtabelle) + Choropleth-Weltkarte. */
(function () {
  'use strict';
  var SEP = ''; // Eltern|Kind-Trenner aus dem Cube
  var DATA = null, el0 = document.getElementById('sm-data');
  try { DATA = el0 ? JSON.parse(el0.textContent) : (window.SM_DATA || null); }
  catch (e) { DATA = window.SM_DATA || null; }
  if (!DATA) return;
  var META = DATA.meta || {};
  var DAILY = (DATA.daily || []).map(function (d) {
    return {datum: d.datum, visits: +d.visits || 0, pageviews: +d.pageviews || 0,
            uniques: +d.uniques || 0, bounces: +d.bounces || 0, bytes: +d.bytes || 0};
  });
  var CUBE = (DATA.cube || []).map(function (r) {
    return {datum: r.datum, dim: r.dim, key: r.dimkey, pv: +r.pv || 0, v: +r.v || 0};
  });

  // Eltern-Dimension -> Kind-Dimension (Drill-down)
  var DRILL = {referrer_type: 'referrer_name', referrer_name: 'referrer_url',
               browser: 'browser_version', os: 'os_version', device: 'device_model'};
  // ISO-2 -> Name in der ECharts-Weltkarte
  var ISO2NAME = {US:'United States',CN:'China',JP:'Japan',KR:'Korea',DE:'Germany',GB:'United Kingdom',
    FR:'France',IN:'India',BR:'Brazil',CA:'Canada',RU:'Russia',IT:'Italy',ES:'Spain',NL:'Netherlands',
    PL:'Poland',TR:'Turkey',SE:'Sweden',CH:'Switzerland',AT:'Austria',BE:'Belgium',AU:'Australia',
    MX:'Mexico',ID:'Indonesia',ZA:'South Africa',EG:'Egypt',NG:'Nigeria',AR:'Argentina',VN:'Vietnam',
    TH:'Thailand',UA:'Ukraine',RO:'Romania',GR:'Greece',PT:'Portugal',NO:'Norway',FI:'Finland',
    DK:'Denmark',IE:'Ireland',SG:'Singapore',MY:'Malaysia',PK:'Pakistan',BD:'Bangladesh',PH:'Philippines',
    SA:'Saudi Arabia',AE:'United Arab Emirates',IL:'Israel',CZ:'Czech Rep.',HU:'Hungary',CL:'Chile',
    CO:'Colombia',NZ:'New Zealand',TW:'Taiwan',HK:'Hong Kong',KE:'Kenya',MA:'Morocco'};
  var LAND = {US:'USA',CN:'China',JP:'Japan',KR:'Südkorea',DE:'Deutschland',GB:'Großbritannien',
    FR:'Frankreich',PH:'Philippinen',IN:'Indien',BR:'Brasilien',CA:'Kanada',RU:'Russland',IT:'Italien',
    ES:'Spanien',NL:'Niederlande',PL:'Polen',TR:'Türkei',SE:'Schweden',CH:'Schweiz',AT:'Österreich',
    AU:'Australien',TW:'Taiwan',HK:'Hongkong','??':'Unbekannt'};

  var PAL = ['#15508c', '#2f8f5b', '#b9851d'];
  var charts = {}, mapReg = false;
  var $ = function (id) { return document.getElementById(id); };
  var nf = function (n) { return Number(n).toLocaleString('de-DE'); };
  var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c]; }); };
  var landName = function (c) { return LAND[c] || c; };
  function ec(id) { if (!charts[id]) charts[id] = echarts.init($(id)); return charts[id]; }
  // Dark Mode: TYPO3-Backend-Schema (data-color-scheme an html/body, ggf. im Eltern-Dokument)
  // bevorzugt, sonst OS-Einstellung (prefers-color-scheme).
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
    } catch (e) { /* Cross-Origin: ignorieren, Fallback unten */ }
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }
  // Achsen-/Textfarben fuer ECharts je nach Schema (Default-Dunkelgrau waere auf Dark unlesbar).
  function chartColors() {
    return isDark()
      ? {text: '#c7d0db', line: '#3a4250', mapArea: '#323a45', mapBorder: '#475063'}
      : {text: '#1d2733', line: '#e3e8ef', mapArea: '#f4f6f9', mapBorder: '#cdd6e0'};
  }
  function inR(d, a, b) { return d >= a && d <= b; }
  function fmtBytes(b) { return b >= 1e9 ? (b/1e9).toFixed(2)+' GB' : b >= 1e6 ? (b/1e6).toFixed(1)+' MB' : b >= 1e3 ? (b/1e3).toFixed(0)+' KB' : b+' B'; }

  // --- Perioden-Vergleich -------------------------------------------------
  var DAY = 86400000;
  function toDate(s) { var p = s.split('-'); return Date.UTC(+p[0], +p[1] - 1, +p[2]); }
  function toStr(ms) { var d = new Date(ms); return d.toISOString().slice(0, 10); }
  // Unmittelbar vorausgehender Zeitraum gleicher Länge, geklemmt auf verfügbare Daten.
  function prevRange(a, b) {
    var len = Math.round((toDate(b) - toDate(a)) / DAY) + 1;
    var pb = toDate(a) - DAY, pa = pb - (len - 1) * DAY;
    var min = toDate(META.von);
    if (pa < min) return null;                 // keine vollständige Vorperiode vorhanden
    return [toStr(pa), toStr(pb)];
  }
  // Delta-Badge in ein KPI-Element schreiben (Pfeil + Prozent, richtungsgefärbt).
  function setDelta(id, cur, prev, invert) {
    var elx = $(id); if (!elx) return;
    if (prev == null) { elx.textContent = ''; elx.className = 'd'; return; }
    if (prev === 0) { elx.textContent = cur > 0 ? 'neu' : '±0'; elx.className = 'd flat'; return; }
    var pct = 100 * (cur - prev) / prev, up = pct > 0.05, down = pct < -0.05;
    var good = invert ? down : up;             // bei Absprungrate ist "runter" gut
    elx.className = 'd ' + (up ? 'up' : down ? 'down' : 'flat') + (good ? ' good' : (up || down ? ' bad' : ''));
    elx.textContent = (up ? '▲ ' : down ? '▼ ' : '± ') + Math.abs(pct).toFixed(1).replace('.', ',') + ' %';
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
  function firstSeg(k) { var i = k.indexOf(SEP); return i < 0 ? k : k.slice(0, i); }
  function lastSeg(k) { var i = k.lastIndexOf(SEP); return i < 0 ? k : k.slice(i + 1); }
  // Kind-Zeilen (volle Keys) einer Eltern-Kategorie – Eltern via SEP kodiert
  function childrenOf(childDim, parentLabel, a, b, metric) {
    return agg(childDim, a, b, metric).filter(function (r) { return firstSeg(r.key) === parentLabel; });
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

  // Rekursiver Renderer: jede Zeile mit Kind-Dimension ist aufklappbar (N Ebenen)
  function renderInto(container, dim, rows, a, b, metric, fmt, limit) {
    var total = rows.reduce(function (s, r) { return s + r[metric]; }, 0) || 1;
    var top = rows.slice(0, limit), max = top.length ? top[0][metric] : 1;
    var childDim = DRILL[dim];
    top.forEach(function (r) {
      var label = lastSeg(r.key);
      var kids = childDim ? childrenOf(childDim, label, a, b, metric) : [];
      var row = rowEl(label, r[metric], total, max, fmt, kids.length > 0);
      container.appendChild(row);
      if (kids.length > 0) {
        var sub = document.createElement('div'); sub.className = 'bl-sub'; sub.style.display = 'none';
        container.appendChild(sub);
        var built = false;
        var lbl = row.querySelector('.bl-label');
        function toggleSub() {
          if (!built) { renderInto(sub, childDim, kids, a, b, metric, esc, 8); built = true; }
          var open = sub.style.display === 'none';
          sub.style.display = open ? 'block' : 'none';
          row.querySelector('.bl-tog').textContent = open ? '▾' : '▸';
          lbl.setAttribute('aria-expanded', open ? 'true' : 'false');
        }
        lbl.onclick = toggleSub;
        lbl.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleSub(); } };
      }
    });
    if (rows.length > limit) { var m = document.createElement('div'); m.className = 'bl-more'; m.textContent = '+ ' + (rows.length - limit) + ' weitere'; container.appendChild(m); }
    if (!top.length) container.innerHTML = '<div class="bl-more">keine Daten</div>';
  }

  function barlist(id, dim, a, b, metric, opts) {
    opts = opts || {};
    var cont = $(id); if (!cont) return; cont.innerHTML = '';
    renderInto(cont, dim, agg(dim, a, b, metric), a, b, metric, opts.fmt || esc, opts.limit || 8);
  }

  function renderMap(a, b) {
    if (typeof window.SM_WORLD === 'undefined') return;
    if (!mapReg) { echarts.registerMap('world', window.SM_WORLD); mapReg = true; }
    var rows = agg('country', a, b, 'v').filter(function (r) { return r.key !== '??'; });
    var data = rows.map(function (r) { return {name: ISO2NAME[r.key] || r.key, value: r.v}; });
    var max = data.reduce(function (m, d) { return Math.max(m, d.value); }, 1);
    var cc = chartColors();
    ec('w-map').setOption({
      tooltip: {trigger: 'item', formatter: function (p) { return p.name + ': ' + (p.value || 0) + ' Besuche'; }},
      visualMap: {min: 0, max: max, left: 8, bottom: 8, calculable: true,
        inRange: {color: ['#eaf1f8', '#9cc0e0', '#15508c']}, text: ['viele', '0'], textStyle: {fontSize: 10, color: cc.text}},
      series: [{type: 'map', map: 'world', roam: false, zoom: 1.15, scaleLimit: {min: 1, max: 6},
        itemStyle: {areaColor: cc.mapArea, borderColor: cc.mapBorder},
        emphasis: {itemStyle: {areaColor: '#b9851d'}, label: {show: false}},
        select: {disabled: true}, data: data}]
    }, true);
  }

  function buildTree(rows) {
    var root = {name: '/', pv: 0, children: {}};
    rows.forEach(function (r) {
      var parts = r.key.split('/').filter(Boolean), node = root, path = ''; root.pv += r.pv;
      parts.forEach(function (p) { path += '/' + p; if (!node.children[p]) node.children[p] = {name: p, path: path, pv: 0, children: {}}; node = node.children[p]; node.pv += r.pv; });
    });
    return root;
  }
  function renderTree(node, container, max, depth) {
    Object.keys(node.children).map(function (k) { return node.children[k]; }).sort(function (a, b) { return b.pv - a.pv; }).forEach(function (k) {
      var hasKids = Object.keys(k.children).length > 0;
      var row = document.createElement('div'); row.className = 'tnode';
      var tog = document.createElement('span'); tog.className = 'tog' + (hasKids ? '' : ' leaf'); tog.textContent = hasKids ? '▸' : '•';
      if (hasKids) { tog.setAttribute('role', 'button'); tog.setAttribute('tabindex', '0'); tog.setAttribute('aria-expanded', depth < 1 ? 'true' : 'false'); }
      var lbl = document.createElement('span'); lbl.className = 'lbl'; lbl.title = k.path; lbl.textContent = k.name + (hasKids ? '/' : '');
      var bar = document.createElement('span'); bar.className = 'bar'; bar.style.width = Math.max(2, Math.round(120 * k.pv / max)) + 'px';
      var num = document.createElement('span'); num.className = 'num'; num.textContent = nf(k.pv);
      row.appendChild(tog); row.appendChild(lbl); row.appendChild(bar); row.appendChild(num); container.appendChild(row);
      if (hasKids) {
        var ch = document.createElement('div'); ch.className = 'children' + (depth < 1 ? ' open' : ''); if (depth < 1) tog.textContent = '▾';
        renderTree(k, ch, max, depth + 1); container.appendChild(ch);
        tog.onclick = function () { var o = ch.classList.toggle('open'); tog.textContent = o ? '▾' : '▸'; tog.setAttribute('aria-expanded', o ? 'true' : 'false'); };
        tog.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); tog.onclick(); } };
      }
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

    // Perioden-Vergleich: Deltas gegen die unmittelbar vorausgehende Periode gleicher Länge.
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

    var tSeries = [
      {name: 'Seitenaufrufe', type: 'line', smooth: true, areaStyle: {opacity: .08}, data: days.map(function (d) { return d.pageviews; }), itemStyle: {color: PAL[0]}},
      {name: 'Besuche', type: 'line', smooth: true, data: days.map(function (d) { return d.visits; }), itemStyle: {color: PAL[1]}},
      {name: 'Eind. Besucher', type: 'line', smooth: true, data: days.map(function (d) { return d.uniques; }), itemStyle: {color: PAL[2]}}];
    var tLegend = ['Seitenaufrufe', 'Besuche', 'Eind. Besucher'];
    if (cmp) {
      // Vorperiode positionsweise (Tag 1 zu Tag 1) als gestrichelte Referenz der Seitenaufrufe.
      var pdays = DAILY.filter(function (d) { return inR(d.datum, cmp[0], cmp[1]); });
      tSeries.push({name: 'Seitenaufrufe (Vorperiode)', type: 'line', smooth: true, lineStyle: {type: 'dashed', width: 1.5},
        data: days.map(function (_, i) { return pdays[i] ? pdays[i].pageviews : null; }), itemStyle: {color: '#9aa7b6'}});
      tLegend.push('Seitenaufrufe (Vorperiode)');
    }
    var cc = chartColors();
    ec('w-time').setOption({textStyle: {color: cc.text}, tooltip: {trigger: 'axis'},
      legend: {bottom: 0, data: tLegend, textStyle: {color: cc.text}},
      grid: {left: 8, right: 18, top: 14, bottom: 34, containLabel: true},
      xAxis: {type: 'category', data: days.map(function (d) { return d.datum; }), axisLine: {lineStyle: {color: cc.line}}},
      yAxis: {type: 'value', splitLine: {lineStyle: {color: cc.line}}},
      series: tSeries}, true);

    var hours = agg('hour', a, b, 'pv'), hmap = {}; hours.forEach(function (r) { hmap[r.key] = r.pv; });
    var hx = []; for (var i = 0; i < 24; i++) hx.push(('0' + i).slice(-2));
    ec('w-hour').setOption({textStyle: {color: cc.text}, tooltip: {trigger: 'axis'},
      grid: {left: 8, right: 12, top: 10, bottom: 24, containLabel: true},
      xAxis: {type: 'category', data: hx, axisLine: {lineStyle: {color: cc.line}}},
      yAxis: {type: 'value', splitLine: {lineStyle: {color: cc.line}}},
      series: [{type: 'bar', data: hx.map(function (k) { return hmap[k] || 0; }), itemStyle: {color: PAL[0], borderRadius: 2}}]}, true);

    renderMap(a, b);

    var tc = $('w-tree'); tc.innerHTML = '';
    var urls = agg('url', a, b, 'pv'), tree = buildTree(urls);
    var tmax = Math.max.apply(null, Object.keys(tree.children).map(function (k) { return tree.children[k].pv; }).concat([1]));
    renderTree(tree, tc, tmax, 0);

    barlist('bl-country', 'country', a, b, 'v', {fmt: function (k) { return esc(landName(k)); }});
    barlist('bl-browser', 'browser', a, b, 'v');
    barlist('bl-os', 'os', a, b, 'v');
    barlist('bl-device', 'device', a, b, 'v');
    barlist('bl-reftype', 'referrer_type', a, b, 'v');
    barlist('bl-refurl', 'referrer_url', a, b, 'v', {limit: 10});
    barlist('bl-keyword', 'keyword', a, b, 'v');
    barlist('bl-entry', 'entry', a, b, 'v');
    barlist('bl-exit', 'exit', a, b, 'v');
    barlist('bl-download', 'download', a, b, 'pv');
    barlist('bl-status', 'status', a, b, 'pv');
    barlist('bl-method', 'method', a, b, 'pv');
  }

  // --- Export -------------------------------------------------------------
  // Dimensionen für den CSV-Export (Schlüssel im Cube -> lesbare Überschrift + Metrik).
  var EXPORT_DIMS = [
    ['country', 'Länder', 'v', landName], ['browser', 'Browser', 'v'], ['os', 'Betriebssystem', 'v'],
    ['device', 'Gerätetyp', 'v'], ['referrer_type', 'Referrer-Typen', 'v'], ['referrer_url', 'Referrer-URLs', 'v'],
    ['keyword', 'Suchbegriffe', 'v'], ['url', 'Seiten', 'pv'], ['entry', 'Einstiegsseiten', 'v'],
    ['exit', 'Ausstiegsseiten', 'v'], ['download', 'Downloads', 'pv'], ['status', 'Statuscodes', 'pv'],
    ['method', 'HTTP-Methoden', 'pv'], ['hour', 'Besuchszeiten (Stunde)', 'pv']];
  function csvCell(s) { s = String(s == null ? '' : s); return /[";\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
  function csvRow(arr) { return arr.map(csvCell).join(';'); }
  function buildCsv(a, b) {
    var L = [], days = DAILY.filter(function (d) { return inR(d.datum, a, b); });
    L.push(csvRow(['SightMetrics-Export']));
    L.push(csvRow(['Website', META.site || '']));
    L.push(csvRow(['Zeitraum', a, 'bis', b]));
    L.push(csvRow(['Stand', META.erzeugt || '']));
    L.push('');
    L.push(csvRow(['Verlauf (täglich)']));
    L.push(csvRow(['Datum', 'Besuche', 'Seitenaufrufe', 'Eind. Besucher', 'Absprünge', 'Bytes']));
    days.forEach(function (d) { L.push(csvRow([d.datum, d.visits, d.pageviews, d.uniques, d.bounces, d.bytes])); });
    EXPORT_DIMS.forEach(function (dd) {
      var rows = agg(dd[0], a, b, dd[2]).filter(function (r) { return r.key != null && r.key !== ''; });
      if (!rows.length) return;
      var label = dd[3] || function (x) { return x; };
      L.push('');
      L.push(csvRow([dd[1] + ' (' + (dd[2] === 'v' ? 'Besuche' : 'Seitenaufrufe') + ')']));
      L.push(csvRow(['Wert', dd[2] === 'v' ? 'Besuche' : 'Seitenaufrufe', 'Seitenaufrufe', 'Besuche']));
      rows.forEach(function (r) { L.push(csvRow([label(r.key.split(SEP).join(' › ')), r[dd[2]], r.pv, r.v])); });
    });
    return L.join('\r\n');
  }
  function download(name, text) {
    var blob = new Blob(['﻿' + text], {type: 'text/csv;charset=utf-8'});  // BOM für Excel
    var url = URL.createObjectURL(blob), a = document.createElement('a');
    a.href = url; a.download = name; document.body.appendChild(a); a.click();
    document.body.removeChild(a); setTimeout(function () { URL.revokeObjectURL(url); }, 0);
  }
  function slug(s) { return String(s || 'sightmetrics').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }
  function exportCsv() {
    var a = $('w-from').value, b = $('w-to').value;
    download('sightmetrics_' + slug(META.site) + '_' + a + '_' + b + '.csv', buildCsv(a, b));
  }

  function init() {
    if (typeof echarts === 'undefined') return;
    if (isDark()) { var rootEl = document.getElementById('sightmetrics'); if (rootEl) rootEl.classList.add('sm-dark'); }
    $('w-site').textContent = META.site || 'SightMetrics';
    $('w-gen').textContent = META.erzeugt ? 'Stand: ' + META.erzeugt : '';
    // Multi-Site: Auswahl füllen; Wechsel lädt das Modul mit ?site=<id> neu
    var sel = $('w-siteselect'), sites = DATA.sites || [];
    if (sel && sites.length) {
      sel.innerHTML = sites.map(function (s) {
        return '<option value="' + s.site_id + '"' + (+s.site_id === +DATA.siteId ? ' selected' : '') + '>' + esc(s.site) + '</option>';
      }).join('');
      sel.onchange = function () { var u = new URL(location.href); u.searchParams.set('site', sel.value); location.href = u.toString(); };
      if (sites.length < 2) sel.style.display = 'none';   // bei nur einer Site keine Auswahl nötig
    }
    // Server liefert nur ein Zeitfenster (DATA.window) – das begrenzt das Transfervolumen.
    // Der Picker spannt aber den ganzen Datenbestand (meta.von/bis); Auswahl ausserhalb des
    // geladenen Fensters laedt das passende Fenster nach (Reload), innerhalb wird sofort gefiltert.
    var WIN = DATA.window || {von: META.von, bis: META.bis};
    $('w-from').value = WIN.von; $('w-from').min = META.von; $('w-from').max = META.bis;
    $('w-to').value = WIN.bis; $('w-to').min = META.von; $('w-to').max = META.bis;
    function onDateChange() {
      var a = $('w-from').value, b = $('w-to').value;
      if (a && b && (a < WIN.von || b > WIN.bis)) {   // ausserhalb des geladenen Fensters -> nachladen
        var u = new URL(location.href);
        u.searchParams.set('from', a); u.searchParams.set('to', b);
        if (DATA.siteId) u.searchParams.set('site', DATA.siteId);
        location.href = u.toString(); return;
      }
      render();
    }
    // Zeitraum setzen (auf Datenbestand geklemmt) und Auswertung/Reload auslösen.
    function setRange(a, b) {
      a = a < META.von ? META.von : a; b = b > META.bis ? META.bis : b;
      $('w-from').value = a; $('w-to').value = b;
      onDateChange();
    }
    // --- Matomo-artige Zeitraum-Vorgaben -----------------------------------
    function ymd(y, m, d) { return y + '-' + ('0' + m).slice(-2) + '-' + ('0' + d).slice(-2); }
    function monthRange(y, m) { return [ymd(y, m, 1), toStr(Date.UTC(y, m, 0))]; }  // m = 1..12
    // Anker für relative Zeiträume: heute, aber nie nach dem neuesten Datenstand.
    // UTC (nicht lokale Browser-Zeit): das Backend speichert 'datum' konsequent in
    // UTC (transform.sql: timezone('UTC', ...)) - lokale Zeit haette in Zeitzonen
    // weit von UTC entfernt einen falschen Tag als "heute" ergeben.
    function anchor() {
      var t = new Date(), today = ymd(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
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
      else if (v === 'window') setRange(WIN.von, WIN.bis);   // geladenes Fenster (kein Reload)
      else if (/^year:/.test(v)) { var y = +v.slice(5); setRange(ymd(y, 1, 1), ymd(y, 12, 31)); }
      // 'custom' -> keine Aktion (manuelle von/bis-Eingabe)
    }
    // Custom-Eingaben (von/bis/Monat) nur im Modus „Benutzerdefiniert" zeigen –
    // sonst ist nur das eine Zeitraum-Dropdown sichtbar (nicht nebeneinander).
    function toggleCustom() { var c = $('w-custom'); if (c) c.hidden = ($('w-preset').value !== 'custom'); }
    function buildPresets() {
      var sel = $('w-preset'); if (!sel) return;
      var fullData = (WIN.von <= META.von && WIN.bis >= META.bis);
      var winDays = Math.round((toDate(WIN.bis) - toDate(WIN.von)) / DAY) + 1;
      var opt = [];
      // Default-Eintrag spiegelt den initial geladenen Stand wider (kein Reload beim Anzeigen).
      if (fullData) opt.push(['all', 'Gesamter Zeitraum']);
      else opt.push(['window', 'Letzte ' + winDays + ' Tage']);
      opt.push(['today', 'Heute'], ['yesterday', 'Gestern'],
        ['last7', 'Letzte 7 Tage'], ['last30', 'Letzte 30 Tage'], ['last90', 'Letzte 90 Tage'],
        ['thismonth', 'Dieser Monat'], ['lastmonth', 'Letzter Monat'],
        ['thisyear', 'Dieses Jahr'], ['lastyear', 'Letztes Jahr']);
      var y0 = +META.von.slice(0, 4), y1 = +META.bis.slice(0, 4);
      for (var y = y1; y >= y0; y--) opt.push(['year:' + y, 'Jahr ' + y]);  // konkrete Jahre aus dem Datenbestand
      if (!fullData) opt.push(['all', 'Gesamter Zeitraum']);
      opt.push(['custom', 'Benutzerdefiniert …']);
      sel.innerHTML = opt.map(function (o) { return '<option value="' + o[0] + '">' + o[1] + '</option>'; }).join('');
      sel.value = opt[0][0];   // Default = geladener Stand
      sel.onchange = function () { toggleCustom(); if (sel.value !== 'custom') applyPreset(sel.value); };
      toggleCustom();
    }
    function onManualDate() { var p = $('w-preset'); if (p) p.value = 'custom'; toggleCustom(); onDateChange(); }
    $('w-from').onchange = $('w-to').onchange = onManualDate;
    // Bestimmten Monat (YYYY-MM) direkt anspringen.
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
    if ($('w-pdf')) $('w-pdf').onclick = function () {
      // Charts vor dem Druck neu zeichnen, damit die Canvas-Größe passt; dann Browser-Druckdialog.
      Object.keys(charts).forEach(function (k) { charts[k].resize(); });
      window.print();
    };
    window.addEventListener('resize', function () { Object.keys(charts).forEach(function (k) { charts[k].resize(); }); });
    render();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
