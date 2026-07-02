<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Reine (TYPO3-freie) Auflösung der konfigurierbaren Fehlerseite -> unit-testbar.
 */
final class ErrorPage
{
    public const DEFAULT_TITLE = 'Auswertung derzeit nicht verfügbar';
    public const DEFAULT_MESSAGE = 'Die Verbindung zur Auswertungs-Datenbank ist zurzeit unterbrochen.';

    /**
     * @param array<string,mixed> $conf Extension-Konfiguration (ext_conf_template)
     * @param bool $isAdmin Technische Meldung nur an Backend-Admins ausliefern (kann
     *        DB-Host/User/Pfade enthalten), auch wenn showTechnical aktiviert ist.
     * @return array{title:string,message:string,technical:string}
     */
    public static function resolve(array $conf, string $technical, bool $isAdmin): array
    {
        return [
            'title' => !empty($conf['errorTitle']) ? (string)$conf['errorTitle'] : self::DEFAULT_TITLE,
            'message' => !empty($conf['errorMessage']) ? (string)$conf['errorMessage'] : self::DEFAULT_MESSAGE,
            'technical' => (!empty($conf['showTechnical']) && $isAdmin) ? $technical : '',
        ];
    }
}
