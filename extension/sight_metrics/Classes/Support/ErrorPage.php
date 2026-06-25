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
     * @return array{title:string,message:string,technical:string}
     */
    public static function resolve(array $conf, string $technical): array
    {
        return [
            'title' => !empty($conf['errorTitle']) ? (string)$conf['errorTitle'] : self::DEFAULT_TITLE,
            'message' => !empty($conf['errorMessage']) ? (string)$conf['errorMessage'] : self::DEFAULT_MESSAGE,
            'technical' => !empty($conf['showTechnical']) ? $technical : '',
        ];
    }
}
