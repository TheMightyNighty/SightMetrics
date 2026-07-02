<?php

declare(strict_types=1);

namespace SightMetrics\Tests\Unit;

use PHPUnit\Framework\TestCase;
use SightMetrics\Support\SiteSelector;
use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
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

    public function testAllowedSiteIdsReturnsNullWhenNoSitesConfigured(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([]);

        // null = kein Mapping -> Aufrufer duerfen filterlos arbeiten (Rueckwaertskompat.).
        self::assertNull(SiteSelector::allowedSiteIds($finder, $this->beUser(false)));
    }

    public function testAllowedSiteIdsReturnsNullWhenNoneHaveMapping(): void
    {
        $site = $this->makeSite([], 1);
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([$site]);

        self::assertNull(SiteSelector::allowedSiteIds($finder, $this->beUser(false)));
    }

    public function testAllowedSiteIdsExtractsMappedIdsForAdmin(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => 3], 1),
            $this->makeSite(['sightmetrics_site_id' => 7], 2),
        ]);

        // Admin sieht alles, unabhaengig vom Webmount.
        self::assertSame([3, 7], SiteSelector::allowedSiteIds($finder, $this->beUser(true)));
    }

    public function testAllowedSiteIdsDeduplicatesForAdmin(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => 1], 1),
            $this->makeSite(['sightmetrics_site_id' => 1], 1),
            $this->makeSite(['sightmetrics_site_id' => 2], 2),
        ]);

        self::assertSame([1, 2], SiteSelector::allowedSiteIds($finder, $this->beUser(true)));
    }

    public function testAllowedSiteIdsConvertsStringToIntForAdmin(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => '5'], 1),
        ]);

        self::assertSame([5], SiteSelector::allowedSiteIds($finder, $this->beUser(true)));
    }

    public function testAllowedSiteIdsFiltersByWebmountForNonAdmin(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => 3], 10),
            $this->makeSite(['sightmetrics_site_id' => 7], 20),
        ]);

        // Nicht-Admin darf nur rootPageId 10 sehen (Webmount) -> nur Site 3 im Ergebnis.
        $beUser = $this->createMock(BackendUserAuthentication::class);
        $beUser->method('isAdmin')->willReturn(false);
        $beUser->method('isInWebMount')->willReturnCallback(
            static fn(int $pageId): ?int => $pageId === 10 ? 10 : null
        );

        self::assertSame([3], SiteSelector::allowedSiteIds($finder, $beUser));
    }

    public function testAllowedSiteIdsExcludesAllForNonAdminWithoutWebmountAccess(): void
    {
        $finder = $this->createMock(SiteFinder::class);
        $finder->method('getAllSites')->willReturn([
            $this->makeSite(['sightmetrics_site_id' => 3], 10),
        ]);

        $beUser = $this->createMock(BackendUserAuthentication::class);
        $beUser->method('isAdmin')->willReturn(false);
        $beUser->method('isInWebMount')->willReturn(null);

        // [] (nicht null!): Mapping existiert, Benutzer darf nichts sehen. Aufrufer muessen
        // das als "keine Sites" behandeln, NICHT als "kein Filter" (Mandantentrennung).
        self::assertSame([], SiteSelector::allowedSiteIds($finder, $beUser));
    }

    /** Die allowedSiteIds-Tests mocken TYPO3-Klassen – im TYPO3-freien Phar-Runner überspringen. */
    protected function setUp(): void
    {
        parent::setUp();
        if (str_starts_with($this->name(), 'testAllowedSiteIds') && !class_exists(SiteFinder::class)) {
            self::markTestSkipped('TYPO3 (SiteFinder/Site) im Unit-Runner nicht verfügbar – Abdeckung via CI/Functional.');
        }
    }

    private function makeSite(array $config, int $rootPageId): Site
    {
        $site = $this->createMock(Site::class);
        $site->method('getConfiguration')->willReturn($config);
        $site->method('getRootPageId')->willReturn($rootPageId);
        return $site;
    }

    private function beUser(bool $isAdmin): BackendUserAuthentication
    {
        $beUser = $this->createMock(BackendUserAuthentication::class);
        $beUser->method('isAdmin')->willReturn($isAdmin);
        return $beUser;
    }
}
