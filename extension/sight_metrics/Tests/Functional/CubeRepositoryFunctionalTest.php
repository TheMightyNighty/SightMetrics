<?php

declare(strict_types=1);

namespace SightMetrics\Tests\Functional;

use SightMetrics\Domain\Repository\CubeRepository;
use TYPO3\CMS\Core\Database\Connection;
use TYPO3\CMS\Core\Database\ConnectionPool;
use TYPO3\CMS\Core\Utility\GeneralUtility;
use TYPO3\TestingFramework\Core\Functional\FunctionalTestCase;

// CubeRepository ist ein privater DI-Service → direkt instanziieren statt getContainer()->get()

/**
 * Functional-Tests für CubeRepository: echte SQLite-Verbindung, kein MariaDB nötig.
 * Prüft: Query-Korrektheit, Site-Filterung, Multi-Site-Isolation.
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
        $c->executeStatement('CREATE TABLE IF NOT EXISTS meta  (site_id INTEGER, site TEXT, von TEXT, bis TEXT, visits_total INTEGER, pageviews_total INTEGER, uniques_total INTEGER, bounces_total INTEGER, bytes_total INTEGER, erzeugt TEXT)');
        $c->executeStatement('CREATE TABLE IF NOT EXISTS daily (site_id INTEGER, datum TEXT, visits INTEGER, pageviews INTEGER, uniques INTEGER, bounces INTEGER, bytes INTEGER)');
        $c->executeStatement('CREATE TABLE IF NOT EXISTS cube  (site_id INTEGER, datum TEXT, dim TEXT, dimkey TEXT, pv INTEGER, v INTEGER)');
        // ConnectionPool cached die SQLite-Verbindung als Singleton → Daten voheriger Tests löschen
        $c->executeStatement('DELETE FROM meta');
        $c->executeStatement('DELETE FROM daily');
        $c->executeStatement('DELETE FROM cube');
    }

    // ---- Fixture-Hilfe -------------------------------------------------------

    private function cubeConn(): Connection
    {
        return GeneralUtility::makeInstance(ConnectionPool::class)->getConnectionByName('cube');
    }

    private function repo(): CubeRepository
    {
        return new CubeRepository(GeneralUtility::makeInstance(ConnectionPool::class));
    }

    private function insertSite(int $siteId, string $siteName, array $cubeRows = []): void
    {
        $c = $this->cubeConn();
        $c->insert('meta', [
            'site_id' => $siteId, 'site' => $siteName,
            'von' => '2026-01-01', 'bis' => '2026-01-31',
            'visits_total' => 3, 'pageviews_total' => 5, 'uniques_total' => 2,
            'bounces_total' => 2, 'bytes_total' => 6700, 'erzeugt' => '2026-02-01 00:00',
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
        // Zeilen ausserhalb des Fensters (anderer Tag) - muessen ausgeschlossen werden.
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
}
