<?php

use SightMetrics\Controller\DashboardController;

/**
 * Backend module below "Web". Non-Extbase (plain controller),
 * since the extension only reads and needs no TCA/domain models.
 */
return [
    'web_sightmetrics' => [
        'parent' => 'web',
        'position' => ['after' => 'web_info'],
        'access' => 'user',
        'iconIdentifier' => 'sight-metrics-module',
        'path' => '/module/web/sight-metrics',
        // Labels from the language file (mlang_tabs_tab = title, mlang_labels_tabdescr = description).
        'labels' => 'LLL:EXT:sight_metrics/Resources/Private/Language/locallang_mod.xlf',
        'routes' => [
            '_default' => [
                'target' => DashboardController::class . '::handleRequest',
            ],
        ],
    ],
];
