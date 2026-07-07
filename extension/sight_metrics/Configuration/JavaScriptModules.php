<?php

// Native ES module mapping for the backend module (PageRenderer::loadJavaScriptModule()).
// Relative imports within Resources/Public/JavaScript/ (./modules/*.js)
// resolve against the entry URL and don't need their own entries.
return [
    'dependencies' => ['backend'],
    'imports' => [
        '@sightmetrics/' => 'EXT:sight_metrics/Resources/Public/JavaScript/',
    ],
];
