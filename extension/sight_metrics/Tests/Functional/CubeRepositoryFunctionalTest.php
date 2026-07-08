<?php

declare(strict_types=1);

namespace SightMetrics\Tests\Functional;

use SightMetrics\Domain\Repository\CubeRepository;
use TYPO3\CMS\Core\Cache\CacheManager;
use TYPO3\CMS\Core\Configuration\ExtensionConfiguration;
use TYPO3\CMS\Core\Database\Connection;
use TYPO3\CMS\Core\Database\ConnectionPool;
use TYPO3\CMS\Core\Utility\GeneralUtility;
use TYPO3\TestingFramework\Core\Functional\FunctionalTestCase;

// CubeRepository is a private DI service -> instantiate directly instead of getContainer()->get()

/**
 * Functional tests for CubeRepository: real SQLite connection, no MariaDB needed.
 * Checks: query correctness, site filtering, multi-site isolation.
 */
final class CubeRepositoryFunctionalTest extends FunctionalTestCase
{
    protected array $testExtensionsToLoad = [];

    protected function setUp(): void
    {
        parent::setUp();

        $GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube'] = [
            'driver' => 'pdo_sqlite',
            'memory' => true,
        ];

        $c = $this->cubeConn();
        $c->executeStatement('CREATE TABLE IF NOT EXISTS meta  (site_id INTEGER, site TEXT, von TEXT, bis TEXT, visits_total INTEGER, pageviews_total INTEGER, uniques_total INTEGER, bounces_total INTEGER, bytes_total INTEGER, erzeugt TEXT, tz TEXT)');
        $c->executeStatement('CREATE TABLE IF NOT EXISTS daily (site_id INTEGER, datum TEXT, visits INTEGER, pageviews INTEGER, uniques INTEGER, bounces INTEGER, bytes INTEGER)');
        $c->executeStatement('CREATE TABLE IF NOT EXISTS cube  (site_id INTEGER, datum TEXT, dim TEXT, parent TEXT, dimkey TEXT, pv INTEGER, v INTEGER)');
        // ConnectionPool caches the SQLite connection as a singleton -> delete data from previous tests
        $c->executeStatement('DELETE FROM meta');
        $c->executeStatement('DELETE FROM daily');
        $c->executeStatement('DELETE FROM cube');
    }

    // ---- Fixture helper -------------------------------------------------------

    private function cubeConn(): Connection
    {
        return GeneralUtility::makeInstance(ConnectionPool::class)->getConnectionByName('cube');
    }

    private function repo(): CubeRepository
    {
        // Cache "sight_metrics" is not registered without ext_localconf.php -> CubeRepository
        // fault-tolerantly falls back to live queries (see CubeRepository::cached()).
        return new CubeRepository(
            GeneralUtility::makeInstance(ConnectionPool::class),
            GeneralUtility::makeInstance(CacheManager::class),
            GeneralUtility::makeInstance(ExtensionConfiguration::class),
        );
    }

    private function insertSite(int $siteId, string $siteName, array $cubeRows = []): void
    {
        $c = $this->cubeConn();
        $c->insert('meta', [
            'site_id' => $siteId, 'site' => $siteName,
            'von' => '2026-01-01', 'bis' => '2026-01-31',
            'visits_total' => 3, 'pageviews_total' => 5, 'uniques_total' => 2,
            'bounces_total' => 2, 'bytes_total' => 6700, 'erzeugt' => '2026-02-01 00:00', 'tz' => 'UTC',
        ]);
        $c->insert('daily', [
            'site_id' => $siteId, 'datum' => '2026-01-01',
            'visits' => 3, 'pageviews' => 5, 'uniques' => 2, 'bounces' => 2, 'bytes' => 6700,
        ]);
        foreach ($cubeRows as $row) {
            $c->insert('cube', array_merge(['site_id' => $siteId, 'datum' => '2026-01-01'], $row));
        }
    }

    // ---- Tests ---------------------------------------------------------------

    public function testSitesReturnsEmptyWhenNoData(): void
    {
        self::assertSame([], $this->repo()->sites());
    }

    public function testSitesReturnsAllSitesOrdered(): void
    {
        $this->insertSite(2, 'B-Site');
        $this->insertSite(1, 'A-Site');

        $sites = $this->repo()->sites();

        self::assertCount(2, $sites);
        self::assertSame('A-Site', $sites[0]['site']);
        self::assertSame('B-Site', $sites[1]['site']);
    }

    public function testMetaReturnsCorrectAggregatesForSite(): void
    {
        $this->insertSite(1, 'Test-Site');

        $meta = $this->repo()->meta(1);

        self::assertSame('Test-Site', $meta['site']);
        self::assertSame(3, (int)$meta['visits_total']);
        self::assertSame(5, (int)$meta['pageviews_total']);
        self::assertSame(2, (int)$meta['uniques_total']);
        self::assertSame(6700, (int)$meta['bytes_total']);
    }

    public function testMetaReturnsEmptyArrayForUnknownSite(): void
    {
        $this->insertSite(1, 'Test-Site');

        self::assertSame([], $this->repo()->meta(99));
    }

    public function testDailyReturnsRowsForCorrectSite(): void
    {
        $this->insertSite(1, 'Site-1');
        $this->insertSite(2, 'Site-2');

        $daily = $this->repo()->daily(1, '2026-01-01', '2026-01-31');

        self::assertCount(1, $daily);
        self::assertSame('2026-01-01', $daily[0]['datum']);
        self::assertSame(3, (int)$daily[0]['visits']);
    }

    public function testDailyAndCubeAreFilteredByDateWindow(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'browser', 'dimkey' => 'Chrome', 'pv' => 5, 'v' => 3],
        ]);
        // Rows outside the window (different day) -- must be excluded.
        $c = $this->cubeConn();
        $c->insert('daily', ['site_id' => 1, 'datum' => '2026-03-15', 'visits' => 9, 'pageviews' => 9, 'uniques' => 9, 'bounces' => 0, 'bytes' => 0]);
        $c->insert('cube', ['site_id' => 1, 'datum' => '2026-03-15', 'dim' => 'browser', 'dimkey' => 'Edge', 'pv' => 9, 'v' => 9]);

        $daily = $this->repo()->daily(1, '2026-01-01', '2026-01-31');
        $cube = $this->repo()->cube(1, '2026-01-01', '2026-01-31');

        self::assertCount(1, $daily, 'nur die Zeile im Fenster');
        self::assertSame('2026-01-01', $daily[0]['datum']);
        self::assertNotContains('Edge', array_column($cube, 'dimkey'), 'Zeile ausserhalb des Fensters ausgeschlossen');
        self::assertContains('Chrome', array_column($cube, 'dimkey'));
    }

    public function testCubeReturnsRowsFilteredBySite(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'browser', 'dimkey' => 'Chrome', 'pv' => 5, 'v' => 3],
            ['dim' => 'url',     'dimkey' => '/a',     'pv' => 3, 'v' => 3],
        ]);
        $this->insertSite(2, 'Site-2', [
            ['dim' => 'browser', 'dimkey' => 'Firefox', 'pv' => 2, 'v' => 1],
        ]);

        $cube = $this->repo()->cube(1, '2026-01-01', '2026-01-31');

        self::assertCount(2, $cube);
        $dims = array_column($cube, 'dimkey');
        self::assertContains('Chrome',  $dims);
        self::assertContains('/a',      $dims);
        self::assertNotContains('Firefox', $dims);
    }

    public function testSiteIsolation(): void
    {
        $this->insertSite(1, 'Behörde A');
        $this->insertSite(2, 'Behörde B');

        $metaA = $this->repo()->meta(1);
        $metaB = $this->repo()->meta(2);

        self::assertSame('Behörde A', $metaA['site']);
        self::assertSame('Behörde B', $metaB['site']);
    }

    public function testDailyReturnsEmptyForSiteWithoutData(): void
    {
        $this->insertSite(1, 'Site-1');

        self::assertSame([], $this->repo()->daily(99, '2026-01-01', '2026-01-31'));
    }

    public function testCubeReturnsEmptyWhenNoDimensionRows(): void
    {
        $this->insertSite(1, 'Site-ohne-Cube');

        self::assertSame([], $this->repo()->cube(1, '2026-01-01', '2026-01-31'));
    }

    public function testCubeReturnsEmptyForUnknownSite(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'browser', 'dimkey' => 'Chrome', 'pv' => 5, 'v' => 3],
        ]);

        self::assertSame([], $this->repo()->cube(99, '2026-01-01', '2026-01-31'));
    }

    public function testSitesFiltersByAllowedIds(): void
    {
        $this->insertSite(1, 'Site-A');
        $this->insertSite(2, 'Site-B');
        $this->insertSite(3, 'Site-C');

        $sites = $this->repo()->sites([1, 3]);

        self::assertCount(2, $sites);
        $names = array_column($sites, 'site');
        self::assertContains('Site-A', $names);
        self::assertContains('Site-C', $names);
        self::assertNotContains('Site-B', $names);
    }

    public function testSitesEmptyAllowedIdsReturnsAll(): void
    {
        $this->insertSite(1, 'Site-A');
        $this->insertSite(2, 'Site-B');

        self::assertCount(2, $this->repo()->sites([]));
    }

    public function testCubeExcludesGovernedDims(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'browser', 'dimkey' => 'Chrome', 'pv' => 5, 'v' => 3],
            ['dim' => 'keyword', 'dimkey' => 'rathaus', 'pv' => 2, 'v' => 1],
        ]);

        $cube = $this->repo()->cube(1, '2026-01-01', '2026-01-31', ['keyword', 'entry']);

        $dims = array_column($cube, 'dim');
        self::assertContains('browser', $dims);
        self::assertNotContains('keyword', $dims, 'per excludeDims ausgeschlossene Dimension darf nicht mitkommen');
    }

    public function testTopNOrdersByMetricDescendingAndRespectsLimitOffset(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'keyword', 'dimkey' => 'a', 'pv' => 1, 'v' => 1],
            ['dim' => 'keyword', 'dimkey' => 'b', 'pv' => 1, 'v' => 5],
            ['dim' => 'keyword', 'dimkey' => 'c', 'pv' => 1, 'v' => 3],
        ]);

        $top = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'keyword', 'v', 2);
        self::assertSame(['b', 'c'], array_column($top, 'dimkey'), 'absteigend nach v sortiert, auf 2 begrenzt');

        $page2 = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'keyword', 'v', 2, 2);
        self::assertSame(['a'], array_column($page2, 'dimkey'), 'Offset 2 liefert die verbleibende dritte Zeile');
    }

    public function testTopNAggregatesAcrossMultipleDays(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'keyword', 'dimkey' => 'rathaus', 'pv' => 3, 'v' => 2],
        ]);
        $this->cubeConn()->insert('cube', [
            'site_id' => 1, 'datum' => '2026-01-02', 'dim' => 'keyword', 'dimkey' => 'rathaus', 'pv' => 4, 'v' => 1,
        ]);

        $top = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'keyword', 'v', 8);

        self::assertCount(1, $top);
        self::assertSame(7, (int)$top[0]['pv']);
        self::assertSame(3, (int)$top[0]['v']);
    }

    public function testTopNRejectsInvalidMetric(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'keyword', 'DROP TABLE cube; --', 8);
    }

    public function testDimSummaryReturnsTotalsAndDistinctCount(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'keyword', 'dimkey' => 'a', 'pv' => 1, 'v' => 2],
            ['dim' => 'keyword', 'dimkey' => 'b', 'pv' => 3, 'v' => 4],
        ]);

        $summary = $this->repo()->dimSummary(1, '2026-01-01', '2026-01-31', 'keyword');

        self::assertSame(['pv' => 4, 'v' => 6, 'count' => 2], $summary);
    }

    public function testDimSummaryIsZeroForUnknownDim(): void
    {
        $this->insertSite(1, 'Site-1');

        $summary = $this->repo()->dimSummary(1, '2026-01-01', '2026-01-31', 'keyword');

        self::assertSame(['pv' => 0, 'v' => 0, 'count' => 0], $summary);
    }

    // ---- Drill-down (parentKey), phase 2 --------------------------------------

    public function testTopNWithParentKeyReturnsOnlyMatchingChildren(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'browser_version', 'parent' => 'Chrome', 'dimkey' => '120', 'pv' => 1, 'v' => 5],
            ['dim' => 'browser_version', 'parent' => 'Chrome', 'dimkey' => '119', 'pv' => 1, 'v' => 2],
            ['dim' => 'browser_version', 'parent' => 'Firefox', 'dimkey' => '115', 'pv' => 1, 'v' => 9],
        ]);

        $children = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'browser_version', 'v', 8, 0, 'Chrome');

        self::assertSame(['120', '119'], array_column($children, 'dimkey'));
    }

    public function testTopNParentKeyDoesNotMatchUnrelatedPrefix(): void
    {
        // Schema v2: 'parent' is an exact equality -- "Chromium" must not match
        // parentKey "Chrom" (this used to require careful CHR(31) prefix logic).
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'browser_version', 'parent' => 'Chromium', 'dimkey' => '1', 'pv' => 1, 'v' => 1],
            ['dim' => 'browser_version', 'parent' => 'Chrom', 'dimkey' => '1', 'pv' => 1, 'v' => 2],
        ]);

        $children = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'browser_version', 'v', 8, 0, 'Chrom');

        self::assertSame([['dimkey' => '1', 'pv' => 1, 'v' => 2]], $children);
    }

    public function testTopNParentKeyHandlesMultibyteLabelsCorrectly(): void
    {
        // Multibyte UTF-8 parent (umlaut) must match exactly.
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'referrer_name', 'parent' => 'Bürgeramt', 'dimkey' => 'seite-a', 'pv' => 1, 'v' => 3],
        ]);

        $children = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'referrer_name', 'v', 8, 0, 'Bürgeramt');

        self::assertSame(['seite-a'], array_column($children, 'dimkey'));
    }

    public function testTopNExcludesEmptyDimkeysAndReturnsIntTypes(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'keyword', 'dimkey' => 'rathaus', 'pv' => 5, 'v' => 3],
            ['dim' => 'keyword', 'dimkey' => '', 'pv' => 99, 'v' => 99],
        ]);

        $top = $this->repo()->topN(1, '2026-01-01', '2026-01-31', 'keyword', 'v', 8);

        self::assertSame(
            [['dimkey' => 'rathaus', 'pv' => 5, 'v' => 3]],
            $top,
            'leerer dimkey ausgefiltert, pv/v als int (nicht als DB-String)'
        );
    }

    public function testDimSummaryExcludesEmptyDimkeys(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'keyword', 'dimkey' => 'rathaus', 'pv' => 5, 'v' => 3],
            ['dim' => 'keyword', 'dimkey' => '', 'pv' => 99, 'v' => 99],
        ]);

        $summary = $this->repo()->dimSummary(1, '2026-01-01', '2026-01-31', 'keyword');

        self::assertSame(['pv' => 5, 'v' => 3, 'count' => 1], $summary, 'leerer dimkey zaehlt weder in Summen noch in count');
    }

    // ---- Page tree (urlTreeChildren/urlTree) ----------------------------------

    public function testUrlTreeChildrenSegmentsAndAggregatesSubtrees(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'url', 'dimkey' => '/a', 'pv' => 5, 'v' => 3],
            ['dim' => 'url', 'dimkey' => '/a/x', 'pv' => 2, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/a/y', 'pv' => 1, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/b', 'pv' => 4, 'v' => 2],
        ]);

        $tree = $this->repo()->urlTreeChildren(1, '2026-01-01', '2026-01-31', '', 8);

        self::assertSame(2, $tree['total']['count']);
        self::assertSame(
            [
                // '/a' aggregates the page itself (5) + subtree (2+1) = 8, has children
                ['seg' => 'a', 'path' => '/a', 'pv' => 8, 'v' => 5, 'hasChildren' => true],
                ['seg' => 'b', 'path' => '/b', 'pv' => 4, 'v' => 2, 'hasChildren' => false],
            ],
            $tree['rows'],
            'Segmente mit Unterbaum-Summen, absteigend nach pv'
        );
    }

    public function testUrlTreeChildrenOfSubPathExcludeSelfAndSiblings(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'url', 'dimkey' => '/a', 'pv' => 5, 'v' => 3],
            ['dim' => 'url', 'dimkey' => '/a/x', 'pv' => 2, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/a/x/tief', 'pv' => 1, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/ab', 'pv' => 9, 'v' => 9],
        ]);

        $tree = $this->repo()->urlTreeChildren(1, '2026-01-01', '2026-01-31', '/a', 8);

        self::assertSame(
            [['seg' => 'x', 'path' => '/a/x', 'pv' => 3, 'v' => 2, 'hasChildren' => true]],
            $tree['rows'],
            'weder die Seite /a selbst noch der Praefix-Nachbar /ab duerfen als Kind erscheinen'
        );
    }

    public function testUrlTreeChildrenRespectLimitOffsetAndCount(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'url', 'dimkey' => '/eins', 'pv' => 3, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/zwei', 'pv' => 2, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/drei', 'pv' => 1, 'v' => 1],
        ]);

        $page1 = $this->repo()->urlTreeChildren(1, '2026-01-01', '2026-01-31', '', 2);
        self::assertSame(['eins', 'zwei'], array_column($page1['rows'], 'seg'));
        self::assertSame(3, $page1['total']['count'], 'count = alle Segmente, nicht nur die Seite');

        $page2 = $this->repo()->urlTreeChildren(1, '2026-01-01', '2026-01-31', '', 2, 2);
        self::assertSame(['drei'], array_column($page2['rows'], 'seg'));
    }

    public function testUrlTreeDepthTwoPreloadsGrandchildren(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'url', 'dimkey' => '/a/x', 'pv' => 2, 'v' => 1],
            ['dim' => 'url', 'dimkey' => '/b', 'pv' => 1, 'v' => 1],
        ]);

        $tree = $this->repo()->urlTree(1, '2026-01-01', '2026-01-31', '', 2, 8);

        self::assertSame('a', $tree['rows'][0]['seg']);
        self::assertSame(
            [['seg' => 'x', 'path' => '/a/x', 'pv' => 2, 'v' => 1, 'hasChildren' => false]],
            $tree['rows'][0]['children'],
            'depth=2 laedt die Kind-Ebene der ersten Ebene mit'
        );
        self::assertSame(1, $tree['rows'][0]['childTotal']['count']);
        self::assertArrayNotHasKey('children', $tree['rows'][1], 'Blatt-Knoten bekommt keine children');
    }

    public function testDimSummaryWithParentKeyOnlyCountsMatchingChildren(): void
    {
        $this->insertSite(1, 'Site-1', [
            ['dim' => 'os_version', 'parent' => 'Windows', 'dimkey' => '11', 'pv' => 1, 'v' => 4],
            ['dim' => 'os_version', 'parent' => 'Windows', 'dimkey' => '10', 'pv' => 1, 'v' => 2],
            ['dim' => 'os_version', 'parent' => 'macOS', 'dimkey' => '14', 'pv' => 1, 'v' => 7],
        ]);

        $summary = $this->repo()->dimSummary(1, '2026-01-01', '2026-01-31', 'os_version', 'Windows');

        self::assertSame(['pv' => 2, 'v' => 6, 'count' => 2], $summary);
    }

    // ---- Schema version (DB contract, docs/SCHEMA.md) ---------------------------

    public function testSchemaVersionIsNullForLegacyDatabases(): void
    {
        // Fixture meta without a schema_version value (column missing or NULL) = legacy ingestion.
        $this->insertSite(1, 'Site-1');

        self::assertNull($this->repo()->schemaVersion());
    }

    public function testSchemaVersionReturnsHighestStampedVersion(): void
    {
        $this->insertSite(1, 'Site-1');
        $c = $this->cubeConn();
        try {
            $c->executeStatement('ALTER TABLE meta ADD COLUMN schema_version INTEGER');
        } catch (\Throwable) {
            // Column already exists (singleton SQLite connection persists across tests)
        }
        $c->executeStatement('UPDATE meta SET schema_version = 5');

        self::assertSame(5, $this->repo()->schemaVersion());
    }
}
