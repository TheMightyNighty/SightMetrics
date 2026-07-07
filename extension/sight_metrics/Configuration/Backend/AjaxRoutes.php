<?php

use SightMetrics\Controller\TopNAjaxController;
use SightMetrics\Controller\TreeAjaxController;

/**
 * Lazy-loading endpoints for the server-side limited evaluations: Top-N bar lists
 * (topn) and page tree (tree) -- see Classes/Support/TopNDims.php and
 * CubeRepository::urlTree() respectively.
 *
 * TYPO3 automatically prefixes Ajax routes with "ajax_" (route name) and "/ajax"
 * (path) -- see AbstractServiceProvider::checkAndFilterExtensionRoutes(). The
 * route names from UriBuilder::buildUriFromRoute()'s perspective are thus
 * "ajax_sightmetrics_topn"/"ajax_sightmetrics_tree", reachable at
 * /typo3/ajax/sightmetrics/topn and .../tree respectively.
 *
 * inheritAccessFromModule: the routes inherit the access check of the backend module
 * (BackendModuleValidator responds 403 if the user lacks web_sightmetrics) --
 * without this option any logged-in backend user could call the endpoints,
 * in installations without site mapping (unfiltered compatibility mode) with
 * no further check at all. See TYPO3 changelog #106983.
 */
return [
    'sightmetrics_topn' => [
        'path' => '/sightmetrics/topn',
        'target' => TopNAjaxController::class . '::handleRequest',
        'inheritAccessFromModule' => 'web_sightmetrics',
    ],
    'sightmetrics_tree' => [
        'path' => '/sightmetrics/tree',
        'target' => TreeAjaxController::class . '::handleRequest',
        'inheritAccessFromModule' => 'web_sightmetrics',
    ],
];
