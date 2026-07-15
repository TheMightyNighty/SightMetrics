<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Boundaries of the preset windows the ingestion precomputes into `topn`
 * (docs/topn-precompute-spec.md). Mirrors presets.js applyPreset() exactly --
 * anchor = min(today in the site's timezone, meta.bis), never later than the
 * newest imported day, clamped into [meta.von, meta.bis]. Used by
 * CubeRepository::topN() to verify that a client-supplied `window` label
 * actually matches the requested [from, to] before trusting the precomputed
 * table; unverified/mismatched labels must fall back to the live query.
 */
final class TopNWindows
{
    private function __construct() {}

    /** Window labels the ingestion precomputes (sink_mysql.sql). */
    public const SUPPORTED = ['last30', 'last90', 'last365', 'thisyear', 'lastyear', 'all'];

    /**
     * @return array{0: string, 1: string}|null [from, to] (ISO), or null if $window
     *   is unsupported or there is no data (meta.von/meta.bis empty).
     */
    public static function boundsFor(string $window, string $metaVon, string $metaBis): ?array
    {
        if (!in_array($window, self::SUPPORTED, true) || $metaVon === '' || $metaBis === '') {
            return null;
        }
        try {
            $anchor = new \DateTimeImmutable($metaBis);
        } catch (\Exception) {
            return null;
        }

        $year = (int)$anchor->format('Y');
        [$from, $to] = match ($window) {
            'last30' => [$anchor->modify('-29 days')->format('Y-m-d'), $anchor->format('Y-m-d')],
            'last90' => [$anchor->modify('-89 days')->format('Y-m-d'), $anchor->format('Y-m-d')],
            'last365' => [$anchor->modify('-364 days')->format('Y-m-d'), $anchor->format('Y-m-d')],
            'thisyear' => [sprintf('%04d-01-01', $year), sprintf('%04d-12-31', $year)],
            'lastyear' => [sprintf('%04d-01-01', $year - 1), sprintf('%04d-12-31', $year - 1)],
            'all' => [$metaVon, $anchor->format('Y-m-d')],
        };

        $fromIso = max($from, $metaVon);
        $toIso = min($to, $metaBis);
        return $fromIso <= $toIso ? [$fromIso, $toIso] : null;
    }
}
