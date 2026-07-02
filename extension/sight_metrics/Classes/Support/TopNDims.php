<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Dimensionen, deren Barlisten serverseitig auf Top-N begrenzt werden (ROADMAP.md
 * "Top-N + Nachladen"). Zwei Kategorien:
 *
 * - ROOT_METRIC_BY_DIM: Top-Level-Dims, im Initial-Payload vorab geladen (siehe
 *   DashboardController). Manche haben ein Drill-down-Kind (CHILD_OF_ROOT), dessen Zeilen
 *   nie im Initial-Payload stecken, sondern nur per Ajax-Nachladen (parentKey) erreichbar sind.
 * - CHILD_METRIC_BY_DIM: reine Kind-Dimensionen (ohne eigene Root-Barliste), nur ueber
 *   parentKey erreichbar. "referrer_url" kommt in beiden Listen vor: einmal als eigene flache
 *   Liste (alle referrer_url-Zeilen ungruppiert), einmal als Kind von referrer_name.
 *
 * Land bleibt komplett unbegrenzt (Choropleth-Karte braucht alle Laender, ISO-Kardinalitaet
 * ohnehin auf ~250 Werte begrenzt) -- taucht hier bewusst nicht auf.
 */
final class TopNDims
{
    private function __construct() {}

    /** Root-dim => Metrik ('pv' oder 'v'). */
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

    /** Kind-dim => Metrik, nur ueber parentKey erreichbar. */
    public const CHILD_METRIC_BY_DIM = [
        'browser_version' => 'v',
        'os_version' => 'v',
        'device_model' => 'v',
        'referrer_name' => 'v',
        'referrer_url' => 'v',
    ];

    /** Root-dim => Kind-dim, fuers Drill-down-UI (Anzeige "▸ klicken fuer ..."). */
    public const CHILD_OF_ROOT = [
        'browser' => 'browser_version',
        'os' => 'os_version',
        'device' => 'device_model',
        'referrer_type' => 'referrer_name',
    ];

    /** Root-dim => Standard-Limit (weicht bei referrer_url vom sonstigen Default ab). */
    public const LIMIT_BY_ROOT_DIM = [
        'referrer_url' => 10,
    ];

    public const DEFAULT_LIMIT = 8;

    public static function defaultLimitFor(string $rootDim): int
    {
        return self::LIMIT_BY_ROOT_DIM[$rootDim] ?? self::DEFAULT_LIMIT;
    }

    /**
     * Alle Dims, die NICHT komplett im Initial-Payload (CubeRepository::cube()) stecken.
     *
     * @return list<string>
     */
    public static function excludedFromFullPayload(): array
    {
        return array_values(array_unique(array_merge(
            array_keys(self::ROOT_METRIC_BY_DIM),
            array_keys(self::CHILD_METRIC_BY_DIM)
        )));
    }
}
