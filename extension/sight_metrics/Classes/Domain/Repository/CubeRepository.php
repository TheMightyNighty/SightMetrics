<?php

declare(strict_types=1);

namespace SightMetrics\Domain\Repository;

use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\ParameterType;
use SightMetrics\Support\Params;
use SightMetrics\Support\TopNWindows;
use TYPO3\CMS\Core\Cache\CacheManager;
use TYPO3\CMS\Core\Cache\Frontend\FrontendInterface;
use TYPO3\CMS\Core\Configuration\ExtensionConfiguration;
use TYPO3\CMS\Core\Database\ConnectionPool;
use TYPO3\CMS\Core\Database\Query\QueryBuilder;

/**
 * Reads the cube tables via a SEPARATE, read-only DB connection ('cube').
 * No Extbase, no TCA -- just DBAL SELECTs against external tables
 * (section 11.1/11.4). Multi-site: all read accesses are filtered by site_id.
 *
 * daily()/cube() are the reads whose volume grows with time window/cardinality;
 * they are cached short-lived via the TYPO3 cache "sight_metrics" (TTL per
 * extension configuration, 0 = disabled). meta()/sites() are single rows/small
 * lists and deliberately stay live, so e.g. a new site is immediately visible.
 */
final class CubeRepository
{
    /**
     * Supported version of the DB contract (tables cube/daily/meta, see
     * docs/SCHEMA.md). The ingestion writes its version to meta.schema_version;
     * if the version there is NEWER, reader and writer no longer match.
     */
    public const SCHEMA_VERSION = 2;

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
            if (\is_array($conf) && isset($conf['cacheLifetime']) && $conf['cacheLifetime'] !== '') {
                return max(0, Params::toInt($conf['cacheLifetime']));
            }
        } catch (\Throwable) {
        }
        // High default is safe: cache keys include the from/bis window, and
        // meta.bis moves forward with every nightly import -- the default view
        // therefore gets fresh keys automatically, no manual flush needed.
        return 21600;
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
        // Cache configuration missing (e.g. unit/functional tests without a loaded
        // ext_localconf.php) -> caching is a pure perf feature, not a
        // correctness requirement, so fault-tolerantly fall back to a live query here.
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
        $qb->getRestrictions()->removeAll(); // cube tables have no TCA
        return $qb;
    }

    /**
     * Available sites (for the selector).
     * $allowedIds: if set, only return these site_ids (TYPO3 site mapping).
     * Empty list = no filter (all sites visible, backward compatibility).
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
     * Highest schema version of the DB contract stored in meta.
     * null = column missing or empty (legacy ingestion predating versioning) --
     * treated as compatible; only a NEWER version than SCHEMA_VERSION
     * is a hard error (see DashboardController::assertSchemaCompatible()).
     */
    public function schemaVersion(): ?int
    {
        try {
            $qb = $this->qb('meta');
            $value = $qb->addSelectLiteral('MAX(schema_version)')->from('meta')
                ->executeQuery()->fetchOne();
            return $value === null ? null : Params::toInt($value);
        } catch (\Throwable) {
            return null; // column doesn't exist: existing DB from an older ingestion
        }
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
        return $row === false ? [] : $row;
    }

    /**
     * Daily aggregates, limited to the time window [$from, $bis] (server-side).
     * Limits the transfer volume independently of the cube DB's retention.
     *
     * @return list<array<string,mixed>>
     */
    public function daily(int $siteId, string $from, string $bis): array
    {
        /** @var list<array<string,mixed>> $rows cached() is untyped (mixed) */
        $rows = $this->cached("daily:$siteId:$from:$bis", function () use ($siteId, $from, $bis) {
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
        return $rows;
    }

    /**
     * Cube rows, limited to the time window [$from, $bis] (server-side).
     * $excludeDims: dimensions that are NOT delivered completely (see TopNDims) --
     * for these, topN() instead delivers only the top-N rows, to limit the
     * transfer volume at high cardinality.
     *
     * @param list<string> $excludeDims
     * @return list<array<string,mixed>>
     */
    public function cube(int $siteId, string $from, string $bis, array $excludeDims = []): array
    {
        $excludeKey = $excludeDims === [] ? '' : ':ex=' . implode(',', $excludeDims);
        /** @var list<array<string,mixed>> $rows cached() is untyped (mixed) */
        $rows = $this->cached("cube:$siteId:$from:$bis$excludeKey", function () use ($siteId, $from, $bis, $excludeDims) {
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
        return $rows;
    }

    /**
     * Restricts a cube query to child rows of a parent category (drill-down).
     * Schema v2: the parent value lives in its own 'parent' column -- a plain,
     * indexable equality instead of the former CHR(31) prefix matching.
     */
    private function applyParentFilter(QueryBuilder $qb, ?string $parentKey): void
    {
        if ($parentKey === null) {
            return;
        }
        $qb->andWhere($qb->expr()->eq('parent', $qb->createNamedParameter($parentKey)));
    }

    /**
     * Top-N rows of a dimension, sorted descending by $metric ('pv' or 'v').
     * For server-side Top-N + lazy-loading on high-cardinality dimensions (see
     * TopNDims/ROADMAP.md). $parentKey: if set, only child rows of this parent category
     * (drill-down, 'parent' column) -- see applyParentFilter().
     *
     * $windowLabel: optional preset label the client claims [$from,$bis] corresponds
     * to (docs/topn-precompute-spec.md). Only used to serve from the precomputed
     * `topn` table when it verifiably matches (TopNWindows::boundsFor()) AND the
     * requested page lies within the precomputed top-100 ($offset+$limit<=100);
     * any mismatch or precomputed-table miss falls back to the live query below
     * -- the label is never trusted blindly, so a stale/forged value cannot
     * produce wrong results, only a slower live query.
     *
     * @return list<array{dimkey: string, pv: int, v: int}>
     */
    public function topN(int $siteId, string $from, string $bis, string $dim, string $metric, int $limit, int $offset = 0, ?string $parentKey = null, ?string $windowLabel = null): array
    {
        if (!in_array($metric, ['pv', 'v'], true)) {
            throw new \InvalidArgumentException('Ungueltige Metrik: ' . $metric);
        }
        if ($windowLabel !== null && $offset + $limit <= 100) {
            $precomputed = $this->topNFromPrecompute($siteId, $from, $bis, $dim, $limit, $offset, $parentKey, $windowLabel);
            if ($precomputed !== null) {
                return $precomputed;
            }
        }
        $cacheKey = "topN:$siteId:$from:$bis:$dim:$metric:$limit:$offset:" . ($parentKey ?? '');
        /** @var list<array{dimkey: string, pv: int, v: int}> $rows cached() is untyped (mixed) */
        $rows = $this->cached($cacheKey, function () use ($siteId, $from, $bis, $dim, $metric, $limit, $offset, $parentKey) {
            $qb = $this->qb('cube');
            $qb->select('dimkey')
                ->addSelectLiteral('SUM(pv) AS pv', 'SUM(v) AS v')
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter($dim)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                    // Don't show empty keys (previously filtered client-side in agg());
                    // '<>' also excludes NULL dimkeys.
                    $qb->expr()->neq('dimkey', $qb->createNamedParameter('')),
                );
            $this->applyParentFilter($qb, $parentKey);
            $rows = $qb->groupBy('dimkey')
                ->orderBy($metric, 'DESC')
                ->setMaxResults($limit)
                ->setFirstResult($offset)
                ->executeQuery()->fetchAllAssociative();
            // mysqli returns aggregate sums as strings -- cast explicitly here
            // for a clean JSON contract (client computes with numbers).
            return array_map(static fn(array $r): array => [
                'dimkey' => Params::toString($r['dimkey'] ?? null),
                'pv' => Params::toInt($r['pv'] ?? null),
                'v' => Params::toInt($r['v'] ?? null),
            ], $rows);
        });
        return $rows;
    }

    /** WHERE site_id/dim/window/parent for `topn` lookups (SELECT columns/order left to the caller). */
    private function topnQueryBase(int $siteId, string $dim, string $windowLabel, ?string $parentKey): QueryBuilder
    {
        $qb = $this->qb('topn');
        $qb->from('topn')->where(
            $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
            $qb->expr()->eq('dim', $qb->createNamedParameter($dim)),
            // Column 'win', not 'window' -- reserved word in DuckDB/MariaDB (window functions).
            $qb->expr()->eq('win', $qb->createNamedParameter($windowLabel)),
        );
        if ($parentKey === null) {
            $qb->andWhere($qb->expr()->isNull('parent'));
        } else {
            $qb->andWhere($qb->expr()->eq('parent', $qb->createNamedParameter($parentKey)));
        }
        return $qb;
    }

    /**
     * Serves topN() from the precomputed `topn` table (docs/topn-precompute-spec.md)
     * when $windowLabel verifiably corresponds to [$from,$bis] (TopNWindows::boundsFor()).
     * Returns null (defer to the live query in topN()) on any mismatch, or if the
     * table simply hasn't been populated yet for this (site, window, dim, parent) --
     * detected via a separate rnk=1 probe, since an empty page at $offset>0 is
     * otherwise indistinguishable from "not populated" (both look like zero rows).
     *
     * @return list<array{dimkey: string, pv: int, v: int}>|null
     */
    private function topNFromPrecompute(int $siteId, string $from, string $bis, string $dim, int $limit, int $offset, ?string $parentKey, string $windowLabel): ?array
    {
        $meta = $this->meta($siteId);
        $bounds = TopNWindows::boundsFor($windowLabel, Params::toString($meta['von'] ?? null), Params::toString($meta['bis'] ?? null));
        if ($bounds === null || $bounds[0] !== $from || $bounds[1] !== $bis) {
            return null;
        }

        $populated = $this->topnQueryBase($siteId, $dim, $windowLabel, $parentKey)
            ->select('rnk')->andWhere($this->qb('topn')->expr()->eq('rnk', 1))
            ->executeQuery()->fetchOne();
        if ($populated === false) {
            return null; // not populated yet (fresh site / pre-rollout DB) -- fall back to live
        }

        $rows = $this->topnQueryBase($siteId, $dim, $windowLabel, $parentKey)
            ->select('dimkey', 'pv', 'v')
            ->orderBy('rnk')
            ->setMaxResults($limit)
            ->setFirstResult($offset)
            ->executeQuery()->fetchAllAssociative();
        return array_map(static fn(array $r): array => [
            'dimkey' => Params::toString($r['dimkey'] ?? null),
            'pv' => Params::toInt($r['pv'] ?? null),
            'v' => Params::toInt($r['v'] ?? null),
        ], $rows);
    }

    /**
     * Total sum + count of distinct dimkeys of a dimension (optionally under a
     * $parentKey prefix) within the time window -- basis for the percentage display and "+ N more"
     * with server-side Top-N.
     *
     * @return array{pv: int, v: int, count: int}
     */
    public function dimSummary(int $siteId, string $from, string $bis, string $dim, ?string $parentKey = null): array
    {
        $cacheKey = "dimSummary:$siteId:$from:$bis:$dim:" . ($parentKey ?? '');
        /** @var array{pv: int, v: int, count: int} $summary cached() is untyped (mixed) */
        $summary = $this->cached($cacheKey, function () use ($siteId, $from, $bis, $dim, $parentKey) {
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
                    // Consistent with topN(): empty keys count neither in the percentage base
                    // nor in "+ N more".
                    $qb->expr()->neq('dimkey', $qb->createNamedParameter('')),
                );
            $this->applyParentFilter($qb, $parentKey);
            $row = $qb->executeQuery()->fetchAssociative();
            return [
                'pv' => Params::toInt(\is_array($row) ? ($row['pv'] ?? null) : null),
                'v' => Params::toInt(\is_array($row) ? ($row['v'] ?? null) : null),
                'count' => Params::toInt(\is_array($row) ? ($row['cnt'] ?? null) : null),
            ];
        });
        return $summary;
    }

    /**
     * Direct child segments of a path prefix in the page tree ('url' dimension), with
     * subtree sums. $path = '' (root) or '/seg(/seg)*'. Per segment, all
     * rows are aggregated whose dimkey lies below "$path/" -- the sum of a
     * segment thus contains both the page itself (e.g. '/a/b') and all
     * deeper paths ('/a/b/c'), identical to the earlier client-side buildTree()
     * aggregation. 'hasChildren' indicates whether further levels exist below
     * the segment (for expanding in the frontend).
     *
     * Portable SQL: SUBSTR/INSTR/CASE exist in MariaDB/MySQL and SQLite; the
     * segment extraction runs completely in SQL, so that not all URL rows have
     * to be transferred at the root of large sites. SUBSTR counts Unicode codepoints
     * (portable across MariaDB/SQLite), hence mb_strlen() for the prefix length.
     *
     * @return array{
     *   rows: list<array{seg: string, path: string, pv: int, v: int, hasChildren: bool}>,
     *   total: array{count: int}
     * }
     */
    public function urlTreeChildren(int $siteId, string $from, string $bis, string $path, int $limit, int $offset = 0): array
    {
        $cacheKey = "urlTree:$siteId:$from:$bis:$limit:$offset:$path";
        /** @var array{rows: list<array{seg: string, path: string, pv: int, v: int, hasChildren: bool}>, total: array{count: int}} $level cached() is untyped (mixed) */
        $level = $this->cached($cacheKey, function () use ($siteId, $from, $bis, $path, $limit, $offset) {
            $prefix = $path . '/';
            $plen = mb_strlen($prefix, 'UTF-8');
            // Path remainder after the prefix; from this the first segment (up to the next '/').
            $rest = 'SUBSTR(dimkey, ' . ($plen + 1) . ')';
            $seg = "CASE WHEN INSTR($rest, '/') > 0 THEN SUBSTR($rest, 1, INSTR($rest, '/') - 1) ELSE $rest END";
            // Child levels present? Only if there's still something after the '/'
            // (protects against pseudo-children from trailing slashes like '/a/').
            $hasChildren = "MAX(CASE WHEN INSTR($rest, '/') > 0 AND SUBSTR($rest, INSTR($rest, '/') + 1) <> '' THEN 1 ELSE 0 END)";

            $qb = $this->qb('cube');
            $qb->addSelectLiteral("$seg AS seg", 'SUM(pv) AS pv', 'SUM(v) AS v', "$hasChildren AS has_children")
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter('url')),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                )
                // Raw prefix fragment (expr()->eq()
                // would quote the SUBSTR expression as an identifier).
                ->andWhere("SUBSTR(dimkey, 1, $plen) = " . $qb->createNamedParameter($prefix))
                ->groupBy('seg')
                ->having("seg <> ''")
                ->orderBy('pv', 'DESC')
                ->setMaxResults($limit)
                ->setFirstResult($offset);
            $rows = array_map(static fn(array $r): array => [
                'seg' => Params::toString($r['seg'] ?? null),
                'path' => $path . '/' . Params::toString($r['seg'] ?? null),
                'pv' => Params::toInt($r['pv'] ?? null),
                'v' => Params::toInt($r['v'] ?? null),
                'hasChildren' => (bool)$r['has_children'],
            ], $qb->executeQuery()->fetchAllAssociative());

            // Total count of distinct segments (for "+ N more"); CASE without ELSE
            // returns NULL for empty segments -> COUNT DISTINCT doesn't count them.
            $qbCount = $this->qb('cube');
            $qbCount->addSelectLiteral("COUNT(DISTINCT CASE WHEN $seg <> '' THEN $seg END) AS cnt")
                ->from('cube')
                ->where(
                    $qbCount->expr()->eq('site_id', $qbCount->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qbCount->expr()->eq('dim', $qbCount->createNamedParameter('url')),
                    $qbCount->expr()->gte('datum', $qbCount->createNamedParameter($from)),
                    $qbCount->expr()->lte('datum', $qbCount->createNamedParameter($bis)),
                )
                ->andWhere("SUBSTR(dimkey, 1, $plen) = " . $qbCount->createNamedParameter($prefix));
            $count = Params::toInt($qbCount->executeQuery()->fetchOne());

            return ['rows' => $rows, 'total' => ['count' => $count]];
        });
        return $level;
    }

    /**
     * Page tree up to $depth levels deep (1 or 2). With depth=2, each child of the
     * first level directly has its child level loaded too ('children'/'childTotal') -- the
     * initial payload thus shows the first two levels without lazy-loading, as before.
     *
     * @return array{rows: list<array<string,mixed>>, total: array{count: int}}
     */
    public function urlTree(int $siteId, string $from, string $bis, string $path, int $depth, int $limit, int $offset = 0): array
    {
        $level = $this->urlTreeChildren($siteId, $from, $bis, $path, $limit, $offset);
        if ($depth >= 2) {
            foreach ($level['rows'] as $i => $row) {
                if (!$row['hasChildren']) {
                    continue;
                }
                $child = $this->urlTreeChildren($siteId, $from, $bis, $row['path'], $limit);
                $level['rows'][$i]['children'] = $child['rows'];
                $level['rows'][$i]['childTotal'] = $child['total'];
            }
        }
        return $level;
    }
}
