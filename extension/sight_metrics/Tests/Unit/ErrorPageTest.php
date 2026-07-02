<?php
declare(strict_types=1);
namespace SightMetrics\Tests\Unit;

use PHPUnit\Framework\TestCase;
use SightMetrics\Support\ErrorPage;

final class ErrorPageTest extends TestCase
{
    public function testDefaultsWhenConfigEmpty(): void
    {
        $r = ErrorPage::resolve([], 'boom', true);
        self::assertSame(ErrorPage::DEFAULT_TITLE, $r['title']);
        self::assertSame(ErrorPage::DEFAULT_MESSAGE, $r['message']);
        self::assertSame('', $r['technical'], 'showTechnical aus -> technische Meldung verborgen');
    }

    public function testCustomValuesAndTechnicalShownForAdmin(): void
    {
        $r = ErrorPage::resolve(['errorTitle' => 'T', 'errorMessage' => 'M', 'showTechnical' => '1'], 'boom', true);
        self::assertSame('T', $r['title']);
        self::assertSame('M', $r['message']);
        self::assertSame('boom', $r['technical']);
    }

    public function testTechnicalHiddenWhenFlagOff(): void
    {
        self::assertSame('', ErrorPage::resolve(['showTechnical' => 0], 'secret', true)['technical']);
    }

    public function testTechnicalHiddenForNonAdminEvenWhenFlagOn(): void
    {
        self::assertSame('', ErrorPage::resolve(['showTechnical' => '1'], 'secret', false)['technical']);
    }
}
