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

    /**
     * Eltern|Kind-Trenner in dimkey-Werten (Drill-down-Dimensionen), exakt identisch zu
     * chr(31) in ingestion/transform.sql und der SEP-Konstante in dashboard.js.
     */
    private const CHILD_SEP = "\x1f";

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
     * $excludeDims: Dimensionen, die NICHT komplett mitgeliefert werden (siehe TopNDims) --
     * fuer die liefert stattdessen topN() nur die Top-N-Zeilen, um das Transfervolumen bei
     * hoher Kardinalitaet zu begrenzen.
     *
     * @param list<string> $excludeDims
     * @return list<array<string,mixed>>
     */
    public function cube(int $siteId, string $from, string $bis, array $excludeDims = []): array
    {
        $excludeKey = $excludeDims === [] ? '' : ':ex=' . implode(',', $excludeDims);
        return $this->cached("cube:$siteId:$from:$bis$excludeKey", function () use ($siteId, $from, $bis, $excludeDims) {
            $qb = $this->qb('cube');
            $qb->select('datum', 'dim', 'dimkey', 'pv', 'v')
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                );
            if ($excludeDims !== []) {
                $qb->andWhere($qb->expr()->notIn(
                    'dim',
                    $qb->createNamedParameter($excludeDims, ArrayParameterType::STRING)
                ));
            }
            return $qb->executeQuery()->fetchAllAssociative();
        });
    }

    /**
     * Beschraenkt eine Cube-Query auf Zeilen, deren dimkey mit "$parentKey . CHILD_SEP"
     * beginnt (Drill-down: Kind-Zeilen einer Eltern-Kategorie). $parentKey ist ein
     * gebundener Parameter (kein Injection-Risiko); nur die per PHP berechnete Praefix-
     * LAENGE wird als Literal in die Query eingebettet. SUBSTR() zaehlt sowohl bei MySQL/
     * MariaDB (nicht-binaere Spalten) als auch bei SQLite Unicode-Codepoints, daher
     * mb_strlen() statt strlen() -- sonst wuerden mehrbyte-UTF-8-Labels falsch abgeschnitten.
     */
    private function applyParentPrefix(QueryBuilder $qb, ?string $parentKey): void
    {
        if ($parentKey === null) {
            return;
        }
        $prefix = $parentKey . self::CHILD_SEP;
        // Kein $qb->expr()->eq() hier: das quotet sein erstes Argument als Identifier
        // (Connection::quoteIdentifier()), was den SUBSTR(...)-Ausdruck kaputt macht.
        // andWhere() akzeptiert rohe SQL-Fragmente direkt.
        $qb->andWhere(
            'SUBSTR(dimkey, 1, ' . mb_strlen($prefix, 'UTF-8') . ') = ' . $qb->createNamedParameter($prefix)
        );
    }

    /**
     * Top-N-Zeilen einer Dimension, absteigend nach $metric ('pv' oder 'v') sortiert.
     * Fuer serverseitiges Top-N + Nachladen bei hochkardinalen Dimensionen (siehe
     * TopNDims/ROADMAP.md). $parentKey: wenn gesetzt, nur Kind-Zeilen dieser Eltern-Kategorie
     * (Drill-down, dimkey-Praefix vor CHILD_SEP) -- siehe applyParentPrefix().
     *
     * @return list<array{dimkey: string, pv: int, v: int}>
     */
    public function topN(int $siteId, string $from, string $bis, string $dim, string $metric, int $limit, int $offset = 0, ?string $parentKey = null): array
    {
        if (!in_array($metric, ['pv', 'v'], true)) {
            throw new \InvalidArgumentException('Ungueltige Metrik: ' . $metric);
        }
        $cacheKey = "topN:$siteId:$from:$bis:$dim:$metric:$limit:$offset:" . ($parentKey ?? '');
        return $this->cached($cacheKey, function () use ($siteId, $from, $bis, $dim, $metric, $limit, $offset, $parentKey) {
            $qb = $this->qb('cube');
            $qb->select('dimkey')
                ->addSelectLiteral('SUM(pv) AS pv', 'SUM(v) AS v')
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter($dim)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                    // Leere Keys nicht anzeigen (frueher client-seitig in agg() gefiltert);
                    // '<>' schliesst NULL-dimkeys gleich mit aus.
                    $qb->expr()->neq('dimkey', $qb->createNamedParameter('')),
                );
            $this->applyParentPrefix($qb, $parentKey);
            $rows = $qb->groupBy('dimkey')
                ->orderBy($metric, 'DESC')
                ->setMaxResults($limit)
                ->setFirstResult($offset)
                ->executeQuery()->fetchAllAssociative();
            // mysqli liefert Aggregat-Summen als String -- fuer einen sauberen JSON-Vertrag
            // (Client rechnet mit Zahlen) hier explizit casten.
            return array_map(static fn(array $r): array => [
                'dimkey' => (string)$r['dimkey'],
                'pv' => (int)$r['pv'],
                'v' => (int)$r['v'],
            ], $rows);
        });
    }

    /**
     * Gesamtsumme + Anzahl unterschiedlicher dimkeys einer Dimension (optional unter einem
     * $parentKey-Praefix) im Zeitfenster -- Basis fuer die Prozentanzeige und "+ N weitere"
     * bei serverseitigem Top-N.
     *
     * @return array{pv: int, v: int, count: int}
     */
    public function dimSummary(int $siteId, string $from, string $bis, string $dim, ?string $parentKey = null): array
    {
        $cacheKey = "dimSummary:$siteId:$from:$bis:$dim:" . ($parentKey ?? '');
        return $this->cached($cacheKey, function () use ($siteId, $from, $bis, $dim, $parentKey) {
            $qb = $this->qb('cube');
            $qb->addSelectLiteral(
                'COALESCE(SUM(pv), 0) AS pv',
                'COALESCE(SUM(v), 0) AS v',
                'COUNT(DISTINCT dimkey) AS cnt'
            )
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter($dim)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                    // Konsistent zu topN(): leere Keys zaehlen weder in die Prozentbasis
                    // noch in "+ N weitere".
                    $qb->expr()->neq('dimkey', $qb->createNamedParameter('')),
                );
            $this->applyParentPrefix($qb, $parentKey);
            $row = $qb->executeQuery()->fetchAssociative();
            return [
                'pv' => (int)($row['pv'] ?? 0),
                'v' => (int)($row['v'] ?? 0),
                'count' => (int)($row['cnt'] ?? 0),
            ];
        });
    }
}
