# Package B – TYPO3 reporting extension `sight_metrics`

The **TYPO3 backend module "Web Analytics"** (TYPO3 v13.4 LTS / v14). It
reads the precomputed analytics data (the "cube") from MariaDB and renders it
as an interactive dashboard — charts, drill-down bar lists, world map, and
page tree. Fully localized (English/German).

This extension is the **read side** of SightMetrics. It contains **no**
DuckDB and writes **nothing** to the database: it accesses the cube
**read-only** (DB user `report_ro`, `SELECT` only), populated by
[package A (`ingestion/`)](../ingestion/README.md). → Overall overview:
[repo README](../README.md).

![SightMetrics backend module "Web Analytics"](typo3-Logauswertung.png)

---

## What the module shows

- **KPI bar:** visits, unique visitors, pageviews, bounce rate, bandwidth
- **Trend** over time (pageviews / visits / unique visitors)
- **Visitor map** (choropleth world map) and **country** list
- **Visit times** by hour
- **Browser / OS / device type** with **drill-down** into versions/models
- **Acquisition:** referrer types, referrer URLs, search terms
- **Behavior:** page-tree drill-down, entry/exit pages
- **Downloads, status codes, HTTP methods**
- **Time range selector** (Matomo-style dropdown: relative / calendar /
  individual years / custom), **period comparison**, **CSV/PDF export**,
  **dark mode**
- **Site selector** for multi-site setups

> Note in the screenshot footer: unique visitors over a multi-day range are
> approximated as the sum of the daily values (not additive-exact); daily
> values are exact. All data comes read-only from the cube.

---

## Structure

```
extension/
├── README.md                  this file
├── lint.sh                    linting: PHPStan level max + strict-rules + TYPO3 coding standards
├── run-tests.sh               test runner (unit / functional / smoke)
└── sight_metrics/             composer package  sightmetrics/sight-metrics
    (bind-mounted live as packages/sight_metrics in the demo stack,
     see demo/docker-compose.yml – no deploy/sync step needed)
    ├── Classes/
    │   ├── Controller/        DashboardController  (builds the module payload)
    │   ├── Domain/Repository/ CubeRepository       (read-only SELECTs against cube/daily/meta)
    │   ├── Support/           SiteSelector, WindowResolver (time window), ErrorPage
    │   └── Command/           health/smoke commands
    ├── Configuration/         backend module registration, services, icons
    ├── Resources/             Fluid template, CSS, JavaScript (native ES modules),
    │                          vendor: Chart.js + Leaflet + world map data, XLF (en/de)
    ├── ext_conf_template.txt  extension configuration (error-page text, showTechnical, windowDays, cacheLifetime)
    └── Tests/                 unit + functional (SQLite) + contract (real MariaDB) + JavaScript (jsdom)
```

---

## Installation & configuration (short version)

1. **Include the package** — as the composer package
   `sightmetrics/sight-metrics` (included as a path repository in the demo).
2. **Configure the `cube` connection** (Doctrine connection in
   `additional.php`), pointing at the cube DB with the **read-only** user
   `report_ro`.
3. **Map the TYPO3 site to a cube site** via `sightmetrics_site_id` in the
   site configuration (see multi-site in the repo README).
4. Open the module in the backend under **Web → "Web Analytics"**.

> **Version 2.x** requires cube **schema v2**. If you're coming from an
> older ingestion, migrate the cube DB once with
> `ingestion/migrations/v1_to_v2.sql` (idempotent) or re-import — details in
> [`docs/SCHEMA.md`](../docs/SCHEMA.md). The module reports an incompatible
> version with a clear message.

The full guide — installation, connection, site mapping, error page, version
matrix, architecture, troubleshooting — is in the
**[extension handbook](../docs/extension-handbuch.md)**.

---

## Development

```bash
./lint.sh                 # PHPStan (level max + strict-rules) + TYPO3 coding standards
./run-tests.sh            # unit, functional (SQLite), smoke, contract, and JS tests
```

The extension supports **TYPO3 v13.4 LTS and v14**, PHP 8.2–8.4. The backend
module uses [Chart.js](https://www.chartjs.org/) (MIT license) for the
trend/bar charts and [Leaflet](https://leafletjs.com/) (BSD-2-Clause) for the
visitor map (choropleth via `L.geoJSON`).
