<?php

use SightMetrics\Controller\DashboardController;

/**
 * Backend-Modul unterhalb von "Web". Nicht-Extbase (einfacher Controller),
 * da die Extension nur liest und keine TCA/Domain-Modelle braucht.
 */
return [
    'web_sightmetrics' => [
        'parent' => 'web',
        'position' => ['after' => 'web_info'],
        'access' => 'user',
        'iconIdentifier' => 'sight-metrics-module',
        'path' => '/module/web/sight-metrics',
        // Labels aus der Sprachdatei (mlang_tabs_tab = Titel, mlang_labels_tabdescr = Beschreibung).
        'labels' => 'LLL:EXT:sight_metrics/Resources/Private/Language/locallang_mod.xlf',
        'routes' => [
            '_default' => [
                'target' => DashboardController::class . '::handleRequest',
            ],
        ],
    ],
];
