<?php

declare(strict_types=1);

namespace SightMetrics\Tests\Unit;

use PHPUnit\Framework\TestCase;
use SightMetrics\Support\WindowResolver;

final class WindowResolverTest extends TestCase
{
    public function testDefaultWindowIsLastNDaysEndingAtMetaBis(): void
    {
        // 92-Tage-Fenster endet an meta.bis; Start = bis - 91 Tage.
        self::assertSame(
            ['2026-03-31', '2026-06-30'],
            WindowResolver::resolve('2025-01-01', '2026-06-30', 92, null, null),
        );
    }

    public function testWindowClampedToMetaVonWhenDatasetShorterThanWindow(): void
    {
        self::assertSame(
            ['2026-06-01', '2026-06-30'],
            WindowResolver::resolve('2026-06-01', '2026-06-30', 92, null, null),
        );
    }

    public function testZeroWindowDaysLoadsWholeDataset(): void
    {
        self::assertSame(
            ['2025-01-01', '2026-06-30'],
            WindowResolver::resolve('2025-01-01', '2026-06-30', 0, null, null),
        );
    }

    public function testExplicitRangeOverridesWindowAndIsClampedToData(): void
    {
        self::assertSame(
            ['2026-02-01', '2026-02-28'],
            WindowResolver::resolve('2025-01-01', '2026-06-30', 92, '2026-02-01', '2026-02-28'),
        );
        // Ausserhalb des Datenbestands -> auf meta.von/bis geklemmt.
        self::assertSame(
            ['2025-01-01', '2026-06-30'],
            WindowResolver::resolve('2025-01-01', '2026-06-30', 92, '2000-01-01', '2099-01-01'),
        );
    }

    public function testInvalidDateParamsAreIgnored(): void
    {
        // Ungueltiges 'to' -> Default-Fenster greift wie ohne Parameter.
        self::assertSame(
            ['2026-03-31', '2026-06-30'],
            WindowResolver::resolve('2025-01-01', '2026-06-30', 92, null, '2026-13-99'),
        );
        // Ungueltiges 'from' -> Default-Fensterstart.
        self::assertSame(
            ['2026-03-31', '2026-06-30'],
            WindowResolver::resolve('2025-01-01', '2026-06-30', 92, 'kaputt', null),
        );
    }

    public function testEmptyMetaReturnsConsistentEmptyWindow(): void
    {
        self::assertSame(['1970-01-01', '1970-01-01'], WindowResolver::resolve(null, null, 92, null, null));
        self::assertSame(['1970-01-01', '1970-01-01'], WindowResolver::resolve('', '', 92, null, null));
    }
}
