<?php

declare(strict_types=1);

namespace SightMetrics\Support;

use TYPO3\CMS\Core\Site\SiteFinder;

final class SiteSelector
{
    /**
     * Ermittelt die aktive Site-ID: bevorzugt die angeforderte, fällt auf die erste zurück.
     *
     * @param list<array{site_id: int|string, ...}> $sites
     */
    public static function resolve(array $sites, int $requested): int
    {
        $ids = array_map(static fn(array $s): int => (int)$s['site_id'], $sites);
        return in_array($requested, $ids, true) ? $requested : (int)($ids[0] ?? 0);
    }

    /**
     * Liest sightmetrics_site_id aus allen TYPO3-Site-Konfigurationen.
     * Rückgabe leere Liste = kein Filter (alle Cube-Sites sichtbar).
     *
     * Konfiguration in config/sites/<identifier>/config.yaml:
     *   sightmetrics_site_id: 1
     * Oder mehrere Sites auf dieselbe cube_site_id:
     *   sightmetrics_site_id: 1
     *
     * @return list<int>
     */
    public static function allowedSiteIds(SiteFinder $siteFinder): array
    {
        $ids = [];
        foreach ($siteFinder->getAllSites() as $site) {
            $raw = $site->getConfiguration()['sightmetrics_site_id'] ?? null;
            if ($raw !== null) {
                $ids[] = (int)$raw;
            }
        }
        return array_values(array_unique($ids));
    }
}
