<?php

declare(strict_types=1);

namespace SightMetrics\Tests\Functional;

use SightMetrics\Domain\Repository\CubeRepository;
use TYPO3\CMS\Core\Cache\CacheManager;
use TYPO3\CMS\Core\Configuration\ExtensionConfiguration;
use TYPO3\CMS\Core\Database\ConnectionPool;
use TYPO3\CMS\Core\Utility\GeneralUtility;
use TYPO3\TestingFramework\Core\Functional\FunctionalTestCase;

/**
 * CONTRACT TEST across the package boundary (docs/SCHEMA.md): reads what the
 * REAL ingestion wrote into a REAL MariaDB cube DB and asserts the numbers
 * through the real CubeRepository. Both packages otherwise only test against
 * their own fixtures; this test pins the shared contract.
 *
 * Orchestrated by tests/contract/run.sh (imports ingestion/tests/fixture.log
 * as site 990 with forced built-in heuristics, then runs this test with the
 * CONTRACT_DB_* env vars set). Without those env vars the test is skipped, so
 * the normal functional suite stays self-contained (SQLite).
 */
final class CubeContractTest extends FunctionalTestCase
{
    private const SITE_ID = 990;
    private const FROM = '2026-01-01';
    private const TO = '2026-01-31';

    protected array $testExtensionsToLoad = [];

    protected function setUp(): void
    {
        parent::setUp();
        $host = getenv('CONTRACT_DB_HOST');
        if ($host === false || $host === '') {
            self::markTestSkipped('Contract-DB nicht konfiguriert (CONTRACT_DB_HOST) - via tests/contract/run.sh ausfuehren.');
        }
        $GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube'] = [
            'driver' => 'mysqli',
            'host' => $host,
            'port' => (int)(getenv('CONTRACT_DB_PORT') ?: 3306),
            'user' => getenv('CONTRACT_DB_USER') ?: 'report_ro',
            'password' => getenv('CONTRACT_DB_PASS') ?: 'report_ro',
            'dbname' => getenv('CONTRACT_DB_NAME') ?: 'analytics',
        ];
    }

    private function repo(): CubeRepository
    {
        return new CubeRepository(
            GeneralUtility::makeInstance(ConnectionPool::class),
            GeneralUtility::makeInstance(CacheManager::class),
            GeneralUtility::makeInstance(ExtensionConfiguration::class),
        );
    }

    public function testContractFixtureRoundTrip(): void
    {
        $repo = $this->repo();

        self::assertSame(CubeRepository::SCHEMA_VERSION, $repo->schemaVersion(), 'Writer und Reader muessen dieselbe Schema-Version sprechen');

        $sites = $repo->sites([self::SITE_ID]);
        self::assertCount(1, $sites, 'Fixture-Site 990 muss in meta stehen');

        $meta = $repo->meta(self::SITE_ID);
        self::assertSame(6, (int)$meta['pageviews_total']);
        self::assertSame(4, (int)$meta['visits_total']);
        self::assertSame(3, (int)$meta['uniques_total']);
        self::assertSame(3, (int)$meta['bounces_total']);
        self::assertSame(7200, (int)$meta['bytes_total']);
        self::assertSame('UTC', (string)$meta['tz']);

        $daily = $repo->daily(self::SITE_ID, self::FROM, self::TO);
        self::assertSame(6, array_sum(array_map(static fn(array $d): int => (int)$d['pageviews'], $daily)));
        self::assertSame(4, array_sum(array_map(static fn(array $d): int => (int)$d['visits'], $daily)));

        // Top-N over the contract columns (dim/dimkey/pv/v aggregation)
        $urls = $repo->topN(self::SITE_ID, self::FROM, self::TO, 'url', 'pv', 10);
        self::assertSame('/a', $urls[0]['dimkey']);
        self::assertSame(4, $urls[0]['pv']);

        $status = $repo->topN(self::SITE_ID, self::FROM, self::TO, 'status', 'pv', 10);
        $byStatus = array_column($status, 'pv', 'dimkey');
        self::assertSame(6, $byStatus['200'] ?? null, 'Statuscode-Dimension: 200er');
        self::assertSame(1, $byStatus['404'] ?? null, 'Statuscode-Dimension enthaelt Fehler (4xx)');

        $browsers = $repo->topN(self::SITE_ID, self::FROM, self::TO, 'browser', 'v', 10);
        $byBrowser = array_column($browsers, 'v', 'dimkey');
        self::assertSame(3, $byBrowser['Chrome'] ?? null);
        self::assertSame(1, $byBrowser['Edge'] ?? null, 'Heuristik-Modus erwartet (run.sh erzwingt SM_UA_*=/nonexistent)');

        // Drill-down via the v2 'parent' column
        $versions = $repo->topN(self::SITE_ID, self::FROM, self::TO, 'browser_version', 'v', 10, 0, 'Chrome');
        self::assertNotSame([], $versions, 'browser_version-Kinder unter parent=Chrome');
        self::assertStringStartsWith('Chrome', $versions[0]['dimkey']);

        // Neutral referrer_type keys (v2 contract)
        $refs = $repo->topN(self::SITE_ID, self::FROM, self::TO, 'referrer_type', 'v', 10);
        $byRef = array_column($refs, 'v', 'dimkey');
        self::assertSame(3, $byRef['direct'] ?? null);
        self::assertSame(1, $byRef['search'] ?? null);

        $summary = $repo->dimSummary(self::SITE_ID, self::FROM, self::TO, 'url');
        self::assertSame(6, $summary['pv']);

        $tree = $repo->urlTree(self::SITE_ID, self::FROM, self::TO, '', 2, 50);
        self::assertSame(6, array_sum(array_map(static fn(array $r): int => (int)$r['pv'], $tree['rows'])), 'Seitenbaum-Wurzel summiert alle Pageviews');
    }

    /**
     * Top-N precompute (docs/topn-precompute-spec.md): the fixture is a single
     * day (2026-01-10), so [meta.von, meta.bis] IS the 'all' window exactly --
     * the precomputed `topn` table must return the identical rows as a live
     * query for the same [from,to], for both a root dim and a drill-down child.
     */
    public function testTopNPrecomputeMatchesLiveQuery(): void
    {
        $repo = $this->repo();
        $meta = $repo->meta(self::SITE_ID);
        $von = (string)$meta['von'];
        $bis = (string)$meta['bis'];
        self::assertSame($von, $bis, 'Fixture ist ein Einzeltag -- Testannahme fuer das "all"-Fenster');

        $liveRoot = $repo->topN(self::SITE_ID, $von, $bis, 'referrer_type', 'v', 10);
        $precomputedRoot = $repo->topN(self::SITE_ID, $von, $bis, 'referrer_type', 'v', 10, 0, null, 'all');
        self::assertNotSame([], $precomputedRoot, 'topn muss fuer die Fixture-Site befuellt sein');
        self::assertSame($liveRoot, $precomputedRoot, 'Vorberechnetes "all"-Fenster (root) muss der Live-Query entsprechen');

        $liveChild = $repo->topN(self::SITE_ID, $von, $bis, 'browser_version', 'v', 10, 0, 'Chrome');
        $precomputedChild = $repo->topN(self::SITE_ID, $von, $bis, 'browser_version', 'v', 10, 0, 'Chrome', 'all');
        self::assertNotSame([], $precomputedChild, 'topn-Drilldown muss fuer die Fixture-Site befuellt sein');
        self::assertSame($liveChild, $precomputedChild, 'Vorberechnetes "all"-Fenster (Drilldown) muss der Live-Query entsprechen');

        // An unsupported/forged window label must be ignored, never crash and
        // never produce wrong data -- just fall back to the (still correct)
        // live path. (A *supported* mismatched label can't be constructed with
        // this fixture: with a single-day dataset every window collapses to
        // [von,bis] after clamping, so all of them "match" here by construction.)
        $unsupported = $repo->topN(self::SITE_ID, $von, $bis, 'referrer_type', 'v', 10, 0, null, 'bogus-window');
        self::assertSame($liveRoot, $unsupported, 'Unbekanntes Fenster-Label darf nur auf live zurueckfallen, nie falsche Daten liefern');
    }
}
