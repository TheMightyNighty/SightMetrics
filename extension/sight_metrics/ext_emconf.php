<?php

/*
 * This file is part of the TYPO3 CMS extension "sight_metrics".
 *
 * SPDX-FileCopyrightText: 2026 Robert Schleiermacher
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

$EM_CONF[$_EXTKEY] = [
    'title' => 'SightMetrics – Web access analytics',
    'description' => 'Privacy-friendly, log-file based web analytics backend module. Reads pre-aggregated data (read-only) from a cube database filled by the separately deployed SightMetrics ingestion pipeline (DuckDB) – no tracker, no cookies.',
    'category' => 'module',
    'author' => 'Robert Schleiermacher',
    'author_email' => 'robert.schleiermacher@gmail.com',
    'state' => 'stable',
    'version' => '2.1.0',
    'constraints' => [
        'depends' => [
            'typo3' => '13.4.0-14.99.99',
            'php' => '8.2.0-0.0.0',
        ],
    ],
];
