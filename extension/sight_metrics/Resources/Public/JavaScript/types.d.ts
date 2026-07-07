/* Global vendor libraries (classic scripts, no import):
   Chart.js, Leaflet, and the world map data. Only typed as far as
   dashboard.js uses them -- for tsc --checkJs (npm run typecheck). */
declare const Chart: any;
declare const L: any;
interface Window {
    SM_DATA?: unknown;
    SM_WORLD?: unknown;
    Chart?: unknown;
    L?: unknown;
}
declare var SM_WORLD: unknown;
