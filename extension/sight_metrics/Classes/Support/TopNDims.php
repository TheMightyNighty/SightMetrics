<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Dimensionen ohne Drill-down-Kind, deren Barlisten serverseitig auf Top-N begrenzt werden
 * (ROADMAP.md "Top-N + Nachladen", Phase 1). Land/Browser/OS/Geraet/Referrer-Typ bleiben
 * aussen vor: Land wird komplett fuer die Choropleth-Karte gebraucht, die anderen haben ein
 * DRILL-Kind in dashboard.js (Kappung der Elternebene wuerde childrenOf() brechen).
 */
final class TopNDims
{
    private function __construct()
    {
    }

    /** dim => Metrik ('pv' oder 'v'), passend zu den bisherigen barlist()-Aufrufen in dashboard.js. */
    public const METRIC_BY_DIM = [
        'keyword' => 'v',
        'entry' => 'v',
        'exit' => 'v',
        'download' => 'pv',
        'status' => 'pv',
        'method' => 'pv',
    ];

    public const DEFAULT_LIMIT = 8;
}
