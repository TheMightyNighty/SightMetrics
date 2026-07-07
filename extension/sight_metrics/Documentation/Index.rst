.. _start:

===========================================================
SightMetrics – privacy-friendly web access analytics
===========================================================

SightMetrics analyzes **web server logs** (Apache/nginx) and presents the results as
a dashboard in a **TYPO3 backend module** – without a JavaScript tracker, without
cookies, and without visitor data ever leaving your own system.

Instead of capturing every single page view through a tracking API (as, for example,
Matomo does), SightMetrics reads the log files that already exist, reduces them
**once with DuckDB** to compact daily aggregates ("cubes"), and stores only these
aggregates in a database. This is fast, resource-friendly, and **privacy-friendly** –
a design that is particularly aimed at public administrations and the public sector
(GDPR/BSI).

This extension (`sight_metrics`) is package B of the SightMetrics project: the
read-only reporting UI. Package A, the ingestion pipeline, is a separate,
non-TYPO3 component that parses logs with DuckDB and writes the aggregated data
into the cube database.

.. important::

   This extension is the **read-only reporting UI only**. It requires the
   **SightMetrics ingestion pipeline** (DuckDB-based, deployed separately as a
   container/cron job outside TYPO3) to fill the cube database. Without the
   ingestion pipeline running, the backend module shows an empty dashboard.

   The ingestion pipeline, its documentation, and operational runbooks are
   maintained in the same repository:
   https://github.com/TheMIghtyNighty/SightMetrics

.. toctree::
   :maxdepth: 2
   :titlesonly:

   Introduction/Index
   Installation/Index
   Configuration/Index
   Usage/Index
   KnownProblems/Index
