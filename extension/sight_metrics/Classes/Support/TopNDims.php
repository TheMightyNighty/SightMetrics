<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Dimensions whose bar lists are limited server-side to Top-N (ROADMAP.md
 * "Top-N + lazy loading"). Two categories:
 *
 * - ROOT_METRIC_BY_DIM: top-level dims, preloaded in the initial payload (see
 *   DashboardController). Some have a drill-down child (CHILD_OF_ROOT), whose rows
 *   never sit in the initial payload but are only reachable via Ajax lazy-loading (parentKey).
 * - CHILD_METRIC_BY_DIM: pure child dimensions (without their own root bar list), only
 *   reachable via parentKey. "referrer_url" appears in both lists: once as its own flat
 *   list (all referrer_url rows ungrouped), once as a child of referrer_name.
 *
 * Country stays completely unbounded (the choropleth map needs all countries, ISO
 * cardinality is bounded to ~250 values anyway) -- deliberately does not appear here.
 */
final class TopNDims
{
    private function __construct() {}

    /** Root dim => metric ('pv' or 'v'). */
    public const ROOT_METRIC_BY_DIM = [
        'keyword' => 'v',
        'entry' => 'v',
        'exit' => 'v',
        'download' => 'pv',
        'status' => 'pv',
        'method' => 'pv',
        'browser' => 'v',
        'os' => 'v',
        'device' => 'v',
        'referrer_type' => 'v',
        'referrer_url' => 'v',
    ];

    /** Child dim => metric, only reachable via parentKey. */
    public const CHILD_METRIC_BY_DIM = [
        'browser_version' => 'v',
        'os_version' => 'v',
        'device_model' => 'v',
        'referrer_name' => 'v',
        'referrer_url' => 'v',
    ];

    /** Root dim => child dim, for the drill-down UI (display "▸ click for ..."). */
    public const CHILD_OF_ROOT = [
        'browser' => 'browser_version',
        'os' => 'os_version',
        'device' => 'device_model',
        'referrer_type' => 'referrer_name',
    ];

    /** Root dim => default limit (differs from the usual default for referrer_url). */
    public const LIMIT_BY_ROOT_DIM = [
        'referrer_url' => 10,
    ];

    public const DEFAULT_LIMIT = 8;

    /**
     * Page tree dimension: not a Top-N/child scheme but path segments -- runs via
     * CubeRepository::urlTree() and the Ajax route sightmetrics_tree, but like the
     * Top-N dims is no longer fully present in the initial payload.
     */
    public const TREE_DIM = 'url';

    public static function defaultLimitFor(string $rootDim): int
    {
        return self::LIMIT_BY_ROOT_DIM[$rootDim] ?? self::DEFAULT_LIMIT;
    }

    /**
     * All dims that are NOT completely present in the initial payload (CubeRepository::cube()).
     *
     * @return list<string>
     */
    public static function excludedFromFullPayload(): array
    {
        return array_values(array_unique(array_merge(
            array_keys(self::ROOT_METRIC_BY_DIM),
            array_keys(self::CHILD_METRIC_BY_DIM),
            [self::TREE_DIM]
        )));
    }
}
