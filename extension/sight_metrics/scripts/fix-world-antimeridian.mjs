#!/usr/bin/env node
// Repariert Antimeridian-Ueberquerungen in Resources/Public/Vendor/world.js.
//
// world-atlas/Natural-Earth-TopoJSON wird ohne Antimeridian-Cutting zu GeoJSON
// konvertiert (Standardverhalten von topojson-client): Polygon-Ringe von
// Laendern, die die 180-Grad-Laenge ueberqueren (Russland, Fiji, Antarktis),
// enthalten Punktfolgen, die z. B. von 179.87 direkt auf -180 springen.
// Leaflet zeichnet solche Ringe naiv in der flachen Lat/Lon-Darstellung und
// zieht dabei eine gerade Linie quer ueber die gesamte Kartenbreite -- sichtbar
// als breite horizontale Streifen im Choropleth (siehe ROADMAP/CHANGELOG).
//
// Fix: Ringe mit einer geraden Anzahl an Antimeridian-Uebergaengen werden am
// Antimeridian in mehrere in sich geschlossene Ringe gesplittet (Standard-Cut
// mit linearer Interpolation des Kreuzungspunkts). Antarktis wird komplett
// entfernt -- die Suedpol-Region hat eine komplexere Loch-Topologie (ein Ring
// wickelt sich um den Pol, ein zweiter schneidet die Landmasse als Loch aus),
// ist fuer Web-Analytics-Besucherdaten irrelevant und wird auch von vielen
// anderen Choropleth-Tools ausgelassen.
//
// Aufruf: node scripts/fix-world-antimeridian.mjs
// Wird nach jeder Neu-Erzeugung von world.js aus world-atlas benoetigt (siehe
// NOTICE.md); ist NICHT Teil von `npm run vendor:update` (dort werden nur
// Chart.js/Leaflet 1:1 kopiert, world.js ist ein separater manueller Schritt).

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const worldPath = join(root, 'Resources/Public/Vendor/world.js');

const raw = readFileSync(worldPath, 'utf8');
const prefixMatch = raw.match(/^window\.SM_WORLD=/);
if (!prefixMatch) {
    throw new Error('world.js hat nicht das erwartete Format (window.SM_WORLD=...)');
}
const prefix = prefixMatch[0];
const data = JSON.parse(raw.slice(prefix.length).replace(/;\s*$/, ''));

function unwrapLon(lon1, lon2) {
    let d = lon2 - lon1;
    while (d > 180) { lon2 -= 360; d = lon2 - lon1; }
    while (d < -180) { lon2 += 360; d = lon2 - lon1; }
    return lon2;
}
function round2(x) { return Math.round(x * 100) / 100; }

/**
 * Splittet einen geschlossenen Ring mit einer geraden Anzahl an
 * Antimeridian-Uebergaengen in mehrere geschlossene Ringe (je einer pro
 * Kartenseite). Wirft bei mehr als einem offenen Bogen je Seite (Faelle mit
 * mehr als 2 Uebergaengen pro Ring kommen in den aktuellen Datensaetzen nicht
 * vor -- dann muesste hier zusaetzlich nach Breitengrad sortiert und entlang
 * des Antimeridians zusammengenaeht werden).
 */
function splitRingAtAntimeridian(ring) {
    const n = ring.length;
    const crossings = [];
    for (let i = 1; i < n; i++) {
        const lon1 = ring[i - 1][0], lon2raw = ring[i][0];
        if (Math.abs(lon2raw - lon1) > 300) {
            const lon2u = unwrapLon(lon1, lon2raw);
            const t = (Math.sign(lon1) >= 0 ? 180 - lon1 : -180 - lon1) / (lon2u - lon1);
            const lat = ring[i - 1][1] + t * (ring[i][1] - ring[i - 1][1]);
            crossings.push({ atIndex: i, lat: round2(lat) });
        }
    }
    if (crossings.length === 0) return [ring];
    if (crossings.length % 2 !== 0) {
        throw new Error('Ungerade Anzahl Antimeridian-Uebergaenge, kann nicht gesplittet werden: ' + JSON.stringify(crossings));
    }

    const arcs = [];
    let curArc = { side: ring[0][0] > 0 ? 1 : -1, points: [ring[0]] };
    let ci = 0;
    for (let i = 1; i < n; i++) {
        if (ci < crossings.length && crossings[ci].atIndex === i) {
            const cr = crossings[ci];
            const leaveLon = curArc.side > 0 ? 180 : -180;
            curArc.points.push([leaveLon, cr.lat]);
            arcs.push(curArc);
            const newSide = -curArc.side;
            curArc = { side: newSide, points: [[newSide > 0 ? 180 : -180, cr.lat]] };
            ci++;
        }
        curArc.points.push(ring[i]);
    }
    arcs.push(curArc);

    // Erster und letzter Bogen liegen auf derselben Seite und teilen sich den
    // Schliesspunkt des Rings (Start == Ende) -> zu einem Bogen zusammenfuehren.
    if (arcs.length > 1 && arcs[0].side === arcs[arcs.length - 1].side) {
        const first = arcs.shift();
        const last = arcs.pop();
        arcs.push({ side: first.side, points: last.points.slice(0, -1).concat(first.points) });
    }

    const bySide = {};
    arcs.forEach((a) => { (bySide[a.side] = bySide[a.side] || []).push(a); });

    return Object.values(bySide).map((sideArcs) => {
        if (sideArcs.length !== 1) {
            throw new Error(sideArcs.length + ' Boegen auf einer Seite -- manuelle Behandlung noetig (>2 Uebergaenge/Ring)');
        }
        const pts = sideArcs[0].points.slice();
        const [x0, y0] = pts[0], [xn, yn] = pts[pts.length - 1];
        if (x0 !== xn || y0 !== yn) pts.push([x0, y0]);
        return pts;
    });
}

function fixFeature(name, polyIndices) {
    const feature = data.features.find((f) => f.properties.name === name);
    if (!feature) throw new Error('Feature nicht gefunden: ' + name);
    const before = feature.geometry.coordinates.length;
    polyIndices.forEach((pi) => {
        const split = splitRingAtAntimeridian(feature.geometry.coordinates[pi][0]);
        feature.geometry.coordinates[pi] = null;
        split.forEach((ring) => feature.geometry.coordinates.push([ring]));
    });
    feature.geometry.coordinates = feature.geometry.coordinates.filter((p) => p !== null);
    console.log(`${name}: ${before} -> ${feature.geometry.coordinates.length} Polygone`);
}

// Aktuell betroffene Polygon-Indizes (world-atlas@2.0.2 / countries-50m).
// Bei einer Neu-Erzeugung aus einer anderen world-atlas-Version zuerst mit den
// Diagnose-Zeilen unten (auskommentiert) pruefen, ob sich die Indizes geaendert
// haben.
fixFeature('Russia', [17, 28]);
fixFeature('Fiji', [15]);

const beforeCount = data.features.length;
data.features = data.features.filter((f) => f.properties.name !== 'Antarctica');
console.log(`Antarctica entfernt: ${beforeCount} -> ${data.features.length} Features`);

// Verifikation: keine Antimeridian-Spruenge mehr vorhanden.
let issues = 0;
data.features.forEach((f) => {
    const geom = f.geometry;
    const polys = geom.type === 'Polygon' ? [geom.coordinates] : geom.type === 'MultiPolygon' ? geom.coordinates : [];
    polys.forEach((poly) => poly.forEach((ring) => {
        for (let i = 1; i < ring.length; i++) {
            if (Math.abs(ring[i][0] - ring[i - 1][0]) > 300) {
                console.error('WEITERHIN DEFEKT:', f.properties.name, ring[i - 1], ring[i]);
                issues++;
            }
        }
    }));
});
if (issues > 0) {
    throw new Error(issues + ' verbleibende Antimeridian-Probleme -- world.js NICHT geschrieben.');
}

writeFileSync(worldPath, prefix + JSON.stringify(data) + ';\n');
console.log('world.js geschrieben:', worldPath);
