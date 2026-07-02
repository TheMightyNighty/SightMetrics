<?php

declare(strict_types=1);

namespace SightMetrics\Domain\Repository;

use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\ParameterType;
use TYPO3\CMS\Core\Cache\CacheManager;
use TYPO3\CMS\Core\Cache\Frontend\FrontendInterface;
use TYPO3\CMS\Core\Configuration\ExtensionConfiguration;
use TYPO3\CMS\Core\Database\ConnectionPool;
use TYPO3\CMS\Core\Database\Query\QueryBuilder;

/**
 * Liest die Cube-Tabellen ueber eine SEPARATE, read-only DB-Verbindung ('cube').
 * Kein Extbase, keine TCA – nur DBAL-SELECTs gegen aussenstehende Tabellen
 * (Abschnitt 11.1/11.4). Multi-Site: alle Lesezugriffe sind nach site_id gefiltert.
 *
 * daily()/cube() sind die Reads, deren Volumen mit Zeitfenster/Kardinalitaet waechst;
 * sie werden kurzlebig ueber den TYPO3-Cache "sight_metrics" gecacht (TTL per
 * Extension-Konfiguration, 0 = deaktiviert). meta()/sites() sind Einzelzeilen/kleine
 * Listen und bleiben bewusst live, damit z. B. eine neue Site sofort sichtbar ist.
 */
final class CubeRepository
{
    private const CONNECTION = 'cube';

    public function __construct(
        private readonly ConnectionPool $connectionPool,
        private readonly CacheManager $cacheManager,
        private readonly ExtensionConfiguration $extensionConfiguration,
    ) {}

    private function cache(): FrontendInterface
    {
        return $this->cacheManager->getCache('sight_metrics');
    }

    private function cacheLifetime(): int
    {
        try {
            $conf = $this->extensionConfiguration->get('sight_metrics');
            if (isset($conf['cacheLifetime']) && $conf['cacheLifetime'] !== '') {
                return max(0, (int)$conf['cacheLifetime']);
            }
        } catch (\Throwable) {
        }
        return 60;
    }

    /**
     * @param callable(): mixed $fetch
     */
    private function cached(string $identifier, callable $fetch): mixed
    {
        $lifetime = $this->cacheLifetime();
        if ($lifetime <= 0) {
            return $fetch();
        }
        // Cache-Konfiguration fehlt (z. B. Unit-/Functional-Tests ohne geladenes
        // ext_localconf.php) -> Caching ist ein reines Perf-Feature, kein
        // Korrektheitserfordernis, daher hier fehlertolerant auf Live-Query zurueckfallen.
        try {
            $cache = $this->cache();
        } catch (\Throwable) {
            return $fetch();
        }
        $entryIdentifier = md5($identifier);
        $value = $cache->get($entryIdentifier);
        if ($value !== false) {
            return $value;
        }
        $value = $fetch();
        $cache->set($entryIdentifier, $value, [], $lifetime);
        return $value;
    }

    private function qb(string $table): QueryBuilder
    {
        $qb = $this->connectionPool->getConnectionByName(self::CONNECTION)->createQueryBuilder();
        $qb->getRestrictions()->removeAll(); // Cube-Tabellen ohne TCA
        return $qb;
    }

    /**
     * Verfuegbare Sites (fuer die Auswahl).
     * $allowedIds: wenn gesetzt, nur diese site_ids zurueckgeben (TYPO3-Site-Mapping).
     * Leere Liste = kein Filter (alle Sites sichtbar, Rueckwaertskompatibilitaet).
     *
     * @param list<int>              $allowedIds
     * @return list<array<string,mixed>>
     */
    public function sites(array $allowedIds = []): array
    {
        $qb = $this->qb('meta')->select('site_id', 'site')->from('meta')->orderBy('site');
        if ($allowedIds !== []) {
            $qb->where($qb->expr()->in(
                'site_id',
                $qb->createNamedParameter(array_map('intval', $allowedIds), ArrayParameterType::INTEGER)
            ));
        }
        return $qb->executeQuery()->fetchAllAssociative();
    }

    /**
     * @return array<string,mixed>
     */
    public function meta(int $siteId): array
    {
        $qb = $this->qb('meta');
        $row = $qb->select('*')->from('meta')
            ->where($qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)))
            ->setMaxResults(1)->executeQuery()->fetchAssociative();
        return $row ?: [];
    }

    /**
     * Tages-Aggregate, auf das Zeitfenster [$from, $bis] begrenzt (serverseitig).
     * Begrenzt das Transfervolumen unabhaengig von der Retention der Cube-DB.
     *
     * @return list<array<string,mixed>>
     */
    public function daily(int $siteId, string $from, string $bis): array
    {
        return $this->cached("daily:$siteId:$from:$bis", function () use ($siteId, $from, $bis) {
            $qb = $this->qb('daily');
            return $qb->select('datum', 'visits', 'pageviews', 'uniques', 'bounces', 'bytes')
                ->from('daily')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                )
                ->orderBy('datum')
                ->executeQuery()->fetchAllAssociative();
        });
    }

    /**
     * Cube-Zeilen, auf das Zeitfenster [$from, $bis] begrenzt (serverseitig).
     *
     * @return list<array<string,mixed>>
     */
    public function cube(int $siteId, string $from, string $bis): array
    {
        return $this->cached("cube:$siteId:$from:$bis", function () use ($siteId, $from, $bis) {
            $qb = $this->qb('cube');
            return $qb->select('datum', 'dim', 'dimkey', 'pv', 'v')
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                )
                ->executeQuery()->fetchAllAssociative();
        });
    }
}
