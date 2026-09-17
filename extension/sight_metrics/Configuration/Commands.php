<?php

/*
 * This file is part of the TYPO3 CMS extension "sight_metrics".
 *
 * SPDX-FileCopyrightText: 2026 Robert Schleiermacher
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

return [
    'sightmetrics:smoke' => [
        'class' => \SightMetrics\Command\SmokeCommand::class,
        'schedulable' => false,
    ],
    'sightmetrics:health' => [
        'class' => \SightMetrics\Command\HealthCommand::class,
        'schedulable' => false,
    ],
];
