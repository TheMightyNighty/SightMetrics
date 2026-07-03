<?php

declare(strict_types=1);

namespace SightMetrics\Support;

use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
use TYPO3\CMS\Core\Http\JsonResponse;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Gemeinsame Site-Zugriffspruefung der Ajax-Endpunkte (TopN/Tree). Eine einzige
 * Implementierung, damit die dreiwertige Semantik von SiteSelector::allowedSiteIds()
 * (null = kein Mapping/filterlos, [] = nichts erlaubt, [ids] = nur diese) nicht in
 * mehreren Controllern unterschiedlich interpretiert werden kann — genau diese
 * Fehlinterpretation war der Mandantentrennungs-Bypass aus der Pruefung 2026-07-02.
 */
final class AjaxSiteGuard
{
    private function __construct() {}

    /**
     * Liefert eine ablehnende JsonResponse (403) oder null, wenn der Zugriff auf
     * $siteId erlaubt ist. Kein Backend-Benutzer im Kontext -> ebenfalls 403.
     */
    public static function denyResponse(SiteFinder $siteFinder, int $siteId): ?JsonResponse
    {
        $beUser = $GLOBALS['BE_USER'] ?? null;
        if (!$beUser instanceof BackendUserAuthentication) {
            return new JsonResponse(['error' => 'kein Backend-Benutzer'], 403);
        }
        $allowedIds = SiteSelector::allowedSiteIds($siteFinder, $beUser);
        if ($allowedIds !== null && !in_array($siteId, $allowedIds, true)) {
            return new JsonResponse(['error' => 'kein Zugriff auf diese Site'], 403);
        }
        return null;
    }
}
