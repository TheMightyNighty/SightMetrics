.. _configuration:

=============
Configuration
=============

Extension configuration options
=================================

Configured in the TYPO3 backend under **Admin Tools → Extensions → sight_metrics**.

.. list-table::
   :header-rows: 1
   :widths: 20 15 65

   * - Setting
     - Default
     - Description
   * - `errorTitle`
     - empty ("Analytics currently unavailable")
     - Heading of the error page shown when the cube database is unreachable.
       Empty = built-in default; set your own (e.g. localized) text here.
   * - `errorMessage`
     - empty ("The connection to the analytics database is currently
       interrupted.")
     - Explanatory text on the error page. Empty = built-in default.
   * - `showTechnical`
     - `0`
     - Show the technical error message (only intended for admins/debugging).
   * - `windowDays`
     - `92`
     - Server-side time window in days: only this window is loaded from the
       cube database, limiting the transfer volume independently of the
       retention period configured on the ingestion side. `0` = unlimited.
   * - `cacheLifetime`
     - `60`
     - Cache TTL in seconds for cube database reads (TYPO3 caching framework,
       cache `sight_metrics`). `0` = no caching, every request reads live data.
       See :ref:`known-problems` regarding cache cleanup responsibilities.

The cube connection is fully independent from the main TYPO3 connection, so a
cube database outage never affects the rest of the TYPO3 backend.

Mapping TYPO3 sites to a cube `site_id`
=========================================

In a TYPO3 instance with multiple sites (e.g. several public-administration
domains), each TYPO3 site can be mapped to its own `site_id` in the cube.

Configuration in `config/sites/<identifier>/config.yaml`:

.. code-block:: yaml

   # Example: config/sites/authority_a/config.yaml
   rootPageId: 1
   base: 'https://authority-a.example/'
   languages: ...

   # SightMetrics: associated site_id in the cube
   sightmetrics_site_id: 1

.. code-block:: yaml

   # Example: config/sites/authority_b/config.yaml
   rootPageId: 2
   base: 'https://authority-b.example/'

   sightmetrics_site_id: 2

Access semantics
-----------------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - State
     - Module behavior
   * - **No** `sightmetrics_site_id` on any TYPO3 site
     - All cube sites appear in the dropdown (backward compatibility — no
       tenant separation is enforced).
   * - **One** TYPO3 site with a mapping
     - Only that site_id is visible and auto-selected (provided the user has
       webmount access to it).
   * - **Multiple** TYPO3 sites with mappings
     - The dropdown shows only the sites whose root page (`rootPageId`) the
       current user has webmount access to. Admin users see all mapped sites.
   * - A mapping exists, but the user has webmount access to **none** of the
       mapped sites
     - **Empty dashboard** — there is deliberately no fallback to "all
       sites" (tenant separation).

.. important::

   Tenant separation only takes effect once sites are mapped. Without any
   mapping (first row above), **every** user with module access sees **all**
   cube sites. In a multi-tenant installation, always assign
   `sightmetrics_site_id` to every site.

Error page behavior
=====================

If the cube database is unreachable, the module shows the configurable error
page described above instead of a PHP exception. This is handled entirely
independently of the main TYPO3 database connection.

Multi-site notes
=================

The intended deployment model is **one** TYPO3 instance with multiple sites in
a single namespace, with the cube living in the same MariaDB instance. All
sites share one cube database (`analytics`), distinguished by `site_id`; the
mapping from TYPO3 site to cube `site_id` is done via `sightmetrics_site_id` as
described above, and the module's site selector reflects that mapping.

Per-tenant database isolation (a separate database per tenant) is not built in
and is not needed for this single-instance deployment model. If true
multi-tenant isolation is required later, the recommended approach is a
dedicated database plus a dedicated `cube` connection per TYPO3 instance — the
extension itself would not need to change.
