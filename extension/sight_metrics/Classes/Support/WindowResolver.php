<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Ermittelt das serverseitige Zeitfenster [from, bis], auf das daily/cube geladen werden.
 *
 * Begrenzt das Transfervolumen unabhaengig von der Retention der Cube-DB: statt den
 * kompletten Cube zu laden, wird nur ein Fenster (Default `windowDays`) gelesen. Innerhalb
 * des Fensters filtert das Frontend weiterhin sofort (inkl. Perioden-Vergleich).
 *
 * Optionale Query-Parameter `from`/`to` (ISO YYYY-MM-DD) verschieben/erweitern das Fenster
 * ad hoc; ungueltige Werte werden ignoriert. Alles wird auf die real vorhandenen Daten
 * (meta.von/meta.bis) geklemmt. windowDays <= 0 = unbegrenzt (gesamter Datenbestand).
 */
final class WindowResolver
{
    /**
     * @return array{0: string, 1: string} [from, bis] als ISO-Datum
     */
    public static function resolve(
        ?string $metaVon,
        ?string $metaBis,
        int $windowDays,
        ?string $requestedFrom,
        ?string $requestedTo,
    ): array {
        // Kein Datenbestand: leeres, in sich konsistentes Fenster.
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
            $from = $metaVon; // unbegrenzt
        }

        if ($from > $bis) {
            $from = $bis;
        }
        return [$from, $bis];
    }

    /**
     * Validiert ein ISO-Datum (YYYY-MM-DD inkl. checkdate, z. B. kein 2026-99-99); sonst
     * null. Public, weil auch TopNAjaxController dieselbe Validierung braucht.
     */
    public static function iso(?string $s): ?string
    {
        if ($s === null || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $s)) {
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
