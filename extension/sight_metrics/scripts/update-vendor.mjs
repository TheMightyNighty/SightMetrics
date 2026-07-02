#!/usr/bin/env node
// Kopiert Chart.js/Leaflet-Dist-Dateien aus node_modules (versionsgepinnt via
// package.json/package-lock.json) nach Resources/Public/Vendor/ und gibt die
// SHA-256-Pruefsummen aus, damit sie manuell in NOTICE.md eingetragen werden
// koennen. Ersetzt den frueheren Ad-hoc-Bezug per curl von jsDelivr.
//
// Aufruf: npm run vendor:update

import { copyFileSync, readFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const vendorDir = join(root, 'Resources/Public/Vendor');
const imagesDir = join(vendorDir, 'images');
mkdirSync(imagesDir, { recursive: true });

const files = [
    ['node_modules/chart.js/dist/chart.umd.min.js', 'chart.umd.min.js'],
    ['node_modules/leaflet/dist/leaflet.js', 'leaflet.js'],
    ['node_modules/leaflet/dist/leaflet.css', 'leaflet.css'],
    ['node_modules/leaflet/dist/images/layers.png', 'images/layers.png'],
    ['node_modules/leaflet/dist/images/layers-2x.png', 'images/layers-2x.png'],
    ['node_modules/leaflet/dist/images/marker-icon.png', 'images/marker-icon.png'],
    ['node_modules/leaflet/dist/images/marker-icon-2x.png', 'images/marker-icon-2x.png'],
    ['node_modules/leaflet/dist/images/marker-shadow.png', 'images/marker-shadow.png'],
];

for (const [src, destRel] of files) {
    const srcPath = join(root, src);
    const destPath = join(vendorDir, destRel);
    copyFileSync(srcPath, destPath);
    const sha256 = createHash('sha256').update(readFileSync(destPath)).digest('hex');
    console.log(`${destRel}\t${sha256}`);
}
