<?php

declare(strict_types=1);

namespace SightMetrics\Support;

use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
use TYPO3\CMS\Core\Http\JsonResponse;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Shared site access check for the Ajax endpoints (TopN/Tree). A single
 * implementation, so that the three-valued semantics of SiteSelector::allowedSiteIds()
 * (null = no mapping/unfiltered, [] = nothing allowed, [ids] = only these) cannot
 * be interpreted differently across multiple controllers -- exactly this
 * misinterpretation was the tenant-separation bypass from the 2026-07-02 review.
 */
final class AjaxSiteGuard
{
    private function __construct() {}

    /**
     * Returns a rejecting JsonResponse (403), or null if access to
     * $siteId is allowed. No backend user in context -> also 403.
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
