/* SightMetrics – Leaflet choropleth world map. The Chart.js choropleth plugin
   (chartjs-chart-geo) turned out too immature; Leaflet + L.geoJSON stays. The
   map and GeoJSON layer persist across renders (only restyle/rebind). */

import { esc, lerpColor } from './util.js';
import { chartColors, isDark } from './charts.js';

// ISO-2 -> country name in the world map geodata (world.js, world-atlas/Natural
// Earth). Names must match properties.name exactly. US/KR/CZ etc. differ from
// the everyday name.
const ISO2NAME = { US: 'United States of America', CN: 'China', JP: 'Japan', KR: 'South Korea', DE: 'Germany', GB: 'United Kingdom',
  FR: 'France', IN: 'India', BR: 'Brazil', CA: 'Canada', RU: 'Russia', IT: 'Italy', ES: 'Spain', NL: 'Netherlands',
  PL: 'Poland', TR: 'Turkey', SE: 'Sweden', CH: 'Switzerland', AT: 'Austria', BE: 'Belgium', AU: 'Australia',
  MX: 'Mexico', ID: 'Indonesia', ZA: 'South Africa', EG: 'Egypt', NG: 'Nigeria', AR: 'Argentina', VN: 'Vietnam',
  TH: 'Thailand', UA: 'Ukraine', RO: 'Romania', GR: 'Greece', PT: 'Portugal', NO: 'Norway', FI: 'Finland',
  DK: 'Denmark', IE: 'Ireland', SG: 'Singapore', MY: 'Malaysia', PK: 'Pakistan', BD: 'Bangladesh', PH: 'Philippines',
  SA: 'Saudi Arabia', AE: 'United Arab Emirates', IL: 'Israel', CZ: 'Czechia', HU: 'Hungary', CL: 'Chile',
  CO: 'Colombia', NZ: 'New Zealand', TW: 'Taiwan', HK: 'Hong Kong', KE: 'Kenya', MA: 'Morocco' };

/**
 * @param {any} ctx dashboard context (createContext())
 * @returns {{ render: (a: string, b: string) => void, invalidate: () => void }}
 */
export function createMap(ctx) {
  const { i18n } = ctx;
  const t = i18n.t, nf = i18n.nf;
  let leafletMap = null, mapLayer = null, mapLegend = null;

  function render(a, b) {
    if (typeof window.SM_WORLD === 'undefined' || typeof L === 'undefined') return;
    const rows = ctx.agg('country', a, b, 'v').filter(function (/** @type {any} */ r) { return r.key !== '??'; });
    /** @type {Record<string, number>} */
    const byName = {};
    rows.forEach(function (/** @type {any} */ r) { byName[ISO2NAME[r.key] || r.key] = r.v; });
    const max = rows.reduce(function (/** @type {number} */ m, /** @type {any} */ r) { return Math.max(m, r.v); }, 1);
    const cc = chartColors();
    // Gradient adapted to the theme: a light-mode blue has too little contrast on
    // a dark map background, hence its own lighter steps.
    const LO = isDark() ? '#3a5a80' : '#9cc0e0', HI = isDark() ? '#8fc4ff' : '#0d3b6b';
    // Square-root scaling: with strongly dominant countries, others would otherwise
    // stay stuck at the lightest step.
    function fillFor(v) {
      if (!v) return cc.mapArea;
      const s = max ? Math.sqrt(v / max) : 0;
      return lerpColor(LO, HI, Math.max(0, Math.min(1, s)));
    }
    function valueFor(f) {
      const name = f.properties && (f.properties.name || f.properties.NAME) || '';
      return byName[name] || 0;
    }
    if (!leafletMap) {
      // preferCanvas: avoids faint horizontal seam lines that Leaflet's SVG
      // renderer produces at internal tile-grid boundaries when there is no
      // base tile layer underneath (pure vector choropleth, no basemap).
      leafletMap = L.map('w-map', { zoomControl: true, attributionControl: false, minZoom: 1, maxZoom: 6, worldCopyJump: true, preferCanvas: true })
        .setView([20, 12], 1.4);
    }
    if (mapLayer) { leafletMap.removeLayer(mapLayer); }
    mapLayer = L.geoJSON(window.SM_WORLD, {
      style: function (f) {
        return { fillColor: fillFor(valueFor(f)), fillOpacity: 1, color: cc.mapBorder, weight: .5 };
      },
      onEachFeature: function (f, layer) {
        const name = (f.properties && (f.properties.name || f.properties.NAME)) || '';
        const v = valueFor(f);
        layer.bindTooltip(esc(name) + ': ' + nf(v) + ' ' + esc(t('visits', 'Visits')), { sticky: true });
        layer.on('mouseover', function () { layer.setStyle({ weight: 1.5, color: '#b9851d' }); });
        layer.on('mouseout', function () { layer.setStyle({ weight: .5, color: cc.mapBorder }); });
      },
    }).addTo(leafletMap);

    if (mapLegend) { leafletMap.removeControl(mapLegend); }
    mapLegend = L.control({ position: 'bottomright' });
    mapLegend.onAdd = function () {
      const div = L.DomUtil.create('div', 'sm-map-legend');
      const steps = 5, grad = [];
      for (let i = 0; i <= steps; i++) grad.push(lerpColor(LO, HI, i / steps));
      div.innerHTML = '<div class="sm-map-legend-bar" style="background:linear-gradient(90deg,' + grad.join(',') + ')"></div>'
        + '<div class="sm-map-legend-lbl"><span>0</span><span>' + nf(max) + '</span></div>';
      return div;
    };
    mapLegend.addTo(leafletMap);
    leafletMap.invalidateSize();
  }

  function invalidate() { if (leafletMap) leafletMap.invalidateSize(); }

  return { render: render, invalidate: invalidate };
}
