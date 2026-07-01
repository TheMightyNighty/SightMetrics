<?php
$EM_CONF[$_EXTKEY] = [
    'title' => 'SightMetrics - Zugriffsauswertung',
    'description' => 'Backend-Modul: liest read-only die DuckDB-Cube-DB und zeigt die Auswertung (Verlauf, Seitenbaum, Geo/Technik, Top-Listen).',
    'category' => 'module',
    'author' => 'SightMetrics',
    'state' => 'stable',
    'version' => '1.0.0',
    'constraints' => [
        'depends' => [
            'typo3' => '13.4.0-14.99.99',
            'php' => '8.2.0-0.0.0',
        ],
    ],
];
