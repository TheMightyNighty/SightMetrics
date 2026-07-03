<?php

use SightMetrics\Controller\TopNAjaxController;
use SightMetrics\Controller\TreeAjaxController;

/**
 * Nachlade-Endpunkte fuer die serverseitig begrenzten Auswertungen: Top-N-Barlisten
 * (topn) und Seitenbaum (tree) — siehe Classes/Support/TopNDims.php bzw.
 * CubeRepository::urlTree().
 *
 * TYPO3 praefixiert Ajax-Routen automatisch mit "ajax_" (Routenname) und "/ajax"
 * (Pfad) -- siehe AbstractServiceProvider::checkAndFilterExtensionRoutes(). Die
 * Routennamen aus Sicht von UriBuilder::buildUriFromRoute() sind also
 * "ajax_sightmetrics_topn"/"ajax_sightmetrics_tree", erreichbar unter
 * /typo3/ajax/sightmetrics/topn bzw. .../tree.
 *
 * inheritAccessFromModule: die Routen erben die Zugriffspruefung des Backend-Moduls
 * (BackendModuleValidator antwortet 403, wenn dem Benutzer web_sightmetrics fehlt) --
 * ohne diese Option koennte jeder eingeloggte Backend-Benutzer die Endpunkte aufrufen,
 * in Installationen ohne Site-Mapping (filterloser Kompatibilitaetsmodus) ganz ohne
 * weitere Pruefung. Siehe TYPO3-Changelog #106983.
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
