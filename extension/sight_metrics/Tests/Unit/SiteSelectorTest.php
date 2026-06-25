<?php

declare(strict_types=1);

namespace SightMetrics\Tests\Unit;

use PHPUnit\Framework\TestCase;
use SightMetrics\Support\SiteSelector;
use TYPO3\CMS\Core\Site\Entity\Site;
use TYPO3\CMS\Core\Site\SiteFinder;

final class SiteSelectorTest extends TestCase
{
    public function testReturnsZeroWhenNoSites(): void
    {
        self::assertSame(0, SiteSelector::resolve([], 0));
    }

    public function testDefaultsToFirstSiteWhenRequestedIsZero(): void
    {
        self::assertSame(1, SiteSelector::resolve([['site_id' => 1]], 0));
    }

    public function testReturnsRequestedSiteWhenItExists(): void
    {
        $sites = [['site_id' => 1], ['site_id' => 2]];
        self::assertSame(2, SiteSelector::resolve($sites, 2));
    }

    public function testFallsBackToFirstWhenRequestedNotInList(): void
    {
        $sites = [['site_id' => 1], ['site_id' => 2]];
        self::assertSame(1, SiteSelector::resolve($sites, 99));
    }

    public function testHandlesStringIdsFromDatabase(): void
    {
        self::assertSame(2, SiteSelector::resolve([['site_id' => '2']], 2));
    }

    public function testFirstSiteSelectedWhenRequestedZeroAndMultipleSites(): void
    {
        $sites = [['site_id' => 5], ['site_id' => 7]];
        self::assertSame(5, SiteSelector::resolve($sites, 0));
    }

    // ---- allowedSiteIds -------------------------------------------------------

    public function testAllowedSiteIdsReturnsEmptyWhenNoSitesConfigured(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([]);

        self::assertSame([], SiteSelector::allowedSiteIds($finder));
    }

    public function testAllowedSiteIdsReturnsEmptyWhenNoneHaveMapping(): void
    {
        $site = $this->makeSite([]);
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([$site]);

        self::assertSame([], SiteSelector::allowedSiteIds($finder));
    }

    public function testAllowedSiteIdsExtractsMappedIds(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => 3]),
            $this->makeSite(['sightmetrics_site_id' => 7]),
        ]);

        self::assertSame([3, 7], SiteSelector::allowedSiteIds($finder));
    }

    public function testAllowedSiteIdsDeduplicates(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => 1]),
            $this->makeSite(['sightmetrics_site_id' => 1]),
            $this->makeSite(['sightmetrics_site_id' => 2]),
        ]);

        self::assertSame([1, 2], SiteSelector::allowedSiteIds($finder));
    }

    public function testAllowedSiteIdsConvertsStringToInt(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => '5']),
        ]);

        self::assertSame([5], SiteSelector::allowedSiteIds($finder));
    }

    /** Die allowedSiteIds-Tests mocken TYPO3-Klassen – im TYPO3-freien Phar-Runner überspringen. */
    protected function setUp(): void
    {
        parent::setUp();
        if (str_starts_with($this->name(), 'testAllowedSiteIds') && !class_exists(SiteFinder::class)) {
            self::markTestSkipped('TYPO3 (SiteFinder/Site) im Unit-Runner nicht verfügbar – Abdeckung via CI/Functional.');
        }
    }

    private function makeSite(array $config): Site
    {
        $site = $this->createMock(Site::class);
        $site->method('getConfiguration')->willReturn($config);
        return $site;
    }
}
