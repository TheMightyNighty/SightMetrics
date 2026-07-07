/* Globale Vendor-Bibliotheken (klassische Skripte, kein Import):
   Chart.js, Leaflet und die Weltkarten-Daten. Nur so weit typisiert, wie
   dashboard.js sie nutzt -- fuer tsc --checkJs (npm run typecheck). */
declare const Chart: any;
declare const L: any;
interface Window {
    SM_DATA?: unknown;
    SM_WORLD?: unknown;
    Chart?: unknown;
    L?: unknown;
}
declare var SM_WORLD: unknown;
