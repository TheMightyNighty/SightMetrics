<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Pure (TYPO3-free) resolution of the configurable error page -> unit-testable.
 */
final class ErrorPage
{
    public const DEFAULT_TITLE = 'Analytics currently unavailable';
    public const DEFAULT_MESSAGE = 'The connection to the analytics database is currently interrupted.';

    /**
     * @param array<mixed> $conf Extension configuration (ext_conf_template, untyped)
     * @param bool $isAdmin Only deliver the technical message to backend admins (may
     *        contain DB host/user/paths), even if showTechnical is enabled.
     * @return array{title:string,message:string,technical:string}
     */
    public static function resolve(array $conf, string $technical, bool $isAdmin): array
    {
        $title = Params::toString($conf['errorTitle'] ?? null);
        $message = Params::toString($conf['errorMessage'] ?? null);
        $showTechnical = Params::toInt($conf['showTechnical'] ?? null) === 1
            || Params::toString($conf['showTechnical'] ?? null) === '1';
        return [
            'title' => $title !== '' ? $title : self::DEFAULT_TITLE,
            'message' => $message !== '' ? $message : self::DEFAULT_MESSAGE,
            'technical' => ($showTechnical && $isAdmin) ? $technical : '',
        ];
    }
}
