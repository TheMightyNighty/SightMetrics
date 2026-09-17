<?php

// Ausschlussliste fuer das TER-Paket (typo3/tailor, via TYPO3_EXCLUDE_FROM_PACKAGING).
// Erweitert tailors Standardliste um Dev-Dateien der Extension, statt sie zu ersetzen.

$default = require \Composer\InstalledVersions::getInstallPath('typo3/tailor') . '/conf/ExcludeFromPackaging.php';

return [
    'directories' => array_merge($default['directories'], [
        'scripts',
    ]),
    'files' => array_merge($default['files'], [
        'phpstan-base.neon',
        'phpstan.ci.neon',
        'phpunit.functional.xml.dist',
        'tsconfig.json',
    ]),
];
