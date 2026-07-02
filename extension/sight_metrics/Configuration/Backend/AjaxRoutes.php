<?php

use SightMetrics\Controller\TopNAjaxController;

/**
 * Nachlade-Endpunkt fuer die serverseitig auf Top-N begrenzten Barlisten
 * (siehe Classes/Support/TopNDims.php, ROADMAP.md "Top-N + Nachladen").
 *
 * TYPO3 praefixiert Ajax-Routen automatisch mit "ajax_" (Routenname) und "/ajax"
 * (Pfad) -- siehe AbstractServiceProvider::checkAndFilterExtensionRoutes(). Der
 * Routenname aus Sicht von UriBuilder::buildUriFromRoute() ist also
 * "ajax_sightmetrics_topn", erreichbar unter /typo3/ajax/sightmetrics/topn.
 */
return [
    'sightmetrics_topn' => [
        'path' => '/sightmetrics/topn',
        'target' => TopNAjaxController::class . '::handleRequest',
    ],
];
