<?php

declare(strict_types=1);

namespace SightMetrics\Support;

use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
use TYPO3\CMS\Core\Site\SiteFinder;

final class SiteSelector
{
    /**
     * Determines the active site ID: prefers the requested one, falls back to the first.
     *
     * @param list<array<string,mixed>> $sites
     */
    public static function resolve(array $sites, int $requested): int
    {
        $ids = array_map(static fn(array $s): int => Params::toInt($s['site_id'] ?? null), $sites);
        return in_array($requested, $ids, true) ? $requested : ($ids[0] ?? 0);
    }

    /**
     * Reads sightmetrics_site_id from all TYPO3 site configurations, restricted to
     * the sites whose page tree (rootPageId) the backend user is allowed to see (the
     * general TYPO3 page tree/webmount model, no custom permission structure). Admins
     * always see everything.
     *
     * Return semantics (deliberately three-valued, do NOT conflate):
     *   - null = NO site has a sightmetrics_site_id mapping -> no filter, all
     *     cube sites visible (backward compatibility for installations without mapping).
     *   - []   = mappings exist, but the user has no webmount access to any mapped
     *     site -> NOTHING visible. Must not be interpreted by callers as "no filter"
     *     (otherwise a tenant-separation bypass: a user without a matching webmount
     *     would see all tenants).
     *   - [ids] = only these cube site IDs are visible.
     *
     * Configuration in config/sites/<identifier>/config.yaml:
     *   sightmetrics_site_id: 1
     * Or multiple sites mapped to the same cube_site_id:
     *   sightmetrics_site_id: 1
     *
     * @return list<int>|null
     */
    public static function allowedSiteIds(SiteFinder $siteFinder, BackendUserAuthentication $beUser): ?array
    {
        $mappingExists = false;
        $ids = [];
        foreach ($siteFinder->getAllSites() as $site) {
            $raw = $site->getConfiguration()['sightmetrics_site_id'] ?? null;
            if ($raw === null) {
                continue;
            }
            $mappingExists = true;
            if (!$beUser->isAdmin() && $beUser->isInWebMount($site->getRootPageId()) === null) {
                continue; // no page tree/webmount access to this site
            }
            $ids[] = Params::toInt($raw);
        }
        return $mappingExists ? array_values(array_unique($ids)) : null;
    }
}
