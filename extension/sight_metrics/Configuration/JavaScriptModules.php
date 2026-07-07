<?php

// Natives ES-Modul-Mapping fuers Backend-Modul (PageRenderer::loadJavaScriptModule()).
// Relative Imports innerhalb von Resources/Public/JavaScript/ (./modules/*.js)
// loesen sich gegen die Entry-URL auf und brauchen keine eigenen Eintraege.
return [
    'dependencies' => ['backend'],
    'imports' => [
        '@sightmetrics/' => 'EXT:sight_metrics/Resources/Public/JavaScript/',
    ],
];
