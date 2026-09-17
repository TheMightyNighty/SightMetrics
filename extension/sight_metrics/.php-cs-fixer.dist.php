<?php

/*
 * This file is part of the TYPO3 CMS extension "sight_metrics".
 *
 * SPDX-FileCopyrightText: 2026 Robert Schleiermacher
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

// Code style per TYPO3 Coding Standards.
$config = \TYPO3\CodingStandards\CsFixerConfig::create();
$config->getFinder()->in([__DIR__ . '/Classes']);
return $config;
