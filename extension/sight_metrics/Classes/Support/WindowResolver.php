<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Determines the server-side time window [from, to], which daily/cube are loaded for.
 *
 * Limits the transfer volume independently of the cube DB's retention: instead of
 * loading the complete cube, only a window (default `windowDays`) is read. Within
 * the window, the frontend keeps filtering instantly (including period comparison).
 *
 * Optional query parameters `from`/`to` (ISO YYYY-MM-DD) shift/extend the window
 * ad hoc; invalid values are ignored. Everything is clamped to the actually present
 * data (meta.von/meta.bis). windowDays <= 0 = unbounded (entire dataset).
 */
final class WindowResolver
{
    /**
     * @return array{0: string, 1: string} [from, to] as ISO date
     */
    public static function resolve(
        ?string $metaVon,
        ?string $metaBis,
        int $windowDays,
        ?string $requestedFrom,
        ?string $requestedTo,
    ): array {
        // No data present: empty, internally consistent window.
        if ($metaVon === null || $metaVon === '' || $metaBis === null || $metaBis === '') {
            return ['1970-01-01', '1970-01-01'];
        }

        $reqTo = self::iso($requestedTo);
        $bis = $reqTo !== null ? self::clamp($reqTo, $metaVon, $metaBis) : $metaBis;

        $reqFrom = self::iso($requestedFrom);
        if ($reqFrom !== null) {
            $from = self::clamp($reqFrom, $metaVon, $bis);
        } elseif ($windowDays > 0) {
            $from = self::clamp(self::minusDays($bis, $windowDays - 1), $metaVon, $bis);
        } else {
            $from = $metaVon; // unbounded
        }

        if ($from > $bis) {
            $from = $bis;
        }
        return [$from, $bis];
    }

    /**
     * Validates an ISO date (YYYY-MM-DD incl. checkdate, e.g. no 2026-99-99); otherwise
     * null. Public because TopNAjaxController needs the same validation too.
     */
    public static function iso(?string $s): ?string
    {
        if ($s === null || preg_match('/^\d{4}-\d{2}-\d{2}$/', $s) !== 1) {
            return null;
        }
        [$y, $m, $d] = array_map('intval', explode('-', $s));
        return checkdate($m, $d, $y) ? $s : null;
    }

    private static function clamp(string $v, string $lo, string $hi): string
    {
        if ($v < $lo) {
            return $lo;
        }
        return $v > $hi ? $hi : $v;
    }

    private static function minusDays(string $iso, int $days): string
    {
        $ts = strtotime($iso . ' -' . $days . ' days');
        return $ts === false ? $iso : date('Y-m-d', $ts);
    }
}
