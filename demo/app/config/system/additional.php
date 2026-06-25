<?php
// Separate, read-only Verbindung zur Cube-DB (Abschnitt 11.1): die Extension
// liest ausschliesslich; geschrieben wird nur von der DuckDB-Ingestion.
$GLOBALS["TYPO3_CONF_VARS"]["DB"]["Connections"]["cube"] = [
    "driver"   => "mysqli",
    "host"     => getenv("CUBE_RO_HOST") ?: "db",
    "port"     => (int)(getenv("CUBE_RO_PORT") ?: 3306),
    "dbname"   => getenv("CUBE_RO_DB") ?: "analytics",
    "user"     => getenv("CUBE_RO_USER") ?: "report_ro",
    "password" => getenv("CUBE_RO_PASSWORD") ?: "report_ro",
    "charset"  => "utf8mb4",
];

// Demo: beliebigen Host/Port erlauben (lokaler Testbetrieb)
$GLOBALS["TYPO3_CONF_VARS"]["SYS"]["trustedHostsPattern"] = ".*";
