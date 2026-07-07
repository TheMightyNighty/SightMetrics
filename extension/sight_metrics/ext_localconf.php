<?php

defined('TYPO3') or die();

// Short-lived cache for the cube DB reads (daily()/cube()), see
// CubeRepository::cachedFetch(). TTL comes from the extension configuration
// (cacheLifetime, 0 = disabled), backend/frontend here only structural.
$GLOBALS['TYPO3_CONF_VARS']['SYS']['caching']['cacheConfigurations']['sight_metrics'] ??= [
    'frontend' => \TYPO3\CMS\Core\Cache\Frontend\VariableFrontend::class,
    'backend' => \TYPO3\CMS\Core\Cache\Backend\Typo3DatabaseBackend::class,
    'options' => [],
];
