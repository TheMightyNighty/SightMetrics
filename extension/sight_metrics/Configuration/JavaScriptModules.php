<?php

/*
 * This file is part of the TYPO3 CMS extension "sight_metrics".
 *
 * SPDX-FileCopyrightText: 2026 Robert Schleiermacher
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

// Native ES module mapping for the backend module (PageRenderer::loadJavaScriptModule()).
// Relative imports within Resources/Public/JavaScript/ (./modules/*.js)
// resolve against the entry URL and don't need their own entries.
return [
    'dependencies' => ['backend'],
    'imports' => [
        '@sightmetrics/' => 'EXT:sight_metrics/Resources/Public/JavaScript/',
    ],
];
