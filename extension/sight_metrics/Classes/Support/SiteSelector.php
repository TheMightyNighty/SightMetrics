<?php

declare(strict_types=1);

namespace SightMetrics\Support;

use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
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
     * Liest sightmetrics_site_id aus allen TYPO3-Site-Konfigurationen, eingeschraenkt auf
     * die Sites, deren Seitenbaum (rootPageId) der Backend-Benutzer sehen darf (allgemeines
     * TYPO3-Seitenbaum-/Webmount-Modell, keine eigene Berechtigungsstruktur). Admins sehen
     * immer alles.
     *
     * Rueckgabe-Semantik (bewusst dreiwertig, NICHT zusammenfallen lassen):
     *   - null = KEINE Site hat ein sightmetrics_site_id-Mapping -> kein Filter, alle
     *     Cube-Sites sichtbar (Rueckwaertskompatibilitaet fuer Installationen ohne Mapping).
     *   - []   = Mappings existieren, aber der Benutzer hat auf keine gemappte Site
     *     Webmount-Zugriff -> NICHTS sichtbar. Darf von Aufrufern nicht als "kein Filter"
     *     interpretiert werden (sonst Mandantentrennungs-Bypass: ein Benutzer ohne
     *     passenden Webmount saehe alle Mandanten).
     *   - [ids] = nur diese Cube-Site-IDs sichtbar.
     *
     * Konfiguration in config/sites/<identifier>/config.yaml:
     *   sightmetrics_site_id: 1
     * Oder mehrere Sites auf dieselbe cube_site_id:
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
                continue; // kein Seitenbaum-/Webmount-Zugriff auf diese Site
            }
            $ids[] = (int)$raw;
        }
        return $mappingExists ? array_values(array_unique($ids)) : null;
    }
}
