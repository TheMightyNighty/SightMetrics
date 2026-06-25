<?php
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
