<?php

defined('TYPO3') or die();

// Kurzlebiger Cache fuer die Cube-DB-Reads (daily()/cube()), siehe
// CubeRepository::cachedFetch(). TTL kommt aus der Extension-Konfiguration
// (cacheLifetime, 0 = deaktiviert), Backend/Frontend hier nur strukturell.
$GLOBALS['TYPO3_CONF_VARS']['SYS']['caching']['cacheConfigurations']['sight_metrics'] ??= [
    'frontend' => \TYPO3\CMS\Core\Cache\Frontend\VariableFrontend::class,
    'backend' => \TYPO3\CMS\Core\Cache\Backend\Typo3DatabaseBackend::class,
    'options' => [],
];
